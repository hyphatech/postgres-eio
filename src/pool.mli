(** A fixed-size connection pool.

    All connections are made by {!create}, so a refused connection fails at
    startup rather than in the middle of a request.

    Every lend is clean: no open transaction, none of a previous borrower's
    session state (settings, temporary tables, cursors, advisory locks,
    [LISTEN]), and the original timeout. Use a {!Postgres_eio.Listener} for
    notifications. *)

type t

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
(** Opens [size] (8) connections as {!Postgres_eio.connect} does, or returns the
    first error after closing those already open. [wait_s] (5) is the default
    borrow wait.

    On return, a reset is sent but not awaited: [DISCARD ALL] minus prepared
    statements and plans, which borrowers share
    ([set session authorization default], [select pg_advisory_unlock_all()],
    [close all], [unlisten *] except on a standby, [reset all], [discard temp],
    [discard sequences]). The next lend reads its answer, usually already
    arrived, and replaces the connection if the session died meanwhile.
    [~reset:false] keeps session state; an open transaction is rolled back
    regardless.

    A daemon fiber on [sw] checks idle connections a few times per
    [min idle_check_s max_lifetime_s]. Connections past [max_lifetime_s] (1800,
    ±10%) are replaced, the new one connected before the old is removed.
    Connections idle past [idle_check_s] (60) are pinged with an empty query,
    while another is idle, and replaced if it fails. Borrowed connections are
    never touched. *)

val use :
  ?wait_s:float -> t -> (Connection.t -> 'a) -> ('a, [> `Busy of float ]) result
(** Borrows a connection, runs [f] on the calling fiber, and returns it, even if
    [f] raises. [`Busy] if none came free within the wait.

    A connection whose reset failed or that was closed is reconnected on lend.
    If that fails, a [warn] is logged and its first statement returns [Closed].
    Unread pipelined answers are drained when the borrow ends.

    The wait is cancellable. [f] is shielded from Eio cancellation so it never
    stops mid-protocol; instead, cancelling cancels the running statement at the
    server and refuses later ones ({!Postgres_eio.abandon}), so [f] fails fast
    and its transaction rolls back.

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
    running transaction. Housekeeping stops at its next pass. *)
