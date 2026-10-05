(* Failures inside an exchange raise [Fail], caught where the exchange
   began and returned as a value; nothing escapes this module. A failure
   that desynchronises the stream (timeout, broken socket, malformed bytes,
   a raise from the caller's row function) closes the link. A server error
   does not, since the server marks where its reply ends. *)

module P = Protocol
module C = Conninfo

let src =
  Logs.Src.create "postgres-eio"
    ~doc:"Postgres: connections made, and the server's notices"

module Log = (val Logs.src_log src : Logs.LOG)

type error =
  | Server of Server_error.t
  | Refused of string
  | Timeout
  | Closed
  | Io of string
  | Protocol of string

let error_to_string = function
  | Server e -> Server_error.to_string e
  | Refused m -> m
  | Timeout -> "the server did not answer within the connection's timeout"
  | Closed -> "the connection is closed"
  | Io m -> m
  | Protocol m -> "the server broke the protocol: " ^ m

exception Fail of error

let fail e = raise (Fail e)

type socket = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t
type notification = { channel : string; payload : string; pid : int }

type statement = { name : string; mutable prepared : prepared }

and prepared =
  | Parsing  (** its Parse is sent and the answer not yet read *)
  | Described of Column.t array  (** parsed, and its result's columns known *)
  | Unparsed of error  (** the server refused its Parse *)

(* Keyed by SQL text; past [capacity] the least recently used is closed. *)
type cache = {
  capacity : int;
  statements : (string, statement * int ref) Hashtbl.t;
  mutable uses : int;
  mutable named : int;
}

(* An exchange awaiting its answer. [read] reads to its ReadyForQuery;
   [lost] reports the link failed first. *)
type reply = { read : unit -> unit; lost : error -> unit }

(* [flow] is [socket] or the TLS session over it. *)
type link = {
  socket : socket;
  flow : socket;
  reader : P.reader;
  buf : Cstruct.t;
  outgoing : Cstruct.t;
  secure : bool;
  (* For SCRAM channel binding. *)
  server_certificate : X509.Certificate.t option;
  address : Eio.Net.Sockaddr.stream;
  (* Queued bytes and their replies, then sent replies in answer order. *)
  out : Buffer.t;
  unsent : reply Queue.t;
  sent : reply Queue.t;
  cache : cache;
  mutable waiting : int;
  mutable moved : Mtime.t;
  mutable writing : bool;
  mutable exchanging : Eio.Cancel.t option;
}

(* Where the link went, so a cancel request can reach the same server. *)
type reached = {
  endpoint : C.endpoint;
  address : Eio.Net.Sockaddr.stream;
  secure : bool;
}

type t = {
  sw : Eio.Switch.t;
  net : [ `Generic ] Eio.Net.ty Eio.Resource.t;
  clock : Eio.Time.Mono.ty Eio.Resource.t;
  conninfo : C.t;
  tls : Tls.Config.client option;
  parameters : (string * string) list;
  statement_cache : int;
  mutable timeout_s : float option;
  mutable link : link option;
  (* Wakes the link's timer when the timeout or link changes. *)
  changed : Eio.Condition.t;
  (* Set by [abandon]: later statements are refused before sending. *)
  mutable refusing : bool; [@atomic]
  mutable status : P.transaction_status;
  mutable pid : int;
  mutable key : string;
  mutable protocol_minor : int;
  mutable settings : (string * string) list;
  mutable reached : reached option;
  (* Only a listener keeps notifications; others drop them. *)
  heard : notification Queue.t option;
}

(* Bytes *)

(* A timeout for work outside a link's own timer: connecting, cancel
   requests, the Terminate. *)
let bounded ~clock timeout_s f =
  let timeout =
    match timeout_s with
    | Some s -> Eio.Time.Timeout.seconds clock s
    | None -> Eio.Time.Timeout.none
  in
  match Eio.Time.Timeout.run_exn timeout f with
  | v -> v
  | exception Eio.Time.Timeout -> fail Timeout

let guard f =
  match f () with
  | v -> v
  | exception End_of_file -> fail Closed
  | exception (Eio.Io _ as ex) -> fail (Io (Printexc.to_string ex))
  | exception (Tls_eio.Tls_alert _ as ex) -> fail (Io (Printexc.to_string ex))
  | exception (Tls_eio.Tls_failure _ as ex) -> fail (Io (Printexc.to_string ex))

let encode m = match P.encode m with Ok s -> s | Error e -> fail (Refused e)
let now t = Eio.Time.Mono.now t.clock

(* Counted as waiting on the server; each byte moved is progress. *)
let waited t link f =
  if link.waiting = 0 then link.moved <- now t;
  link.waiting <- link.waiting + 1;
  let v = guard f in
  link.waiting <- link.waiting - 1;
  link.moved <- now t;
  v

(* Written in pieces so a slow but live server counts as progress. *)
let piece = 65536

(* Larger than one TLS read can return (16 KiB record + 4 KiB), so no
   plaintext is left buffered inside tls-eio, invisible to a listener waiting
   on socket readiness. *)
let read_size = 65536

let write t link bytes =
  let n = String.length bytes in
  link.writing <- true;
  let rec go off =
    if off < n then begin
      let len = Int.min piece (n - off) in
      Cstruct.blit_from_string bytes off link.outgoing 0 len;
      waited t link (fun () ->
          Eio.Flow.write link.flow [ Cstruct.sub link.outgoing 0 len ]);
      go (off + len)
    end
  in
  go 0;
  link.writing <- false

let send t link m = write t link (encode m)

(* [awaited] false: a read nobody waits on yet (a COPY's answer while its
   data is still being sent), so it is not counted as waiting. *)
let receive ~awaited t link =
  let n =
    if awaited then
      waited t link (fun () -> Eio.Flow.single_read link.flow link.buf)
    else
      let n = guard (fun () -> Eio.Flow.single_read link.flow link.buf) in
      link.moved <- now t;
      n
  in
  P.feed link.reader (Cstruct.sub link.buf 0 n)

let rec next ~awaited t link =
  match P.next link.reader with
  | Error m -> fail (Protocol m)
  | Ok (Some m) -> m
  | Ok None ->
      receive ~awaited t link;
      next ~awaited t link

(* 54.2.7: notices, parameter changes and notifications may arrive between
   any two messages. *)
let notice fields =
  let e = Server_error.of_fields fields in
  match Server_error.severity e with
  | "WARNING" -> Log.warn (fun m -> m "%s" (Server_error.to_string e))
  | "NOTICE" | "INFO" -> Log.info (fun m -> m "%s" (Server_error.to_string e))
  | _ -> Log.debug (fun m -> m "%s" (Server_error.to_string e))

let asynchronous t = function
  | P.Notice_response fields ->
      notice fields;
      true
  | P.Parameter_status { name; value } ->
      t.settings <- (name, value) :: List.remove_assoc name t.settings;
      true
  | P.Notification_response { pid; channel; payload } ->
      Option.iter (Queue.add { channel; payload; pid }) t.heard;
      true
  | _ -> false

let rec message ?(awaited = true) t link =
  let m = next ~awaited t link in
  if asynchronous t m then message ~awaited t link else m

let name_of = function
  | P.Authentication _ -> "an Authentication message"
  | P.Backend_key_data _ -> "a BackendKeyData"
  | P.Parameter_status _ -> "a ParameterStatus"
  | P.Ready_for_query _ -> "a ReadyForQuery"
  | P.Row_description _ -> "a RowDescription"
  | P.Data_row _ -> "a DataRow"
  | P.Command_complete _ -> "a CommandComplete"
  | P.Empty_query_response -> "an EmptyQueryResponse"
  | P.Error_response _ -> "an ErrorResponse"
  | P.Notice_response _ -> "a NoticeResponse"
  | P.Notification_response _ -> "a NotificationResponse"
  | P.Parse_complete -> "a ParseComplete"
  | P.Bind_complete -> "a BindComplete"
  | P.Close_complete -> "a CloseComplete"
  | P.No_data -> "a NoData"
  | P.Portal_suspended -> "a PortalSuspended"
  | P.Parameter_description _ -> "a ParameterDescription"
  | P.Copy_in_response _ -> "a CopyInResponse"
  | P.Copy_out_response _ -> "a CopyOutResponse"
  | P.Copy_both_response _ -> "a CopyBothResponse"
  | P.Copy_data _ -> "a CopyData"
  | P.Copy_done -> "a CopyDone"
  | P.Function_call_response _ -> "a FunctionCallResponse"
  | P.Negotiate_protocol_version _ -> "a NegotiateProtocolVersion"

let out_of_turn section m when_ =
  fail (Protocol (Printf.sprintf "%s: %s %s" section (name_of m) when_))

(* One timer per link, not per exchange (which cost a fiber and a timer
   registration every round trip). It sleeps until the timeout would expire
   since the last byte moved, and cancels the waiting exchange if none has.
   Time is only counted while waiting on the server, never during the
   caller's row function. *)
let rec watch t link =
  match t.link with
  | Some current when current == link -> (
      match t.timeout_s with
      | None ->
          Eio.Condition.await_no_mutex t.changed;
          watch t link
      | Some s ->
          let span =
            Option.value
              (Mtime.Span.of_float_ns (s *. 1e9))
              ~default:Mtime.Span.zero
          in
          if
            link.waiting > 0
            && Mtime.Span.compare (Mtime.span link.moved (now t)) span >= 0
          then begin
            Option.iter
              (fun cc -> Eio.Cancel.cancel cc (Fail Timeout))
              link.exchanging;
            Eio.Condition.await_no_mutex t.changed
          end
          else begin
            let from = if link.waiting > 0 then link.moved else now t in
            Eio.Fiber.first
              (fun () ->
                Eio.Time.Mono.sleep_until t.clock
                  (Option.value (Mtime.add_span from span)
                     ~default:Mtime.max_stamp))
              (fun () -> Eio.Condition.await_no_mutex t.changed)
          end;
          watch t link)
  | Some _ | None -> `Stop_daemon

let linked t link =
  t.link <- Some link;
  Eio.Fiber.fork_daemon ~sw:t.sw (fun () -> watch t link)

(* The link's timer cancels this context; any other cancellation is the
   caller's and propagates unchanged. *)
let exchange t link f =
  match t.timeout_s with
  | None -> f ()
  | Some _ -> (
      match
        Eio.Cancel.sub (fun cc ->
            link.exchanging <- Some cc;
            f ())
      with
      | v ->
          link.exchanging <- None;
          v
      | exception Eio.Cancel.Cancelled (Fail Timeout) ->
          link.exchanging <- None;
          fail Timeout
      | exception ex ->
          link.exchanging <- None;
          raise ex)

(* TLS *)

let read_file what file =
  match In_channel.with_open_bin file In_channel.input_all with
  | contents -> contents
  | exception Sys_error m ->
      fail (Refused (Printf.sprintf "%s cannot be read: %s" what m))

(* Built once per connection: loading the system CAs takes milliseconds.
   ALPN "postgresql" is required for direct TLS and harmless otherwise. *)
let tls_config (c : C.t) =
  let trusted () =
    match c.ssl_root_cert with
    | None -> Ca_certs.authenticator ()
    | Some file ->
        Result.map
          (fun cas ->
            X509.Authenticator.chain_of_trust
              ~time:(fun () -> Some (Ptime_clock.now ()))
              cas)
          (X509.Certificate.decode_pem_multiple (read_file "sslrootcert" file))
  in
  let authenticator =
    match c.ssl_mode with
    | C.Disable | C.Allow | C.Prefer | C.Require ->
        Ok (fun ?ip:_ ~host:_ _ -> Ok None)
    | C.Verify_ca ->
        (* verify-ca: the chain only, not the name. *)
        Result.map
          (fun a ?ip:_ ~host:_ chain -> a ?ip:None ~host:None chain)
          (trusted ())
    | C.Verify_full -> trusted ()
  in
  let certificates =
    match (c.ssl_cert, c.ssl_key) with
    | None, None -> `None
    | Some cert, Some key -> (
        match
          ( X509.Certificate.decode_pem_multiple (read_file "sslcert" cert),
            X509.Private_key.decode_pem (read_file "sslkey" key) )
        with
        | Ok chain, Ok key -> `Single (chain, key)
        | Error (`Msg m), _ ->
            fail (Refused ("sslcert is not a PEM certificate chain: " ^ m))
        | _, Error (`Msg m) ->
            fail
              (Refused
                 ("sslkey is not a PEM key this driver opens -- an encrypted \
                   one it does not: " ^ m)))
    | Some _, None | None, Some _ ->
        fail
          (Refused
             "sslcert and sslkey come together: a certificate is sent with its \
              key")
  in
  match authenticator with
  | Error (`Msg m) -> fail (Refused ("no certificate authority to trust: " ^ m))
  | Ok authenticator -> (
      match
        Tls.Config.client ~authenticator ~certificates
          ~alpn_protocols:[ "postgresql" ] ()
      with
      | Ok config -> config
      | Error (`Msg m) -> fail (Refused ("TLS cannot be configured: " ^ m)))

(* Only verify-full checks the name, so only there is an unusable name an
   error. Elsewhere SNI is still sent when valid, since some hosts route by
   it, and omitted when not (e.g. a compose service called [db]). *)
let identity (mode : C.ssl_mode) host =
  match Ipaddr.of_string host with
  | Ok ip -> (None, Some ip)
  | Error _ -> (
      match
        (Result.bind (Domain_name.of_string host) Domain_name.host, mode)
      with
      | Ok name, _ -> (Some name, None)
      | Error (`Msg _), C.Verify_full ->
          fail (Refused (Printf.sprintf "%S is not a name TLS can check" host))
      | ( Error (`Msg _),
          (C.Disable | C.Allow | C.Prefer | C.Require | C.Verify_ca) ) ->
          (None, None))

(* Returns the session and the server's certificate for channel binding.
   Direct TLS requires ALPN "postgresql", or any TLS server would do. *)
let handshake t config (endpoint : C.endpoint) socket ~direct =
  let host, ip =
    match endpoint.host with
    | C.Tcp h -> identity t.conninfo.ssl_mode h
    | C.Unix_socket _ -> (None, None)
  in
  let flow = guard (fun () -> Tls_eio.client_of_flow config ?host ?ip socket) in
  let epoch = Tls_eio.epoch flow in
  (match epoch with
  | Ok (e : Tls.Core.epoch_data)
    when direct
         && not (Option.equal String.equal e.alpn_protocol (Some "postgresql"))
    ->
      fail
        (Refused
           "the server did not agree to postgresql by ALPN on a direct TLS \
            handshake, so it is not taken for Postgres")
  | Ok _ | Error () -> ());
  let certificate =
    match epoch with
    | Ok { peer_certificate = Some c; _ } -> Some c
    | Ok { received_certificates = c :: _; _ } -> Some c
    | Ok _ | Error () -> None
  in
  ((flow :> socket), certificate)

type offer =
  | Encrypted of socket * X509.Certificate.t option
  | Declined
  | Errored

(* 54.2.10: read exactly one byte before the handshake, so bytes injected
   after it reach TLS and are refused (CVE-2021-23222). An ErrorResponse
   here is unauthenticated, so its text is not shown. *)
let negotiate t config endpoint (socket : socket) =
  guard (fun () -> Eio.Flow.copy_string (encode P.Ssl_request) socket);
  let one = Cstruct.create 1 in
  let n = guard (fun () -> Eio.Flow.single_read socket one) in
  match (n, Cstruct.get_char one 0) with
  | 1, 'S' ->
      let flow, certificate =
        handshake t config endpoint socket ~direct:false
      in
      Encrypted (flow, certificate)
  | 1, 'N' -> Declined
  | 1, 'E' -> Errored
  | _, c ->
      fail
        (Protocol
           (Printf.sprintf
              "54.2.10 SSL Session Encryption: %C in answer to an SSLRequest, \
               not S or N"
              c))

(* Startup and sign-in *)

let password t (endpoint : C.endpoint) =
  match (t.conninfo.password, endpoint.password) with
  | Some p, _ | None, Some p -> p
  | None, None ->
      fail
        (Refused
           "the server asks for a password and the connection string gives none")

let scram t link endpoint ~binding ~mechanism =
  let nonce = Base64.encode_string (Mirage_crypto_rng.generate 18) in
  let exchange, first =
    Auth.client_first ~binding ~password:(password t endpoint) ~nonce ()
  in
  send t link (P.Sasl_initial_response { mechanism; data = first });
  match message t link with
  | P.Authentication (P.Sasl_continue server_first) -> (
      match Auth.client_final exchange server_first with
      | Error m -> fail (Refused m)
      | Ok (proven, final) -> (
          send t link (P.Sasl_response final);
          match message t link with
          | P.Authentication (P.Sasl_final server_final) -> (
              match Auth.verify proven server_final with
              | Ok () -> ()
              | Error m -> fail (Refused m))
          | P.Error_response f -> fail (Server (Server_error.of_fields f))
          | m ->
              out_of_turn "54.3.1 SCRAM-SHA-256" m
                "where AuthenticationSASLFinal was due"))
  | P.Error_response f -> fail (Server (Server_error.of_fields f))
  | m ->
      out_of_turn "54.3.1 SCRAM-SHA-256" m
        "where AuthenticationSASLContinue was due"

(* 54.2.1: the server may downgrade the minor version, down to the
   connection string's minimum. *)
let negotiated t newest_minor =
  let least = C.protocol_minor t.conninfo.min_protocol_version in
  if newest_minor < least then
    fail
      (Refused
         (Printf.sprintf
            "the server speaks protocol 3.%d, below min_protocol_version 3.%d"
            newest_minor least));
  t.protocol_minor <- newest_minor

(* Checked against require_auth and channel binding at AuthenticationOk. *)
type signed = Not_yet | By_password | By_md5 | By_scram of { bound : bool }

(* 54.2.1: each request is checked before answering: require_auth,
   required channel binding, and no cleartext password without TLS. *)
let rec authenticate t link endpoint ~signed =
  let c = t.conninfo in
  let allowed = c.require_auth in
  let binding_required =
    match c.channel_binding with
    | C.Binding_required -> true
    | C.Binding_disabled | C.Binding_preferred -> false
  in
  let refuse m = fail (Refused m) in
  match message t link with
  | P.Authentication P.Accepted -> (
      match signed with
      | Not_yet when not allowed.none ->
          refuse
            "the server signed the client in without asking for anything, \
             which require_auth does not allow"
      | By_scram { bound = true } -> ()
      | Not_yet | By_password | By_md5 | By_scram { bound = false } ->
          if binding_required then
            refuse
              "channel binding is required, and the server signed the client \
               in without it")
  | P.Authentication P.Cleartext_password ->
      if not allowed.password then
        refuse
          "the server asks for a cleartext password, which require_auth does \
           not allow, and it is not sent";
      if binding_required then
        refuse
          "channel binding is required, and the server asks for a password \
           without it; it is not sent";
      if not link.secure then
        refuse
          "the server asks for the password in cleartext on a connection that \
           is not encrypted, and it is not sent";
      send t link (P.Password (password t endpoint));
      authenticate t link endpoint ~signed:By_password
  | P.Authentication (P.Md5_password salt) ->
      if not allowed.md5 then
        refuse
          "the server asks for MD5, which require_auth does not allow, and \
           nothing is sent";
      if binding_required then
        refuse
          "channel binding is required, and the server asks for MD5 without \
           it; nothing is sent";
      send t link
        (P.Password
           (Auth.md5 ~user:c.user ~password:(password t endpoint) ~salt));
      authenticate t link endpoint ~signed:By_md5
  | P.Authentication (P.Sasl mechanisms) ->
      if not allowed.scram_sha_256 then
        refuse
          "the server asks for SCRAM-SHA-256, which require_auth does not \
           allow, and nothing is sent";
      let offered m = List.exists (String.equal m) mechanisms in
      let data =
        if link.secure then
          Option.bind link.server_certificate Auth.tls_server_end_point
        else None
      in

      let binding, mechanism =
        match (c.channel_binding, offered Auth.mechanism_plus, data) with
        | (C.Binding_preferred | C.Binding_required), true, Some d ->
            (Auth.Bound d, Auth.mechanism_plus)
        | C.Binding_required, _, _ ->
            refuse
              (if not link.secure then
                 "channel binding is required, and the connection is not over \
                  TLS"
               else if not (offered Auth.mechanism_plus) then
                 "channel binding is required, and the server does not offer it"
               else
                 "channel binding is required, and the server's certificate \
                  names no hash to bind to")
        | C.Binding_preferred, false, Some _ ->
            (Auth.Not_offered, Auth.mechanism)
        | C.Binding_preferred, _, _ | C.Binding_disabled, _, _ ->
            (Auth.Unsupported, Auth.mechanism)
      in
      if not (offered mechanism) then
        refuse
          (Printf.sprintf
             "the server offers %s, and this driver signs in only with %s"
             (String.concat ", " mechanisms)
             Auth.mechanism);
      scram t link endpoint ~binding ~mechanism;
      authenticate t link endpoint
        ~signed:
          (By_scram
             {
               bound =
                 (match binding with
                 | Auth.Bound _ -> true
                 | Auth.Unsupported | Auth.Not_offered -> false);
             })
  | P.Authentication (P.Kerberos_v5 | P.Gss | P.Sspi) ->
      refuse
        "the server asks for Kerberos, GSSAPI or SSPI, which this driver does \
         not speak"
  | P.Negotiate_protocol_version { newest_minor; _ } ->
      negotiated t newest_minor;
      authenticate t link endpoint ~signed
  | P.Error_response f -> fail (Server (Server_error.of_fields f))
  | m ->
      out_of_turn "54.2.1 Start-up" m "before the server accepted the sign-in"

let rec ready t link =
  match message t link with
  | P.Backend_key_data { pid; key } ->
      t.pid <- pid;
      t.key <- key;
      ready t link
  | P.Ready_for_query s -> t.status <- s
  | P.Negotiate_protocol_version { newest_minor; _ } ->
      negotiated t newest_minor;
      ready t link
  | P.Error_response f -> fail (Server (Server_error.of_fields f))
  | m -> out_of_turn "54.2.1 Start-up" m "before ReadyForQuery"

(* The caller's parameters override the connection string's. *)
let start t link endpoint =
  let c = t.conninfo in
  t.protocol_minor <- C.protocol_minor c.max_protocol_version;
  let settings =
    List.filter (fun (k, _) -> not (List.mem_assoc k t.parameters)) c.options
    @ t.parameters
  in
  send t link
    (P.Startup
       {
         minor = t.protocol_minor;
         parameters =
           ("user", c.user) :: ("database", c.database)
           :: Option.fold ~none:[]
                ~some:(fun a -> [ ("application_name", a) ])
                c.application_name
           @ settings;
       });
  authenticate t link endpoint ~signed:Not_yet;
  ready t link

(* Hosts, addresses and sockets *)

let addresses t (endpoint : C.endpoint) =
  match (endpoint.host, endpoint.address) with
  | C.Unix_socket dir, _ ->
      [
        `Unix (Filename.concat dir (Printf.sprintf ".s.PGSQL.%d" endpoint.port));
      ]
  | C.Tcp _, Some ip ->
      let raw =
        match ip with
        | Ipaddr.V4 a -> Ipaddr.V4.to_octets a
        | Ipaddr.V6 a -> Ipaddr.V6.to_octets a
      in
      [ `Tcp (Eio.Net.Ipaddr.of_raw raw, endpoint.port) ]
  | C.Tcp host, None -> (
      match
        guard (fun () ->
            Eio.Net.getaddrinfo_stream t.net host
              ~service:(string_of_int endpoint.port))
      with
      | [] -> fail (Io (Printf.sprintf "no address for %s" host))
      | addresses -> addresses)

let close_quietly (socket : socket) =
  try Eio.Resource.close socket with Eio.Io _ -> ()

(* Detects a peer that vanished without closing, which an idle connection
   would never notice. Probe timing is the OS default: no portable way to
   set it. *)
let keep_alive (socket : socket) =
  match Eio_unix.Resource.fd_opt socket with
  | None -> ()
  | Some fd -> (
      try
        Eio_unix.Fd.use_exn "keepalive" fd (fun fd ->
            Unix.setsockopt fd Unix.SO_KEEPALIVE true)
      with Unix.Unix_error (e, _, _) ->
        fail (Io ("TCP keepalive cannot be set: " ^ Unix.error_message e)))

(* Not [Eio.Net.connect], which attaches the socket to the switch before
   connecting and leaks a descriptor per refused address until the switch
   ends. Raises the same [Eio.Io] it would. *)
let connect_socket ~sw address =
  let addr = Eio_unix.Net.sockaddr_to_unix address in
  let as_eio = function
    | Unix.Unix_error (code, name, arg) -> Eio_unix.Err.v code name arg
    | ex -> ex
  in
  let connect fd =
    Unix.set_nonblock fd;
    match Unix.connect fd addr with
    | () -> ()
    | exception
        Unix.Unix_error ((EINPROGRESS | EINTR | EAGAIN | EWOULDBLOCK), _, _)
      -> (
        Eio_unix.await_writable fd;
        match Unix.getsockopt_error fd with
        | None -> ()
        | Some code -> raise (Unix.Unix_error (code, "connect", "")))
  in
  match
    Unix.socket ~cloexec:true (Unix.domain_of_sockaddr addr) Unix.SOCK_STREAM 0
  with
  | exception ex -> raise (as_eio ex)
  | fd -> (
      match connect fd with
      | () -> Eio_unix.Net.import_socket_stream ~sw ~close_unix:true fd
      | exception ex ->
          (try Unix.close fd with Unix.Unix_error _ -> ());
          raise (as_eio ex))

let open_socket t address =
  let socket = (guard (fun () -> connect_socket ~sw:t.sw address) :> socket) in
  (match address with
  | `Tcp _ when t.conninfo.keepalives -> (
      try keep_alive socket
      with ex ->
        close_quietly socket;
        raise ex)
  | `Tcp _ | `Unix _ -> ());
  socket

type tls = Plain | If_offered | Required

(* [prefer] retries without TLS when the server refused TLS, the handshake
   failed, or sign-in failed inside it, as libpq does. *)
exception Again_without_tls

(* Unix sockets never use TLS, as in libpq. *)
let attempt t endpoint address ~tls =
  let socket = open_socket t address in
  let without_tls_if_preferred e =
    match tls with
    | If_offered -> raise Again_without_tls
    | Plain | Required -> fail e
  in
  match
    let flow, secure, server_certificate =
      match ((endpoint : C.endpoint).host, tls, t.tls) with
      | C.Unix_socket _, _, _ | C.Tcp _, Plain, _ | C.Tcp _, _, None ->
          (socket, false, None)
      | C.Tcp _, (If_offered | Required), Some config -> (
          match t.conninfo.ssl_negotiation with
          | C.Direct ->
              let flow, certificate =
                handshake t config endpoint socket ~direct:true
              in
              (flow, true, certificate)
          | C.Postgres -> (
              match negotiate t config endpoint socket with
              | Encrypted (flow, certificate) -> (flow, true, certificate)
              | exception Fail (Io _ as e) -> without_tls_if_preferred e
              | Declined -> (
                  match tls with
                  | If_offered -> (socket, false, None)
                  | Plain | Required ->
                      fail
                        (Refused
                           (Printf.sprintf
                              "the server does not offer TLS, which sslmode=%s \
                               asks for"
                              (C.ssl_mode_to_string t.conninfo.ssl_mode))))
              | Errored ->
                  without_tls_if_preferred
                    (Refused
                       "the server answered the request for TLS with an error, \
                        which is not shown because the server is not yet \
                        proven")))
    in
    let link =
      {
        socket;
        flow;
        reader = P.reader ();
        buf = Cstruct.create read_size;
        outgoing = Cstruct.create piece;
        secure;
        server_certificate;
        address;
        out = Buffer.create 256;
        unsent = Queue.create ();
        sent = Queue.create ();
        cache =
          {
            capacity = t.statement_cache;
            statements = Hashtbl.create (Int.min t.statement_cache 64);
            uses = 0;
            named = 0;
          };
        waiting = 0;
        moved = now t;
        writing = false;
        exchanging = None;
      }
    in
    t.settings <- [];
    (match start t link endpoint with
    | () -> ()
    | exception Fail (Server _ as e) when secure -> without_tls_if_preferred e);
    link
  with
  | link -> link
  | exception ex ->
      close_quietly socket;
      raise ex

let connect_address t endpoint address =
  match t.conninfo.ssl_mode with
  | C.Disable -> attempt t endpoint address ~tls:Plain
  | C.Allow -> (
      match attempt t endpoint address ~tls:Plain with
      | link -> link
      | exception Fail (Server _) -> attempt t endpoint address ~tls:Required)
  | C.Prefer -> (
      match attempt t endpoint address ~tls:If_offered with
      | link -> link
      | exception Again_without_tls -> attempt t endpoint address ~tls:Plain)
  | C.Require | C.Verify_ca | C.Verify_full ->
      attempt t endpoint address ~tls:Required

(* From the parameters Postgres 14+ reports at startup, so no query. *)
let suits t (wanted : C.session_attrs) =
  let on name =
    match List.assoc_opt name t.settings with
    | Some "on" -> Some true
    | Some "off" -> Some false
    | Some _ | None -> None
  in
  match wanted with
  | C.Any | C.Prefer_standby -> Ok true
  | C.Read_write | C.Read_only | C.Primary | C.Standby -> (
      match (on "in_hot_standby", on "default_transaction_read_only") with
      | Some standby, Some read_only ->
          Ok
            (match wanted with
            | C.Read_write -> (not standby) && not read_only
            | C.Read_only -> standby || read_only
            | C.Primary -> not standby
            | C.Standby | C.Any | C.Prefer_standby -> standby)
      | _ ->
          Error
            (Refused
               "the server does not say whether it is a standby, as Postgres \
                14 and later do"))

(* A generator seeded for each shuffle: the stdlib's global one starts
   from a fixed seed in every process, which would send every client to the
   same host first, and it is the application's. *)
let shuffled t l =
  match t.conninfo.load_balance_hosts with
  | C.In_order -> l
  | C.Random ->
      let random = Random.State.make_self_init () in
      List.map snd
        (List.sort
           (fun (a, _) (b, _) -> Int.compare a b)
           (List.map (fun x -> (Random.State.bits random, x)) l))

let session_attrs_name = function
  | C.Any -> "any"
  | C.Read_write -> "read-write"
  | C.Read_only -> "read-only"
  | C.Primary -> "primary"
  | C.Standby -> "standby"
  | C.Prefer_standby -> "prefer-standby"

(* Tries each address of each host until one matches target_session_attrs,
   each attempt bounded by connect_timeout as in libpq. [prefer-standby]
   falls back to any host. *)
let establish t =
  let c = t.conninfo in
  let bound =
    match c.connect_timeout_s with Some s -> Some s | None -> t.timeout_s
  in
  let terminate link =
    (try guard (fun () -> Eio.Flow.copy_string (encode P.Terminate) link.flow)
     with Fail _ -> ());
    close_quietly link.socket
  in
  let wrong_kind wanted =
    Refused
      (Printf.sprintf "no host is what target_session_attrs=%s asks for"
         (session_attrs_name wanted))
  in
  let search wanted =
    let rec hosts last = function
      | [] -> Error last
      | endpoint :: rest -> (
          match
            bounded ~clock:t.clock bound (fun () -> addresses t endpoint)
          with
          | exception Fail e -> hosts (Some e) rest
          | found -> each endpoint rest last (shuffled t found))
    and each endpoint rest last = function
      | [] -> hosts last rest
      | address :: more -> (
          match
            bounded ~clock:t.clock bound (fun () ->
                connect_address t endpoint address)
          with
          | exception Fail e ->
              Log.debug (fun m ->
                  m "no connection at %a: %s" Eio.Net.Sockaddr.pp address
                    (error_to_string e));
              each endpoint rest (Some e) more
          | link -> (
              match suits t wanted with
              | Ok true -> Ok (endpoint, link)
              | Ok false ->
                  terminate link;
                  each endpoint rest (Some (wrong_kind wanted)) more
              | Error e ->
                  terminate link;
                  each endpoint rest (Some e) more))
    in
    hosts None (shuffled t c.hosts)
  in
  let found =
    match c.target_session_attrs with
    | C.Prefer_standby -> (
        match search C.Standby with
        | Ok found -> Ok found
        | Error _ -> search C.Any)
    | wanted -> search wanted
  in
  match found with
  | Ok (endpoint, link) ->
      t.reached <-
        Some { endpoint; address = link.address; secure = link.secure };
      Log.debug (fun m ->
          m "connected to %a%s" Eio.Net.Sockaddr.pp link.address
            (if link.secure then " over TLS" else ""));
      link
  | Error last ->
      fail (Option.value last ~default:(Io "no address to connect to"))

let open_connection ~sw ~net ~clock ~parameters ~timeout_s ~statement_cache
    ~heard conninfo =
  (* TLS and the SCRAM nonce fail at runtime without a seeded RNG. *)
  Mirage_crypto_rng_unix.use_default ();
  match
    match (conninfo : C.t).ssl_mode with
    | C.Disable -> None
    | C.Allow | C.Prefer | C.Require | C.Verify_ca | C.Verify_full ->
        Some (tls_config conninfo)
  with
  | exception Fail e -> Error e
  | tls -> (
      let t =
        {
          sw;
          net :> [ `Generic ] Eio.Net.ty Eio.Resource.t;
          clock :> Eio.Time.Mono.ty Eio.Resource.t;
          conninfo;
          tls;
          parameters;
          statement_cache = Int.max 0 statement_cache;
          timeout_s = Some timeout_s;
          link = None;
          changed = Eio.Condition.create ();
          refusing = false;
          status = P.Idle;
          pid = 0;
          key = "";
          protocol_minor = 0;
          settings = [];
          reached = None;
          heard;
        }
      in
      match establish t with
      | link ->
          linked t link;
          Ok t
      | exception Fail e -> Error e)

let connect ~sw ~net ~clock ?(parameters = []) ?(timeout_s = 30.)
    ?(statement_cache = 256) conninfo =
  open_connection ~sw ~net ~clock ~parameters ~timeout_s ~statement_cache
    ~heard:None conninfo

(* The answer queue *)

let break t e =
  match t.link with
  | None -> ()
  | Some link ->
      t.link <- None;
      Eio.Condition.broadcast t.changed;
      close_quietly link.socket;
      Buffer.reset link.out;
      let lose q =
        Queue.iter (fun r -> r.lost e) q;
        Queue.clear q
      in
      lose link.sent;
      lose link.unsent

let abandoned =
  Refused
    "the work this connection was lent for was cancelled, and its statements \
     are not sent"

(* [sending] false: only reads, allowed even while refusing statements. *)
let run ?(sending = true) t f =
  match t.link with
  | None -> Error Closed
  | Some _ when sending && t.refusing -> Error abandoned
  | Some link -> (
      match exchange t link (fun () -> f link) with
      | answer -> answer
      | exception Fail (Refused _ as e) -> Error e
      | exception Fail e ->
          break t e;
          Error e
      | exception ex ->
          break t Closed;
          raise ex)

let enqueue link bytes reply =
  Buffer.add_string link.out bytes;
  Queue.add reply link.unsent

(* When refusing statements, queued bytes are dropped instead. *)
let take_queued t link =
  if t.refusing then begin
    Buffer.clear link.out;
    Queue.iter (fun r -> r.lost abandoned) link.unsent;
    Queue.clear link.unsent;
    ""
  end
  else begin
    let bytes = Buffer.contents link.out in
    if Buffer.length link.out > piece then Buffer.reset link.out
    else Buffer.clear link.out;
    Queue.transfer link.unsent link.sent;
    bytes
  end

(* Replies are read strictly in send order, through [target]'s or all. *)
let rec read_through link target =
  match Queue.take_opt link.sent with
  | None -> ()
  | Some r -> (
      r.read ();
      match target with
      | Some target when r == target -> ()
      | Some _ | None -> read_through link target)

(* Write and read concurrently: writing everything first can deadlock with
   both sides' buffers full. While writing, every reply is read, not just
   up to [through]'s, since the server stops reading while its answers
   wait. *)
let drive ?through t link =
  let last = Queue.fold (fun _ r -> Some r) None link.unsent in
  let bytes = take_queued t link in
  if String.length bytes = 0 then read_through link through
  else if Queue.length link.sent <= 1 then begin
    write t link bytes;
    read_through link through
  end
  else
    Eio.Fiber.both
      (fun () -> write t link bytes)
      (fun () ->
        read_through link (match through with None -> None | Some _ -> last))

(* 54.2.7: consumes asynchronous messages, or a fatal error, already
   received between exchanges, without blocking. *)
let rec unsolicited t link =
  match P.next link.reader with
  | Error m -> fail (Protocol m)
  | Ok None -> ()
  | Ok (Some m) when asynchronous t m -> unsolicited t link
  | Ok (Some (P.Error_response f)) -> fail (Server (Server_error.of_fields f))
  | Ok (Some m) ->
      out_of_turn "54.2.7 Asynchronous Operations" m "between exchanges"

(* Statements *)

let copy_refused =
  Refused
    "the statement is a COPY, which query and script do not carry: copy_in and \
     copy_out do"

(* Fixed text: the real reason may quote the data. *)
let copy_failed = "the client ended the COPY"

(* An unexpected COPY FROM STDIN is ended with CopyFail (plus a Sync under
   the extended protocol, whose Sync was ignored in copy-in mode). If more
   was already pipelined behind it, the server would read that as COPY
   data, so the connection is closed instead. *)
let refuse_copy_in t link ~extended =
  if Queue.is_empty link.sent && not link.writing then
    write t link
      (encode (P.Copy_fail copy_failed) ^ if extended then encode P.Sync else "")
  else begin
    break t copy_refused;
    fail copy_refused
  end

let column_of (f : P.field) =
  let format =
    match f.format with
    | 0 -> Column.Text
    | 1 -> Column.Binary
    | n ->
        fail
          (Protocol
             (Printf.sprintf
                "54.7 Message Formats: a RowDescription gives %S the format \
                 %d, not 0 or 1"
                f.name n))
  in
  { Column.name = f.name; type_oid = f.type_oid; format }

let columns_of fields = Array.of_list (List.map column_of fields)

(* Sent with the next write. Closing a missing name is not an error. *)
let close_statements t link names =
  match names with
  | [] -> ()
  | names ->
      let bytes =
        String.concat ""
          (List.map
             (fun name -> encode (P.Close { target = P.Statement; name }))
             names
          @ [ encode P.Sync ])
      in
      let rec read () =
        match message t link with
        | P.Close_complete | P.Error_response _ -> read ()
        | P.Ready_for_query s -> t.status <- s
        | m -> out_of_turn "54.2.3 Extended Query" m "in answer to a Close"
      in
      enqueue link bytes { read; lost = ignore }

let used (c : cache) =
  c.uses <- c.uses + 1;
  c.uses

let cached link sql =
  match Hashtbl.find_opt link.cache.statements sql with
  | None -> None
  | Some (s, last) ->
      last := used link.cache;
      Some s

let drop link sql s =
  match Hashtbl.find_opt link.cache.statements sql with
  | Some (held, _) when held == s -> Hashtbl.remove link.cache.statements sql
  | Some _ | None -> ()

let forget t link sql s =
  drop link sql s;
  close_statements t link [ s.name ]

let remember t link sql s =
  let c = link.cache in
  if Hashtbl.length c.statements >= c.capacity then begin
    let oldest =
      Hashtbl.fold
        (fun sql (s, last) oldest ->
          match oldest with
          | Some (_, _, before) when before <= !last -> oldest
          | Some _ | None -> Some (sql, s, !last))
        c.statements None
    in
    Option.iter (fun (sql, s, _) -> forget t link sql s) oldest
  end;
  Hashtbl.replace c.statements sql (s, ref (used c))

(* [DISCARD ALL] and [DEALLOCATE] by the caller invalidate the cache; the
   tag does not name which statement, so all are dropped. *)
let dropped_by t link tag =
  match Tag.command tag with
  | "DISCARD ALL" | "DEALLOCATE ALL" -> Hashtbl.reset link.cache.statements
  | "DEALLOCATE" ->
      let names =
        Hashtbl.fold
          (fun _ (s, _) names -> s.name :: names)
          link.cache.statements []
      in
      Hashtbl.reset link.cache.statements;
      close_statements t link names
  | _ -> ()

(* 0A000 "cached plan must not change result type", identified by the
   routine field since the message is localised. *)
let stale = function
  | Server e ->
      String.equal (Server_error.sqlstate e) "0A000"
      && Option.equal String.equal (Server_error.field e 'R')
           (Some "RevalidateCachedQuery")
  | Refused _ | Timeout | Closed | Io _ | Protocol _ -> false

type use =
  | Unnamed  (** the cache is off: the unnamed statement, parsed each time *)
  | First of string * statement
      (** its first use on this link, which parses and describes it *)
  | Again of string * statement  (** parsed already, or being parsed *)

(* A new statement enters the cache only after encoding succeeds. *)
let prepare link sql =
  if link.cache.capacity = 0 then
    (Unnamed, [ P.Parse { name = ""; query = sql } ])
  else
    match cached link sql with
    | Some s -> (Again (sql, s), [])
    | None ->
        let c = link.cache in
        c.named <- c.named + 1;
        (* Not s1, which a caller's own PREPARE may use. *)
        let s =
          {
            name = Printf.sprintf "postgres_eio_%d" c.named;
            prepared = Parsing;
          }
        in
        ( First (sql, s),
          [
            P.Parse { name = s.name; query = sql };
            P.Describe { target = P.Statement; name = s.name };
          ] )

let name_of_use = function
  | Unnamed -> ""
  | First (_, s) | Again (_, s) -> s.name

let queue_use t link use messages reply =
  let bytes = String.concat "" (List.map encode messages) in
  (match use with
  | First (sql, s) -> remember t link sql s
  | Unnamed | Again _ -> ());
  enqueue link bytes reply

let first failed e = match failed with Some _ -> failed | None -> Some e

(* Keeps the cache in sync with the server: a refused Parse has nothing to
   close, a stale plan is closed for reparsing, and pipelined uses after a
   refused Parse report that refusal, not "statement does not exist". *)
let concluded t link use ~parsed failed =
  match (use, failed) with
  | Unnamed, _ | (First _ | Again _), None -> failed
  | First (sql, s), Some e when not parsed ->
      s.prepared <- Unparsed e;
      drop link sql s;
      failed
  | (First (sql, s) | Again (sql, s)), Some e when stale e ->
      forget t link sql s;
      failed
  | Again (_, { prepared = Unparsed e; _ }), Some _ -> Some e
  | (First _ | Again _), Some _ -> failed

(* Describe reports text; apply the formats the Bind asked for. *)
let as_bound described (results : P.format array) =
  if Array.length results = 0 then described
  else
    Array.mapi
      (fun i (c : Column.t) ->
        if i < Array.length results then { c with format = results.(i) } else c)
      described

(* 54.2.3: always read to ReadyForQuery; after an error the server skips
   to the Sync. *)
let read_statement t link use ~results ~columns ~init ~row =
  let rec loop acc tag failed parsed =
    match message t link with
    | P.Parse_complete -> loop acc tag failed true
    | P.Parameter_description _ -> loop acc tag failed parsed
    | (P.Row_description _ | P.No_data) as m ->
        let described =
          match m with
          | P.Row_description fields -> columns_of fields
          | _ -> [||]
        in
        (match use with
        | First (_, s) -> s.prepared <- Described described
        | Unnamed -> columns described
        | Again _ ->
            out_of_turn "54.2.3 Extended Query" m
              "for a statement described already");
        loop acc tag failed parsed
    | P.Bind_complete as m ->
        (match use with
        | First (_, s) | Again (_, s) -> (
            match s.prepared with
            | Described described -> columns (as_bound described results)
            | Parsing | Unparsed _ ->
                out_of_turn "54.2.3 Extended Query" m
                  "for a statement never described")
        | Unnamed -> ());
        loop acc tag failed parsed
    | P.Data_row cells -> (
        match failed with
        | Some _ -> loop acc tag failed parsed
        | None -> loop (row acc cells) tag failed parsed)
    | P.Command_complete s ->
        let tag = Tag.of_string s in
        dropped_by t link tag;
        loop acc tag failed parsed
    | P.Empty_query_response -> loop acc Tag.empty failed parsed
    | P.Error_response f ->
        loop acc tag (first failed (Server (Server_error.of_fields f))) parsed
    | P.Copy_in_response _ ->
        refuse_copy_in t link ~extended:true;
        loop acc tag (first failed copy_refused) parsed
    | P.Copy_out_response _ | P.Copy_data _ | P.Copy_done ->
        loop acc tag (first failed copy_refused) parsed
    | P.Ready_for_query s -> (
        t.status <- s;
        match concluded t link use ~parsed failed with
        | Some e -> Error e
        | None -> Ok (acc, tag))
    | m -> out_of_turn "54.2.3 Extended Query" m "in answer to a statement"
  in
  loop init Tag.empty None false

let bind ?(results = [||]) name params =
  P.Bind
    { portal = ""; statement = name; params; results = Array.to_list results }

let execute = P.Execute { portal = ""; max_rows = 0 }

let queue_statement t link sql ~params ~results ~columns ~init ~row ~answered =
  let use, begun = prepare link sql in
  let described =
    match use with
    | Unnamed -> [ P.Describe { target = P.Portal; name = "" } ]
    | First _ | Again _ -> []
  in
  let reply =
    {
      read =
        (fun () ->
          answered (read_statement t link use ~results ~columns ~init ~row));
      lost = (fun e -> answered (Error e));
    }
  in
  queue_use t link use
    (begun
    @ (bind ~results (name_of_use use) params :: described)
    @ [ execute; P.Sync ])
    reply;
  reply

let binary_needs_the_cache =
  Refused
    "binary results need the statement cache, which is off on this connection: \
     a statement's columns have to be known before it is bound"

(* Binary results need column types before Bind, so a new statement costs
   one extra round trip to describe it; cached runs cost none. *)
let described_for_binary t link sql =
  drive t link;
  let held () =
    match cached link sql with
    | Some { prepared = Described columns; _ } -> Some columns
    | Some { prepared = Parsing | Unparsed _; _ } | None -> None
  in
  match held () with
  | Some columns -> Ok columns
  | None -> (
      let use, begun = prepare link sql in
      let answer = ref (Error Closed) in
      let reply =
        {
          read =
            (fun () ->
              answer :=
                Result.map ignore
                  (read_statement t link use ~results:[||] ~columns:ignore
                     ~init:() ~row:(fun () _ -> ())));
          lost = (fun e -> answer := Error e);
        }
      in
      queue_use t link use (begun @ [ P.Sync ]) reply;
      drive ~through:reply t link;
      match (!answer, held ()) with
      | Error e, _ -> Error e
      | Ok (), Some columns -> Ok columns
      | Ok (), None ->
          fail
            (Protocol
               "54.2.3 Extended Query: a statement described with no \
                RowDescription or NoData"))

let formats_for (columns : Column.t array) =
  Array.map
    (fun (c : Column.t) -> if Value.binary c.type_oid then P.Binary else P.Text)
    columns

(* Retry a stale plan once, only outside a transaction: inside, the
   transaction is already aborted. *)
let once_more_if_stale t answer again =
  match (answer, t.status) with
  | Error e, P.Idle when stale e -> again ()
  | answer, (P.Idle | P.In_transaction | P.Failed) -> answer

let query ?(columns = ignore) ?(binary = false) t sql ~params ~init ~row =
  run t (fun link ->
      let attempt () =
        let results =
          if not binary then Ok [||]
          else if link.cache.capacity = 0 then Error binary_needs_the_cache
          else Result.map formats_for (described_for_binary t link sql)
        in
        match results with
        | Error e -> Error e
        | Ok results ->
            let answer = ref (Error Closed) in
            let reply =
              queue_statement t link sql ~params ~results ~columns ~init ~row
                ~answered:(fun a -> answer := a)
            in
            drive ~through:reply t link;
            !answer
      in
      once_more_if_stale t (attempt ()) attempt)

(* One Sync for all rows: a single implicit transaction. *)
let read_many t link use =
  let rec loop tags failed parsed =
    match message t link with
    | P.Parse_complete -> loop tags failed true
    | P.Parameter_description _ | P.Bind_complete | P.Data_row _ ->
        loop tags failed parsed
    | (P.Row_description _ | P.No_data) as m ->
        let described =
          match m with
          | P.Row_description fields -> columns_of fields
          | _ -> [||]
        in
        (match use with
        | First (_, s) -> s.prepared <- Described described
        | Unnamed | Again _ ->
            out_of_turn "54.2.3 Extended Query" m
              "for a statement not described");
        loop tags failed parsed
    | P.Command_complete s ->
        let tag = Tag.of_string s in
        dropped_by t link tag;
        loop (tag :: tags) failed parsed
    | P.Empty_query_response -> loop (Tag.empty :: tags) failed parsed
    | P.Error_response f ->
        loop tags (first failed (Server (Server_error.of_fields f))) parsed
    | P.Copy_in_response _ ->
        refuse_copy_in t link ~extended:true;
        loop tags (first failed copy_refused) parsed
    | P.Copy_out_response _ | P.Copy_data _ | P.Copy_done ->
        loop tags (first failed copy_refused) parsed
    | P.Ready_for_query s -> (
        t.status <- s;
        match concluded t link use ~parsed failed with
        | Some e -> Error e
        | None -> Ok (List.rev tags))
    | m -> out_of_turn "54.2.3 Extended Query" m "in answer to a batch"
  in
  loop [] None false

let execute_many t sql ~params =
  run t (fun link ->
      match params with
      | [] -> Ok []
      | rows ->
          let attempt () =
            let use, begun = prepare link sql in
            let name = name_of_use use in
            let answer = ref (Error Closed) in
            let reply =
              {
                read = (fun () -> answer := read_many t link use);
                lost = (fun e -> answer := Error e);
              }
            in
            queue_use t link use
              (begun
              @ List.concat_map
                  (fun params -> [ bind name params; execute ])
                  rows
              @ [ P.Sync ])
              reply;
            drive ~through:reply t link;
            !answer
          in
          once_more_if_stale t (attempt ()) attempt)

let read_script t link =
  let rec loop failed =
    match message t link with
    | P.Row_description _ | P.Data_row _ | P.Empty_query_response
    | P.Copy_data _ | P.Copy_done ->
        loop failed
    | P.Command_complete s ->
        dropped_by t link (Tag.of_string s);
        loop failed
    | P.Error_response f ->
        loop (first failed (Server (Server_error.of_fields f)))
    | P.Copy_in_response _ ->
        refuse_copy_in t link ~extended:false;
        loop (first failed copy_refused)
    | P.Copy_out_response _ -> loop (first failed copy_refused)
    | P.Ready_for_query s -> (
        t.status <- s;
        match failed with Some e -> Error e | None -> Ok ())
    | m -> out_of_turn "54.2.2 Simple Query" m "in answer to a query"
  in
  loop None

let script t sql =
  run t (fun link ->
      let bytes = encode (P.Query sql) in
      let answer = ref (Error Closed) in
      let reply =
        {
          read = (fun () -> answer := read_script t link);
          lost = (fun e -> answer := Error e);
        }
      in
      enqueue link bytes reply;
      drive ~through:reply t link;
      !answer)

type description = { parameters : int list; columns : Column.t array }

(* Uses the unnamed statement, so the cache is untouched. *)
let read_description t link =
  let rec loop parameters columns failed =
    match message t link with
    | P.Parse_complete -> loop parameters columns failed
    | P.Parameter_description oids -> loop oids columns failed
    | P.Row_description fields -> loop parameters (columns_of fields) failed
    | P.No_data -> loop parameters [||] failed
    | P.Error_response f ->
        loop parameters columns
          (first failed (Server (Server_error.of_fields f)))
    | P.Ready_for_query s -> (
        t.status <- s;
        match failed with
        | Some e -> Error e
        | None -> Ok { parameters; columns })
    | m -> out_of_turn "54.2.3 Extended Query" m "in answer to a Describe"
  in
  loop [] [||] None

let describe t sql =
  run t (fun link ->
      let bytes =
        String.concat ""
          [
            encode (P.Parse { name = ""; query = sql });
            encode (P.Describe { target = P.Statement; name = "" });
            encode P.Sync;
          ]
      in
      let answer = ref (Error Closed) in
      let reply =
        {
          read = (fun () -> answer := read_description t link);
          lost = (fun e -> answer := Error e);
        }
      in
      enqueue link bytes reply;
      drive ~through:reply t link;
      !answer)

module Pipeline = struct
  type conn = t

  type 'a answer = {
    conn : conn;
    mutable reply : reply option;
    mutable result : ('a, error) result option;
  }

  let query ?(columns = ignore) conn sql ~params ~init ~row =
    let a = { conn; reply = None; result = None } in
    let answered r = a.result <- Some r in
    (match conn.link with
    | None -> answered (Error Closed)
    | Some _ when conn.refusing -> answered (Error abandoned)
    | Some link -> (
        match
          queue_statement conn link sql ~params ~results:[||] ~columns ~init
            ~row ~answered
        with
        | reply -> a.reply <- Some reply
        | exception Fail e -> answered (Error e)));
    a

  let get a =
    (match (a.result, a.reply) with
    | None, Some reply ->
        ignore
          (run ~sending:false a.conn (fun link ->
               drive ~through:reply a.conn link;
               Ok ())
            : (unit, error) result)
    | (Some _ | None), _ -> ());
    match a.result with Some r -> r | None -> Error Closed

  (* Also catches a session the server ended while nobody was reading. *)
  let drain conn =
    run ~sending:false conn (fun link ->
        drive conn link;
        unsolicited conn link;
        Ok ())

  let flush conn =
    run conn (fun link ->
        let bytes = take_queued conn link in
        if String.length bytes > 0 then write conn link bytes;
        Ok ())
end

(* COPY *)

(* 54.2.6: COPY uses the extended protocol so it is exactly one statement.
   Copy-in mode ignores the Sync, so another follows the data. A COPY is
   not pipelined: earlier answers are read first. *)
let copy_statement sql =
  String.concat ""
    [
      encode (P.Parse { name = ""; query = sql });
      encode (bind "" []);
      encode execute;
      encode P.Sync;
    ]

(* Only the answer reveals the statement's kind, so it has already run. *)
let not_a_copy direction =
  Refused
    (Printf.sprintf
       "the statement is not a COPY %s, and it has run: only the server's \
        answer says what a statement was"
       direction)

let rec answer t link =
  match message t link with
  | P.Parse_complete | P.Bind_complete -> answer t link
  | m -> m

(* Reads to ReadyForQuery keeping the tag and the first error. *)
let rec copy_rest ?(awaited = true) ?(refused = ignore) t link ~tag ~failed m =
  let continue ~tag ~failed =
    copy_rest ~awaited ~refused t link ~tag ~failed (message ~awaited t link)
  in
  match m with
  | P.Command_complete s -> continue ~tag:(Tag.of_string s) ~failed
  | P.Parse_complete | P.Bind_complete | P.No_data | P.Row_description _
  | P.Data_row _ | P.Empty_query_response | P.Copy_out_response _
  | P.Copy_data _ | P.Copy_done ->
      continue ~tag ~failed
  | P.Copy_in_response _ ->
      refuse_copy_in t link ~extended:true;
      continue ~tag ~failed
  | P.Error_response f ->
      refused ();
      continue ~tag ~failed:(first failed (Server (Server_error.of_fields f)))
  | P.Ready_for_query s -> (
      t.status <- s;
      match failed with Some e -> Error e | None -> Ok tag)
  | m -> out_of_turn "54.2.6 COPY Operations" m "in answer to a COPY"

type 'a outcome = Answered of 'a | Raised of exn * Printexc.raw_backtrace

(* Data is written while answers are read: the server may reply per row
   (e.g. trigger notices), and writing alone could deadlock. If [send]
   raises, the COPY is ended cleanly with CopyFail and the exception is
   re-raised after, so the connection survives.

   The timeout counts only from the last byte written, since the server
   is silent while data flows. *)
let copy_in_with t sql send =
  let copied =
    run t (fun link ->
        drive t link;
        write t link (copy_statement sql);
        match answer t link with
        | P.Copy_in_response _ -> (
            let server_refused = ref false in
            let finish bytes =
              write t link bytes;
              if link.waiting = 0 then link.moved <- now t;
              link.waiting <- link.waiting + 1
            in
            let fail_copy () =
              finish (encode (P.Copy_fail copy_failed) ^ encode P.Sync)
            in
            let writer () =
              match send link ~stop:(fun () -> !server_refused) with
              | () ->
                  finish
                    (if !server_refused then encode P.Sync
                     else encode P.Copy_done ^ encode P.Sync);
                  `Sent
              | exception Fail (Refused _ as e) ->
                  fail_copy ();
                  `Refused e
              | exception (Fail _ as ex) -> raise ex
              | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
              | exception ex ->
                  let bt = Printexc.get_raw_backtrace () in
                  fail_copy ();
                  `Raised (ex, bt)
            in
            let reader () =
              copy_rest ~awaited:false
                ~refused:(fun () -> server_refused := true)
                t link ~tag:Tag.empty ~failed:None
                (message ~awaited:false t link)
            in
            let sent, answered = Eio.Fiber.pair writer reader in
            link.waiting <- link.waiting - 1;
            match sent with
            | `Sent -> Result.map (fun tag -> Answered tag) answered
            | `Refused e -> Error e
            | `Raised (ex, bt) -> Ok (Raised (ex, bt)))
        | P.Error_response _ as m ->
            Result.map
              (fun tag -> Answered tag)
              (copy_rest t link ~tag:Tag.empty ~failed:None m)
        | m ->
            Result.map
              (fun tag -> Answered tag)
              (copy_rest t link ~tag:Tag.empty
                 ~failed:(Some (not_a_copy "FROM STDIN"))
                 m))
  in
  match copied with
  | Ok (Answered tag) -> Ok tag
  | Ok (Raised (ex, bt)) -> Printexc.raise_with_backtrace ex bt
  | Error e -> Error e

(* Bytes per CopyData: enough that one write carries many rows. *)
let copy_chunk = 65536

let copy_in t sql source =
  copy_in_with t sql (fun link ~stop ->
      let buf = Cstruct.create copy_chunk in
      let rec go () =
        if not (stop ()) then
          match Eio.Flow.single_read source buf with
          | n ->
              write t link (encode (P.Copy_data (Cstruct.to_string ~len:n buf)));
              go ()
          | exception End_of_file -> ()
      in
      go ())

let identifier what name =
  if String.contains name '\000' then
    Error
      (Refused
         (Printf.sprintf "%s holds a NUL byte, which no identifier can" what))
  else Ok ("\"" ^ String.concat "\"\"" (String.split_on_char '"' name) ^ "\"")

(* COPY text: tab-separated, newline-terminated, [\N] for NULL; backslash,
   tab, newline and CR are escaped. *)
let add_row b cells =
  Array.iteri
    (fun i cell ->
      if i > 0 then Buffer.add_char b '\t';
      match cell with
      | None -> Buffer.add_string b "\\N"
      | Some v ->
          String.iter
            (function
              | '\\' -> Buffer.add_string b "\\\\"
              | '\t' -> Buffer.add_string b "\\t"
              | '\n' -> Buffer.add_string b "\\n"
              | '\r' -> Buffer.add_string b "\\r"
              | '\000' ->
                  fail
                    (Refused
                       "a value holds a NUL byte, which COPY's text format \
                        cannot carry")
              | c -> Buffer.add_char b c)
            v)
    cells;
  Buffer.add_char b '\n'

let copy_in_rows t ?schema ~table ~columns rows =
  let ( let* ) = Result.bind in
  let* target =
    let* table = identifier "the table's name" table in
    match schema with
    | None -> Ok table
    | Some s ->
        let* s = identifier "the schema's name" s in
        Ok (s ^ "." ^ table)
  in
  let* columns =
    List.fold_right
      (fun c acc ->
        let* acc = acc in
        let* c = identifier "a column's name" c in
        Ok (c :: acc))
      columns (Ok [])
  in
  let sql =
    Printf.sprintf "copy %s%s from stdin" target
      (match columns with [] -> "" | cs -> " (" ^ String.concat ", " cs ^ ")")
  in
  copy_in_with t sql (fun link ~stop ->
      let b = Buffer.create copy_chunk in
      let flush () =
        if Buffer.length b > 0 then begin
          write t link (encode (P.Copy_data (Buffer.contents b)));
          Buffer.reset b
        end
      in
      let rec go rows =
        if not (stop ()) then
          match rows () with
          | Seq.Nil -> flush ()
          | Seq.Cons (cells, rest) ->
              add_row b cells;
              if Buffer.length b >= copy_chunk then flush ();
              go rest
      in
      go rows)

let copy_out_with t sql ~init ~chunk =
  run t (fun link ->
      drive t link;
      write t link (copy_statement sql);
      match answer t link with
      | P.Copy_out_response copy ->
          let rec data acc =
            match message t link with
            | P.Copy_data d -> data (chunk copy acc d)
            | P.Copy_done ->
                Result.map
                  (fun tag -> (acc, tag))
                  (copy_rest t link ~tag:Tag.empty ~failed:None (message t link))
            | P.Error_response _ as m ->
                Result.map
                  (fun tag -> (acc, tag))
                  (copy_rest t link ~tag:Tag.empty ~failed:None m)
            | m -> out_of_turn "54.2.6 COPY Operations" m "inside a COPY OUT"
          in
          data init
      | P.Error_response _ as m ->
          Result.map
            (fun tag -> (init, tag))
            (copy_rest t link ~tag:Tag.empty ~failed:None m)
      | m ->
          Result.map
            (fun tag -> (init, tag))
            (copy_rest t link ~tag:Tag.empty
               ~failed:(Some (not_a_copy "TO STDOUT"))
               m))

let copy_out t sql ~init ~chunk =
  copy_out_with t sql ~init ~chunk:(fun _ acc d -> chunk acc d)

(* Backslash + [b f n r t v], 1-3 octal digits, or [x] + 1-2 hex digits;
   before anything else, the character itself. *)
let unescape field =
  if String.equal field "\\N" then None
  else if not (String.contains field '\\') then Some field
  else
    let n = String.length field in
    let b = Buffer.create n in
    let value c =
      match c with
      | '0' .. '9' -> Some (Char.code c - Char.code '0')
      | 'a' .. 'f' -> Some (Char.code c - Char.code 'a' + 10)
      | 'A' .. 'F' -> Some (Char.code c - Char.code 'A' + 10)
      | _ -> None
    in

    let digits i ~max ~base =
      let rec go j v =
        match if j < n && j - i < max then value field.[j] else None with
        | Some d when d < base -> go (j + 1) ((v * base) + d)
        | Some _ | None -> (j, v)
      in
      go i 0
    in
    let hex c = Option.is_some (value c) in
    let rec go i =
      if i >= n then ()
      else if (not (Char.equal field.[i] '\\')) || i + 1 = n then (
        Buffer.add_char b field.[i];
        go (i + 1))
      else
        let escaped c =
          Buffer.add_char b c;
          go (i + 2)
        in
        match field.[i + 1] with
        | 'b' -> escaped '\b'
        | 'f' -> escaped '\012'
        | 'n' -> escaped '\n'
        | 'r' -> escaped '\r'
        | 't' -> escaped '\t'
        | 'v' -> escaped '\011'
        | '0' .. '7' ->
            let j, v = digits (i + 1) ~max:3 ~base:8 in
            Buffer.add_char b (Char.chr (v land 0xff));
            go j
        | 'x' when i + 2 < n && hex field.[i + 2] ->
            let j, v = digits (i + 2) ~max:2 ~base:16 in
            Buffer.add_char b (Char.chr v);
            go j
        | c -> escaped c
    in
    go 0;
    Some (Buffer.contents b)

(* Rows may span CopyData messages: the server's don't, but the spec does
   not promise it. *)
let copy_out_rows t ~select ~init ~row =
  let held = Buffer.create 256 in
  let chunk (copy : P.copy) acc data =
    let width = List.length copy.columns in
    let rec lines acc from =
      match String.index_from_opt data from '\n' with
      | None ->
          Buffer.add_substring held data from (String.length data - from);
          acc
      | Some j ->
          Buffer.add_substring held data from (j - from);
          let line = Buffer.contents held in
          Buffer.clear held;
          let cells =
            if width = 0 then [||]
            else
              Array.of_list (List.map unescape (String.split_on_char '\t' line))
          in
          lines (row acc cells) (j + 1)
    in
    lines acc 0
  in
  match
    copy_out_with t (Printf.sprintf "copy (%s) to stdout" select) ~init ~chunk
  with
  | Ok _ when Buffer.length held > 0 ->
      let e = Protocol "54.2.6 COPY Operations: the data ended inside a row" in
      break t e;
      Error e
  | answer -> answer

(* Lifecycle *)

let status t = t.status
let parameter t name = List.assoc_opt name t.settings
let closed t = Option.is_none t.link
let statement_cache t = t.statement_cache
let timeout t = t.timeout_s

(* Only on change: the pool restores the timeout on every return. *)
let set_timeout t s =
  if not (Option.equal Float.equal s t.timeout_s) then begin
    t.timeout_s <- s;
    Eio.Condition.broadcast t.changed
  end

(* 54.2.8: a separate connection to the same server. Waits for the server
   to close it, so the request was read when this returns. Safe to call
   from another fiber. *)
let cancel t =
  match t.reached with
  | None -> Ok ()
  | Some { endpoint; address; secure } -> (
      match
        Eio.Switch.run (fun sw ->
            bounded ~clock:t.clock t.timeout_s (fun () ->
                let socket =
                  (guard (fun () -> Eio.Net.connect ~sw t.net address)
                    :> socket)
                in
                let flow =
                  match (secure, t.tls) with
                  | false, _ | true, None -> socket
                  | true, Some config -> (
                      match t.conninfo.ssl_negotiation with
                      | C.Direct ->
                          fst (handshake t config endpoint socket ~direct:true)
                      | C.Postgres -> (
                          match negotiate t config endpoint socket with
                          | Encrypted (flow, _) -> flow
                          | Declined | Errored ->
                              fail (Refused "the server no longer offers TLS")))
                in
                guard (fun () ->
                    Eio.Flow.copy_string
                      (encode (P.Cancel_request { pid = t.pid; key = t.key }))
                      flow);
                let buf = Cstruct.create 64 in
                let rec until_closed () =
                  match Eio.Flow.single_read flow buf with
                  | _ -> until_closed ()
                  | exception End_of_file -> ()
                in
                guard until_closed))
      with
      | () -> Ok ()
      | exception Fail e -> Error e)

let abandon t =
  t.refusing <- true;
  cancel t

let resume t = t.refusing <- false

(* The Terminate is bounded: a server that stopped reading never takes it. *)
let close t =
  match t.link with
  | None -> ()
  | Some link ->
      (try
         bounded ~clock:t.clock t.timeout_s (fun () ->
             guard (fun () ->
                 Eio.Flow.copy_string (encode P.Terminate) link.flow))
       with Fail _ -> ());
      break t Closed

(* Same target, credentials and parameters; the statement cache starts
   empty. *)
let reset t =
  close t;
  match establish t with
  | link ->
      linked t link;
      Ok ()
  | exception Fail e -> Error e

(* LISTEN/NOTIFY *)

(* Postgres's limit, checked before sending. *)
let payload_limit = 8000

let notify t ~channel payload =
  if String.length payload >= payload_limit then
    Error
      (Refused
         (Printf.sprintf
            "a notification's payload of %d bytes, where Postgres takes fewer \
             than %d"
            (String.length payload) payload_limit))
  else
    Result.map ignore
      (query t "select pg_notify($1, $2)" ~params:[ Some channel; Some payload ]
         ~init:() ~row:(fun () _ -> ()))

(* Waits on socket readiness, bounded by [seconds], never on a cancellable
   read: tls-eio stores a cancelled read's exception as the session error
   and raises it on the next write, which broke every TLS listener at its
   first silence. Once bytes arrive, the read runs under the normal
   timeout. Without a descriptor, a plain socket is read under the bound;
   a TLS one waits unbounded. *)
let heard_within t ~seconds =
  run t (fun link ->
      drive t link;
      let within f =
        match
          Eio.Time.Timeout.run (Eio.Time.Timeout.seconds t.clock seconds) f
        with
        | Ok n -> Some n
        | Error `Timeout -> None
      in
      let took n =
        P.feed link.reader (Cstruct.sub link.buf 0 n);
        unsolicited t link;
        Ok true
      in
      let read () =
        waited t link (fun () -> Eio.Flow.single_read link.flow link.buf)
      in
      match Eio_unix.Resource.fd_opt link.socket with
      | Some fd -> (
          match
            within (fun () ->
                Eio_unix.Fd.use_exn "heard_within" fd Eio_unix.await_readable;
                Ok ())
          with
          | None -> Ok false
          | Some () -> took (read ()))
      | None when not link.secure -> (
          match
            within (fun () ->
                Ok (guard (fun () -> Eio.Flow.single_read link.flow link.buf)))
          with
          | None -> Ok false
          | Some n -> took n)
      | None -> took (read ()))

module Listener = struct
  type conn = t

  type nonrec notification = notification = {
    channel : string;
    payload : string;
    pid : int;
  }

  type event = Notification of notification | Reconnected

  type t = {
    conn : conn;
    heard : notification Queue.t;
    heartbeat_s : float;
    (* For re-listening after reconnect. *)
    mutable channels : string list;
    mutable stopped : bool;
  }

  let ( let* ) = Result.bind

  let connect ~sw ~net ~clock ?(parameters = []) ?(timeout_s = 30.)
      ?(heartbeat_s = 10.) conninfo =
    let heard = Queue.create () in
    Result.map
      (fun conn -> { conn; heard; heartbeat_s; channels = []; stopped = false })
      (open_connection ~sw ~net ~clock ~parameters ~timeout_s ~statement_cache:0
         ~heard:(Some heard) conninfo)

  (* Quoted, so the name is case-sensitive. *)
  let command verb channel =
    let* name = identifier "a channel's name" channel in
    Ok (verb ^ " " ^ name)

  let listen t channel =
    let* sql = command "listen" channel in
    let* () = script t.conn sql in
    if not (List.exists (String.equal channel) t.channels) then
      t.channels <- t.channels @ [ channel ];
    Ok ()

  let unlisten t channel =
    let* sql = command "unlisten" channel in
    let* () = script t.conn sql in
    t.channels <- List.filter (fun c -> not (String.equal c channel)) t.channels;
    Ok ()

  (* Transport failures retry with backoff (the server may be restarting):
     at once, then doubling from a second, so a restart is caught quickly,
     up to half a minute, so a long outage is not hammered. A server refusal
     is returned. *)
  let first_retry_s = 1.
  let last_retry_s = 30.

  let reconnect t =
    let again () =
      let* () = reset t.conn in
      List.fold_left
        (fun acc channel ->
          let* () = acc in
          let* sql = command "listen" channel in
          script t.conn sql)
        (Ok ()) t.channels
    in
    let rec attempt wait_s =
      match again () with
      | Ok () -> Ok Reconnected
      | Error (Server _ | Refused _) as refused -> refused
      | Error ((Timeout | Closed | Io _ | Protocol _) as e) ->
          Log.warn (fun m ->
              m "a listener could not reconnect, and tries again in %gs: %s"
                wait_s (error_to_string e));
          Eio.Time.Mono.sleep t.conn.clock wait_s;
          attempt (Float.min last_retry_s (wait_s *. 2.))
    in
    attempt first_retry_s

  let lost t e =
    Log.warn (fun m ->
        m "a listener lost its connection, and reconnects: %s"
          (error_to_string e));
    reconnect t

  (* Buffered notifications first; after a silent heartbeat, an empty query
   proves the server is alive. *)
  let rec next t =
    if t.stopped then Error Closed
    else
      match Queue.take_opt t.heard with
      | Some n -> Ok (Notification n)
      | None when closed t.conn -> reconnect t
      | None -> (
          match heard_within t.conn ~seconds:t.heartbeat_s with
          | Ok true -> next t
          | Ok false -> (
              match script t.conn "" with
              | Ok () -> next t
              | Error e -> lost t e)
          | Error e -> lost t e)

  let close t =
    t.stopped <- true;
    close t.conn
end
