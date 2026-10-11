module C = Connection

let src =
  Logs.Src.create "postgres-eio.pool"
    ~doc:
      "The pool: waits for a connection, borrows held long, and connections \
       made again"

module Log = (val Logs.src_log src : Logs.LOG)

type error = [ `Pool of [ `Busy | `Closed ] ]

let error_to_string : error -> string = function
  | `Pool `Busy -> "no connection came free within the pool's wait"
  | `Pool `Closed -> "the pool is closed"

(* Only the holder of an entry (a borrower or the housekeeping) touches it,
   so no lock is needed. *)
type entry = {
  conn : C.t;
  expires : Mtime.t;
  mutable idle_since : Mtime.t;
  (* Queued at give-back, read at the next lend. *)
  mutable resetting : Tag.t C.Pipeline.answer list;
}

(* Not [Eio.Pool]: connections are made up front, and its wait has no
   bound and cannot cancel a borrower's work. *)
type t = {
  free : entry Eio.Stream.t;
  (* Resolved by [close]; a borrow waiting races it. *)
  closed : unit Eio.Promise.t;
  close_now : unit Eio.Promise.u;
  size : int;
  wait_s : float;
  clock : Eio.Time.Mono.ty Eio.Resource.t;
  connect : unit -> (C.t, C.error) result;
  timeout_s : float option;
  reset : bool;
  lifetime : Mtime.Span.t;
  idle_check : Mtime.Span.t;
  waiting : int Atomic.t;
  replaced : int Atomic.t;
  (* Its own, seeded: the stdlib's starts alike in every process, so pools
     started together would replace their connections together. *)
  random : Random.State.t;
}

type stats = { size : int; idle : int; waiting : int; replaced : int }

let span s =
  Option.value (Mtime.Span.of_float_ns (s *. 1e9)) ~default:Mtime.Span.max_span

let now t = Eio.Time.Mono.now t.clock

(* Jitter of ±10%, so connections made together are not replaced together. *)
let entry t conn =
  let made = now t in
  let jitter = 0.9 +. Random.State.float t.random 0.2 in
  let lifetime = span (Mtime.Span.to_float_ns t.lifetime *. jitter /. 1e9) in
  {
    conn;
    expires =
      Option.value (Mtime.add_span made lifetime) ~default:Mtime.max_stamp;
    idle_since = made;
    resetting = [];
  }

(* DISCARD ALL minus prepared statements and plans, which are the shared
   cache, and minus UNLISTEN, which is sent regardless. *)
let reset_statements =
  [
    "set session authorization default";
    "select pg_advisory_unlock_all()";
    "close all";
    "reset all";
    "discard temp";
    "discard sequences";
  ]

(* Sent but not read here: the next lend reads it, usually without waiting.
   Even with [~reset:false] an open transaction is rolled back, and a
   LISTEN ended, since an idle pooled connection reads nothing and would
   fill the server's notification queue. A standby refuses UNLISTEN and
   cannot have listened anyway. *)
let queue_reset t e =
  let conn = e.conn in
  let rollback =
    match C.status conn with
    | Protocol.Idle -> []
    | Protocol.In_transaction | Protocol.Failed -> [ "rollback" ]
  in
  let unlisten =
    match C.parameter conn "in_hot_standby" with
    | Some "on" -> []
    | Some _ | None -> [ "unlisten *" ]
  in
  let reset = if t.reset then reset_statements else [] in
  match rollback @ unlisten @ reset with
  | [] -> ()
  | statements ->
      e.resetting <-
        List.map (fun sql -> C.Pipeline.execute conn sql ~params:[]) statements;
      (* A failed write closes the connection; the next lend reconnects. *)
      ignore (C.Pipeline.flush conn : (unit, C.error) result)

let back t e =
  e.idle_since <- now t;
  if Eio.Promise.is_resolved t.closed then C.close e.conn
  else Eio.Stream.add t.free e

let made_again what e =
  Log.info (fun m -> m "%s, and is made again" what);
  match C.reset e.conn with
  | Ok () -> ()
  | Error err ->
      Log.warn (fun m ->
          m "a connection could not be made again: %s" (C.error_to_string err))

(* Reads the queued reset; a failed reset or dead connection is replaced
   here, inside the borrow, so a cancelled borrower still returns it. If
   reconnecting fails the reason is logged, as the borrower will only see
   [Closed]. *)
let ready e =
  ignore (C.Pipeline.drain e.conn : (unit, C.error) result);
  let failed =
    List.find_map
      (fun a ->
        match C.Pipeline.get a with Ok _ -> None | Error err -> Some err)
      e.resetting
  in
  e.resetting <- [];
  match failed with
  | _ when C.closed e.conn -> made_again "a connection was found closed" e
  | Some err ->
      made_again
        (Printf.sprintf "a connection's reset failed (%s)"
           (C.error_to_string err))
        e
  | None -> ()

(* A borrower cancelled between exchanges may leave a statement sent and
   unread, which Postgres would run to its end, so it is cancelled at the
   server, within the pool's timeout, since the borrower may have lifted
   its own; one cancelled midway has closed the connection and cancelled
   its own. The connection is closed rather than read back into step, to
   be made again at the next lend, and what it had queued is never sent.

   A row function that raises while drained has closed the connection; it
   goes back all the same, to be made again at the next lend, and its
   exception is returned for the borrower to raise. *)
let give_back t e ~cancelled =
  if cancelled && not (C.closed e.conn) then begin
    C.set_timeout e.conn ~timeout_s:t.timeout_s;
    ignore (C.cancel e.conn : (unit, C.error) result);
    C.close e.conn
  end;
  let raised =
    match C.Pipeline.drain e.conn with
    | (_ : (unit, C.error) result) -> None
    | exception ex -> Some (ex, Printexc.get_raw_backtrace ())
  in
  C.set_timeout e.conn ~timeout_s:t.timeout_s;
  if not (C.closed e.conn) then queue_reset t e;
  back t e;
  raised

(* Housekeeping *)

(* The replacement connects before [e] leaves the queue, so no borrower
   waits on a connect. If [e] was borrowed meanwhile, the next pass retries. *)
let renew t e =
  match t.connect () with
  | Error err ->
      Log.warn (fun m ->
          m "a connection past its lifetime could not be made anew: %s"
            (C.error_to_string err))
  | Ok conn ->
      let fresh = entry t conn in
      let rec find n =
        n > 0
        &&
        match Eio.Stream.take_nonblocking t.free with
        | None -> false
        | Some held when held == e -> true
        | Some other ->
            Eio.Stream.add t.free other;
            find (n - 1)
      in
      if find (Eio.Stream.length t.free) then begin
        C.close e.conn;
        Atomic.incr t.replaced;
        back t fresh
      end
      else C.close conn

(* An empty query, only while another connection is idle so a borrower
   still has one. A failure means reconnect. *)
let check t e =
  match C.script e.conn "" with
  | Ok () -> back t e
  | Error err -> (
      Log.info (fun m ->
          m "an idle connection failed its check (%s), and is made anew"
            (C.error_to_string err));
      match t.connect () with
      | Ok conn ->
          C.close e.conn;
          Atomic.incr t.replaced;
          back t (entry t conn)
      | Error err ->
          Log.warn (fun m ->
              m "a connection could not be made anew: %s"
                (C.error_to_string err));
          back t e)

(* Idle connections only: a borrowed one is its borrower's alone. *)
let tidy t =
  let at = now t in
  let expired e = Mtime.is_later at ~than:e.expires in
  let quiet e =
    Mtime.Span.compare (Mtime.span e.idle_since at) t.idle_check >= 0
  in
  let due = ref [] in
  for _ = 1 to Eio.Stream.length t.free do
    match Eio.Stream.take_nonblocking t.free with
    | None -> ()
    | Some e when expired e ->
        Eio.Stream.add t.free e;
        due := e :: !due
    | Some e when quiet e && Eio.Stream.length t.free > 0 -> check t e
    | Some e -> Eio.Stream.add t.free e
  done;
  List.iter (renew t) !due

(* Passes per [min idle_check_s max_lifetime_s], so a connection is
   replaced or checked at most a quarter of that period late. *)
let passes_per_period = 4.

let housekeeping t ~every =
  let rec loop () =
    Eio.Time.Mono.sleep t.clock every;
    if not (Eio.Promise.is_resolved t.closed) then begin
      tidy t;
      loop ()
    end
  in
  loop ()

let create ~sw ~net ~clock ?parameters ?timeout_s ?statement_cache ?(size = 8)
    ?(wait_s = 5.) ?(reset = true) ?(max_lifetime_s = 1800.)
    ?(idle_check_s = 60.) conninfo =
  let connect () =
    C.connect ~sw ~net ~clock ?parameters ?timeout_s ?statement_cache conninfo
  in
  let rec go n acc =
    if n <= 0 then Ok acc
    else
      match connect () with
      | Ok c -> go (n - 1) (c :: acc)
      | Error e ->
          List.iter C.close acc;
          Error e
  in
  Result.map
    (fun all ->
      let size = List.length all in
      let closed, close_now = Eio.Promise.create () in
      let t =
        {
          free = Eio.Stream.create size;
          closed;
          close_now;
          size;
          wait_s;
          clock :> Eio.Time.Mono.ty Eio.Resource.t;
          connect;
          timeout_s = (match all with c :: _ -> C.timeout_s c | [] -> None);
          reset;
          lifetime = span max_lifetime_s;
          idle_check = span idle_check_s;
          waiting = Atomic.make 0;
          replaced = Atomic.make 0;
          random = Random.State.make_self_init ();
        }
      in
      List.iter (fun c -> Eio.Stream.add t.free (entry t c)) all;
      (* A daemon, so it does not keep the switch open. *)
      Eio.Fiber.fork_daemon ~sw (fun () ->
          housekeeping t
            ~every:(Float.min max_lifetime_s idle_check_s /. passes_per_period);
          `Stop_daemon);
      t)
    (go (max 1 size) [])

