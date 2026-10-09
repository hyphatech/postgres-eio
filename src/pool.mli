(** A fixed-size connection pool.

    All connections are made by {!create}, so a refused connection fails at
    startup rather than in the middle of a request. One pool serves borrowers on
    every domain.

    Every lend is clean: no open transaction, no [LISTEN], the original timeout,
    and by default none of a previous borrower's session state (settings,
    temporary tables, cursors, advisory locks). Use a {!Postgres_eio.Listener}
    for notifications. *)

type t

type error =
  [ `Busy  (** no connection came free within the wait *)
  | `Closed  (** the pool is closed *) ]

val error_to_string : error -> string
(** A sentence safe to log. *)

val create :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.Mono.t ->
  ?parameters:(string * string) list ->
  ?timeout_s:float ->
  ?statement_cache:int ->
  ?size:int ->
  ?wait_s:float ->
  ?reset:bool ->
  ?max_lifetime_s:float ->
  ?idle_check_s:float ->
  Conninfo.t ->
  (t, Connection.error) result
(** Opens [size] (8) connections, and at least one, as {!Postgres_eio.connect}
    does, or returns the first error after closing those already open. [wait_s]
    (5) is the default borrow wait.

    On return, a reset is sent but not awaited: [DISCARD ALL] minus prepared
    statements and plans, which borrowers share
    ([set session authorization default], [select pg_advisory_unlock_all()],
    [close all], [unlisten *] except on a standby, [reset all], [discard temp],
    [discard sequences]). The next lend reads its answer, usually already
    arrived, and replaces the connection if the session died meanwhile.
    [~reset:false] keeps session state, except that an open transaction is
    rolled back and [LISTEN] ended regardless: a pooled connection never
    listens.

    A daemon fiber on [sw] checks idle connections a few times per
    [min idle_check_s max_lifetime_s]. Connections past [max_lifetime_s] (1800,
    ±10%) are replaced, the new one connected before the old is removed.
    Connections idle past [idle_check_s] (60) are pinged with an empty query,
    while another is idle, and replaced if it fails. Borrowed connections are
    never touched. *)

val use : ?wait_s:float -> t -> (Connection.t -> 'a) -> ('a, [> error ]) result
(** Borrows a connection, runs [f] on the calling fiber, and returns it, even if
    [f] raises. [`Busy] if none came free within the wait, and [`Closed] at once
    if the pool is closed, or closes while the borrow waits.

    A connection whose reset failed or that was closed is reconnected on lend.
    If that fails, a [warn] is logged and its first statement returns [Closed].
    Unread pipelined answers are drained when the borrow ends. A row function
    that raises while they are closes the connection, which still goes back and
    is made again at the next lend, and its exception reaches the caller as it
    was raised, unless [f] raised first.

    The wait is cancellable, and so is [f]: an Eio cancellation stops [f] at
    whatever it is waiting on, the server or anything else, and propagates from
    [use] at once. The connection then goes back closed, to be made again at the
    next lend: its running statement is first cancelled at the server
    ({!Postgres_eio.cancel}), the request given the pool's timeout even if the
    borrower lifted its own, and at most 5 s for a statement cut off midway; its
    transaction rolls back, and statements it queued but had not sent are never
    sent. Only that cancel request and the give-back are shielded from the
    cancellation.

    Waits over 100 ms and borrows held over 250 ms log a [warn] on
    [postgres-eio.pool]. *)

type stats = {
  size : int;  (** connections the pool keeps *)
  idle : int;  (** of them, not borrowed *)
  waiting : int;  (** borrows waiting for one *)
  replaced : int;  (** connections replaced by housekeeping since creation *)
}

val stats : t -> stats
(** For a health endpoint. *)

val close : t -> unit
(** Closes idle connections now and borrowed ones when returned, never under a
    running transaction. A borrow waiting, and every one after, returns
    [`Closed]. Housekeeping stops at its next pass. *)
