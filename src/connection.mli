(** A connection to Postgres.

    Use a connection from one fiber at a time: there is no locking. Only
    {!cancel} and {!abandon} may be called from another fiber.

    Every failure is a value. Driver errors and logs never contain parameters,
    passwords, sign-in exchanges or message bytes. The [postgres-eio] log source
    has a [debug] line per connection and logs notices at their own level.
    Server errors are the server's words; see {!Server_error.to_string}. *)

type t

type error =
  | Server of Server_error.t  (** the server refused, and said why *)
  | Refused of string
      (** refused by the driver: an unsafe sign-in, an untrusted certificate, a
          value it cannot send *)
  | Timeout  (** the connection's timeout passed; the connection is closed *)
  | Closed  (** the connection is closed, or the server closed it *)
  | Io of string  (** the socket or TLS failed; the connection is closed *)
  | Protocol of string
      (** the server broke the protocol (the section is named); the connection
          is closed *)

val error_to_string : error -> string
(** A sentence safe to log. *)

val connect :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.Mono.t ->
  ?parameters:(string * string) list ->
  ?timeout_s:float ->
  ?statement_cache:int ->
  Conninfo.t ->
  (t, error) result
(** Connects, negotiates TLS per [sslmode], signs in and starts up. The socket,
    and any {!reset} opens, live on [sw].

    [parameters] are startup parameters, e.g. [("statement_timeout", "10s")],
    re-sent on every {!reset}, so they last for the connection's life.

    [timeout_s] (30) is the longest the connection waits on the server for bytes
    to move, in either direction; the caller's row function is not timed.
    Connecting uses [connect_timeout] if set, else [timeout_s]. Bound statement
    runtime with [statement_timeout]; for statements that wait longer than
    [timeout_s], raise it with {!set_timeout}.

    [statement_cache] (256) is how many statements stay parsed, LRU by SQL text,
    emptied by {!reset}. [0] disables it, for poolers without named statements
    (pgbouncer before 1.21 in transaction mode). *)

(** {1 Statements}

    A cached statement is parsed once: the first run sends Parse with the run,
    at no extra round trip, and later runs only bind. If its result type changed
    (e.g. the table was altered) it is reparsed and retried once outside a
    transaction; inside one, the error is returned. [DISCARD ALL] or
    [DEALLOCATE] empties the cache.

    Answers are read in send order across {!query}, {!Pipeline}, {!execute_many}
    and {!script}. *)

val query :
  ?columns:(Column.t array -> unit) ->
  ?binary:bool ->
  t ->
  string ->
  params:string option list ->
  init:'a ->
  row:('a -> string option array -> 'a) ->
  ('a * Tag.t, error) result
(** Runs one statement by the extended protocol. [params] bind [$1], [$2], ...
    as text, [None] for NULL. [columns] is called once before any row, even with
    no rows. [row] folds each row as it arrives ([None] is NULL); rows are not
    buffered. If [row] raises, the connection is closed and the exception
    propagates.

    [binary] (false) requests binary for the types in {!Value.binary}, text for
    the rest; {!Value} decodes either. This needs column types before Bind,
    costing one extra round trip on a statement's first run, and is refused when
    the cache is off. *)

val execute_many :
  t -> string -> params:string option list list -> (Tag.t list, error) result
(** Runs one statement per parameter list in one round trip and one implicit
    transaction: if any fails, none apply. Returned rows are discarded. *)

val script : t -> string -> (unit, error) result
(** Runs one or more parameterless statements by the simple protocol, discarding
    rows.

    A COPY here or in {!query} is refused and the connection stays usable,
    unless more was pipelined behind it, in which case it is closed. Use the
    COPY functions instead. *)

type description = {
  parameters : Oid.t list;  (** inferred parameter types, [0] where unknown *)
  columns : Column.t array;  (** empty for a statement returning no rows *)
}

val describe : t -> string -> (description, error) result
(** Parameter types and result columns without running the statement. Uses the
    unnamed statement, leaving the cache untouched. *)

(** Statements sent without waiting for earlier answers.

    Each gets its own Sync, so it behaves as if sent alone: a failure does not
    stop the next, and inside [begin]/[commit] a failure aborts the transaction
    as usual. Nothing is sent until an answer is requested; then everything
    queued is written while answers are read, so no pipeline length can
    deadlock. *)
module Pipeline : sig
  type conn := t
  type 'a answer

  val query :
    ?columns:(Column.t array -> unit) ->
    conn ->
    string ->
    params:string option list ->
    init:'a ->
    row:('a -> string option array -> 'a) ->
    ('a * Tag.t) answer
  (** Queues a statement, as {!Postgres_eio.query}. Encoding errors surface in
      its answer. *)

  val get : 'a answer -> ('a, error) result
  (** Sends everything queued and reads answers up to this one. *)

  val drain : conn -> (unit, error) result
  (** Sends everything and reads every outstanding answer, so
      {!Postgres_eio.status} is current. Errors only if the connection failed
      (including a terminated backend); statement errors stay in their answers.
  *)

  val flush : conn -> (unit, error) result
  (** Sends everything without reading; whoever reads next gets the answers.
      Only for a few statements: a pipeline long enough to fill the server's
      output buffer stalls until the timeout. {!get} and {!drain} read while
      writing. *)
end

(** {1 COPY}

    Bulk data, streamed in both directions without buffering whole tables. COPY
    takes no parameters. *)

val copy_in : t -> string -> _ Eio.Flow.source -> (Tag.t, error) result
(** Runs a [COPY ... FROM STDIN], streaming the source's bytes unchanged in the
    statement's format. Any other statement is refused, after it has run.

    If reading the source raises, the COPY is failed (nothing is written), the
    connection stays usable, and the exception propagates. The server is sent a
    fixed message, never the exception. Cancellation closes the connection. *)

val copy_in_rows :
  t ->
  ?schema:string ->
  table:string ->
  columns:string list ->
  string option array Seq.t ->
  (Tag.t, error) result
(** Runs [COPY "schema"."table" ("a", "b") FROM STDIN] in text format, escaping
    each row. Cells follow [columns]' order ([None] is NULL); empty [columns]
    means all, in table order. The sequence is consumed lazily. Names are quoted
    as given, so ["Jobs"] is not [jobs].

    A NUL in a name is refused before sending; a NUL in a value fails the COPY
    with the connection still usable. A raise from the sequence behaves as in
    {!copy_in}. *)

val copy_out :
  t ->
  string ->
  init:'a ->
  chunk:('a -> string -> 'a) ->
  ('a * Tag.t, error) result
(** Runs a [COPY ... TO STDOUT], folding each CopyData into [chunk] as it
    arrives, in the statement's format. Any other statement is refused, after it
    has run. If [chunk] raises, the connection is closed and the exception
    propagates. *)

val copy_out_rows :
  t ->
  select:string ->
  init:'a ->
  row:('a -> string option array -> 'a) ->
  ('a * Tag.t, error) result
(** Runs [COPY (select) TO STDOUT], decoding each text-format row for [row]
    ([None] is NULL). Like {!query}, for very large results. *)

val status : t -> Protocol.transaction_status
(** As of the last ReadyForQuery read; with pipelined answers outstanding, call
    {!Pipeline.drain} first. *)

val parameter : t -> string -> string option
(** The latest value of a server-reported parameter, e.g. [server_version],
    [TimeZone], [DateStyle]. *)

val cancel : t -> (unit, error) result
(** From another fiber, asks the server to cancel the running statement (over a
    separate connection). It fails with SQLSTATE 57014 and its transaction
    aborts. No effect if nothing is running. *)

val reset : t -> (unit, error) result
(** Closes the connection if open and reconnects with the same target,
    credentials and startup parameters. *)

val closed : t -> bool
(** Closed by {!close} or a failure; statements return [Closed] until {!reset}.
*)

val statement_cache : t -> int
(** The cache size it was made with; [0] means no [binary] results. *)

val timeout_s : t -> float option
(** The current timeout, in seconds; [None] waits forever. *)

val set_timeout : t -> timeout_s:float option -> unit
(** For long work like a migration: [set_timeout conn ~timeout_s:None]. A pool
    restores the original timeout on return. *)

val abandon : t -> (unit, error) result
(** From another fiber, cancels the running statement and refuses later ones
    with [Refused] until {!resume}. For a lender whose borrower went away. *)

val resume : t -> unit
(** Accepts statements again after {!abandon}. *)

val close : t -> unit
(** Sends Terminate and closes. Unsent statements are dropped and outstanding
    answers become [Closed]. Idempotent. *)

(** {1 LISTEN/NOTIFY} *)

val notify : t -> channel:string -> string -> (unit, error) result
(** [select pg_notify(channel, payload)] on any connection. Delivered on commit,
    not on rollback. [channel] is case-sensitive. Payloads of 8000 bytes or more
    are refused before sending. *)

(** A dedicated connection for notifications, used from one fiber. For many
    subjects, listen on one channel and route by payload.

    A listener that stops reading fills the server's notification queue, after
    which every NOTIFY in the database fails. LISTEN does not work through
    pgbouncer in transaction mode. *)
module Listener : sig
  type t
  type notification = { channel : string; payload : string; pid : int }

  type event =
    | Notification of notification
        (** [pid] is the sending session's backend *)
    | Reconnected
        (** reconnected and re-listened; notifications in between are lost, so
            re-read any state *)

  val connect :
    sw:Eio.Switch.t ->
    net:_ Eio.Net.t ->
    clock:_ Eio.Time.Mono.t ->
    ?parameters:(string * string) list ->
    ?timeout_s:float ->
    ?heartbeat_s:float ->
    Conninfo.t ->
    (t, error) result
  (** Connects as {!Postgres_eio.connect}. [heartbeat_s] (10) is how long
      {!next} waits in silence before pinging the server. *)

  val listen : t -> string -> (unit, error) result
  (** [LISTEN], quoted: ["Jobs"] hears [pg_notify('Jobs', ...)], not an unquoted
      [NOTIFY Jobs], which Postgres folds to [jobs]. Notifications read
      meanwhile are kept for {!next}. *)

  val unlisten : t -> string -> (unit, error) result
  (** [UNLISTEN]; the channel is not restored on reconnect. *)

  val next : t -> (event, error) result
  (** Waits for the next notification, in arrival order.

      After a silent heartbeat it sends an empty query, so a dead server is
      noticed within heartbeat + timeout; no background fiber is used. A failed
      connection is reconnected, immediately then with backoff from 1 s to 30 s
      (each failure a [warn]), and {!event.Reconnected} is returned. A server
      refusal (sign-in, [LISTEN]) is returned as an error. After {!close},
      [Closed]. *)

  val close : t -> unit
  (** Closes it for good; {!next} then returns [Closed]. *)
end