let stats (t : t) =
  {
    size = t.size;
    idle = Eio.Stream.length t.free;
    waiting = Atomic.get t.waiting;
    replaced = Atomic.get t.replaced;
  }

let wait_warn_s = 0.1
let hold_warn_s = 0.25

let slow ~what ~over_s since until =
  let s = Mtime.Span.to_float_ns (Mtime.span since until) /. 1e9 in
  if s > over_s then Log.warn (fun m -> m "%s took %.0f ms" what (s *. 1000.))

(* Several branches can succeed at once, and the losers' results are
   dropped; if one were a connection it would leak from the pool. So the
   connection always wins. *)
let take (t : t) ~wait_s =
  Atomic.incr t.waiting;
  Fun.protect
    ~finally:(fun () -> Atomic.decr t.waiting)
    (fun () ->
      Eio.Fiber.any
        ~combine:(fun a b -> match a with Ok _ -> a | Error _ -> b)
        [
          (fun () -> Ok (Eio.Stream.take t.free));
          (fun () ->
            Eio.Promise.await t.closed;
            Error `Closed);
          (fun () ->
            Eio.Time.Mono.sleep t.clock wait_s;
            Error `Busy);
        ])

let use ?wait_s t f =
  let wait_s = Option.value wait_s ~default:t.wait_s in
  let asked = now t in
  match take t ~wait_s with
  | Error `Busy ->
      Log.warn (fun m -> m "no connection came free within %gs" wait_s);
      Error (`Pool `Busy)
  | Error `Closed -> Error (`Pool `Closed)
  | Ok e ->
      let given = now t in
      slow ~what:"a wait for a connection" ~over_s:wait_warn_s asked given;
      (* [f] is not shielded: a cancellation stops it at whatever it is
         waiting on. Only the give-back's own exchanges are. *)
      let answer, cancelled =
        match ready e with
        | exception ex -> (Error (ex, Printexc.get_raw_backtrace ()), false)
        | () -> (
            match f e.conn with
            | v -> (Ok v, false)
            | exception (Eio.Cancel.Cancelled _ as ex) ->
                (Error (ex, Printexc.get_raw_backtrace ()), true)
            | exception ex -> (Error (ex, Printexc.get_raw_backtrace ()), false)
            )
      in
      let raised =
        Eio.Cancel.protect (fun () ->
            slow ~what:"a borrowed connection" ~over_s:hold_warn_s given (now t);
            give_back t e ~cancelled)
      in
      (* What the borrower raised, a cancellation included, came first and
         wins over what the drain raised. *)
      begin match (answer, raised) with
      | Error (ex, bt), _ | Ok _, Some (ex, bt) ->
          Printexc.raise_with_backtrace ex bt
      | Ok v, None -> Ok v
      end

(* Borrowed connections close when returned, not under a running
   transaction. *)
let close t =
  ignore (Eio.Promise.try_resolve t.close_now () : bool);
  let rec idle () =
    match Eio.Stream.take_nonblocking t.free with
    | Some e ->
        C.close e.conn;
        idle ()
    | None -> ()
  in
  idle ()
