# Changes

## Unreleased

- Breaking: the words are the stack's own. `connect`'s, `Listener.connect`'s
  and `Pool.create`'s `~clock` is `~mono_clock`, `Listener.connect`'s
  `?heartbeat` is `?keep_alive`, and `reset`, which reconnects, is
  `revive`; `Pool.create`'s `?reset`, which cleans a session, keeps its
  name.
- Breaking: `Postgres_eio.error` is a polymorphic variant, as
  `Pool.use`'s errors already were, and every function that fails
  answers `[> error]`, so a connection's failures and a pool's join in
  one result. `Timeout`, `Io` and `Protocol` are one tag, `` `Lost ``:
  the statement was sent and no answer came back, so it may have run.
  `Closed` is `` `Connection `Closed `` and now means the statement was
  never sent: an answer a `close` or a failure leaves unread is
  `` `Lost ``. A connection that cannot be made, by `connect`, `revive`,
  `Listener.connect` or `Pool.create`, answers `` `Unsent `` for what was
  `Timeout`, `Io` or `Protocol`, since nothing was done. `Server` and
  `Refused` are `` `Server `` and `` `Refused ``. `Pool.error_to_string`
  prints a connection's errors as well as the pool's.
- A SCRAM sign-in whose server asks for more than a million iterations is
  refused before the first. The count was unbounded, and computing it
  never yields, so a server asking for a hundred million held the
  connect, its timeout and every fiber on its domain for over a minute.
- A `Pool.create` cancelled partway closes the connections it had made.
  They were left open, sessions held at the server, until their switch
  ended.
- `connect_timeout` bounds a host's name lookup. eio_posix looks a name
  up in a system thread no cancellation reaches, so a slow resolver held
  `connect` for as long as it took; the lookup now runs beside the wait,
  on the connection's switch, and is left to finish there. A
  `Postgres_eio.Resolver`, which `connect` and `Listener.connect` take as
  `?resolver`, does lookups on its own fiber for a connection revived on
  any domain, since Eio forks onto a switch only from its own; a pool
  keeps one for its connections, so a borrower's revive is bounded on
  every domain.
- Breaking: every connection, a `Listener`'s too, sets the settings the
  decoders read text by -- `client_encoding=UTF8`, `DateStyle=ISO`,
  `IntervalStyle=postgres` and `extra_float_digits=3` -- over a
  database's and a role's defaults. Nothing set `client_encoding`, so in a
  `LATIN1` database UTF-8 text was stored as mojibake, and with
  `extra_float_digits=0` a float read back rounded. A parameter or an
  `options` setting giving one of them another value is `` `Refused ``;
  `client_encoding` is compared by encoding, so `UTF-8` or `Unicode` is
  `UTF8`.
- Breaking: with no `sslmode`, a host on another machine needs TLS, and
  only a host on this one -- `localhost`, 127.0.0.0/8, `::1` or a Unix
  socket, judged by `hostaddr` when given -- is `prefer`. Every host was
  `prefer`, so a server that declined TLS, or a network that stripped
  it, had the password and every query sent in the clear. A server that
  offers no TLS is refused with an error naming `sslmode=disable` and
  `prefer`. `sslnegotiation=direct` with no `sslmode` needs TLS of every
  host. `Conninfo.t`'s `ssl_mode` is an option, `None` when the string
  gives none, and each `Conninfo.endpoint` has the `ssl_mode` it is
  reached with.
- Breaking: `sslrootcert` is refused unless `sslmode` is `verify-full` or
  `verify-ca`, the only modes that read it: with any other, or none, the
  file was silently ignored and no certificate checked. Write
  `sslmode=verify-full`, or `verify-ca`, to check against it.

## 0.4.0 (2026-10-13)

- Breaking: `Conninfo.t`, `Conninfo.endpoint` and `Conninfo.auth_methods`
  are private records. Their fields are read as before, and one is made
  by `Conninfo.of_string`, so a key the driver comes to read is not a
  breaking change. `{ c with database = name }` is
  `Conninfo.with_database c name`, `{ c with connect_timeout = Some span }`
  is `Conninfo.with_connect_timeout c span`, and any other key is set in
  the connection string.
- Breaking: `Postgres_eio.Protocol` and `Postgres_eio.Auth` are no longer
  exported, so a message the protocol gains is not a breaking change.
  `status` returns `Postgres_eio.transaction_status`: match
  `Postgres_eio.Idle`, not `Postgres_eio.Protocol.Idle`. `Column.format`
  is a type of its own, with the same constructors.

## 0.3.0 (2026-10-11)

- Breaking: every duration is an `Mtime.Span.t` named for what it bounds,
  not a float of seconds named for its unit, so a wait in the wrong unit
  no longer compiles. `connect`'s and `Listener.connect`'s `?timeout_s`
  is `?timeout`, `Listener.connect`'s `?heartbeat_s` is `?heartbeat`,
  `Pool.create`'s `?timeout_s`, `?wait_s`, `?max_lifetime_s` and
  `?idle_check_s` are `?timeout`, `?wait`, `?max_lifetime` and
  `?idle_check`, and `Pool.use`'s `?wait_s` is `?wait`: write
  `~timeout:Mtime.Span.(10 * s)`.
- Breaking: `timeout_s` is `timeout`, and `set_timeout` takes
  `~timeout:Mtime.Span.t option`.
- Breaking: the `Conninfo.t` field `connect_timeout_s : float option` is
  `connect_timeout : Mtime.Span.t option`. The connection string still
  gives it in whole seconds, as libpq reads it, and `to_url` writes it
  in whole seconds, rounded up. Only a zero span now falls back to the
  connection's timeout, since a span is never negative.

- Breaking: `abandon` and `resume` are gone. The pool has stopped a
  cancelled borrower through Eio cancellation since 0.2.0, and nothing
  else called them. To stop a statement, cancel the fiber running it: the
  statement is cancelled at the server and the connection closed.

## 0.2.0 (2026-10-11)

- Breaking: OCaml 5.5 or later is required. The opam files asked for 5.4,
  which CI tested and nothing else did; every switch the code is written
  in is 5.5.
- A row function that raises while `Pool.use` drains its unread answers no
  longer takes the connection out of the pool for good: the connection goes
  back, is made again at the next lend, and the exception reaches the
  caller as raised, not wrapped in `Fun.Finally_raised`.
- Breaking: an Eio cancellation stops a `Pool.use` borrower at once,
  wherever it waits. `f` was shielded until it returned, so a cancelled
  borrower waited for work nobody wanted, or forever on something the
  cancellation had stopped. Its statement is still cancelled at the
  server; its connection is now closed and made again at the next lend.
- A `Timeout`, or an Eio cancellation of a statement under way, cancels
  the statement at the server as it closes the connection. Before, only a
  pool's cancelled borrower did; elsewhere the server ran the statement to
  its end with nobody to read it. The request has 5 s, or the timeout if
  that is shorter, and a pool's cancelled borrower's has the pool's
  timeout: with the timeout lifted, a server that never closed the
  request's connection held the caller forever.
- `Listener.next` returns a notification that arrived in the same read as
  the end of the listener's own answer (a `LISTEN`, or the heartbeat's
  empty query) at once. It waited for the next heartbeat, ten seconds by
  default, though the notification was already read.
- Cancelling `Listener.next` while it waits keeps the connection. It
  closed it, so a loop racing `next` against a tick reconnected at every
  tick and lost what was sent meanwhile. Only the read after the socket is
  readable is shielded, and what it reads is kept for the next call.
- A loop racing `Listener.next` against a tick shorter than `heartbeat_s`
  sends its heartbeats, and notices a dead server within heartbeat +
  timeout. Each `next` counted the heartbeat from its own start, so such a
  loop never sent one. The heartbeat now counts from the last time the
  listener heard the server, and one under way when `next` is cancelled is
  finished, within the timeout, rather than closing the connection.
- Breaking: a `Listener` whose server is restarting waits for it: an error
  of class 57P while it reconnects (57P03, the server starting up) is
  retried with backoff, as a lost connection is, and no longer returned by
  `next`. It ended the loop with the error, though the server would take
  the sign-in a moment later. Any other server refusal is still returned.
- `Pool.error_to_string` prints a `Pool.error`, what `Pool.use` answers,
  as `error_to_string` prints a connection's error.
- Connecting keeps a random generator the application set as
  mirage-crypto's default, and sets one only where none is. Every
  connection replaced it with `Mirage_crypto_rng_unix.use_default ()`.
- A connection's read buffer goes back to 4 KiB once it is empty after a
  message over 128 KiB. It kept the size of the largest message it had
  read, so one large row held that memory for a pooled connection's life.
- A keyword connection string whose password holds an unquoted space no
  longer quotes the part after the space in its error, which was part of
  the password. A word after `password=` is never quoted; the error says
  to quote the password, `password='a b'`.
- Breaking: `Pool.error` is `` [ `Pool of [ `Busy | `Closed ] ] ``, the
  pool's states under the pool, so an error merged with others says which
  resource refused. `Pool.use` answers `` `Pool `Busy `` where it answered
  `` `Busy ``, and `` `Pool `Closed `` on a closed pool, at once, as it does
  to a borrow waiting when the pool closes. A closed pool waited out
  `wait_s`, logged that no connection came free, and returned `` `Busy ``,
  though none ever would.
- The cancel request of `abandon` has 5 s, or the timeout if that is shorter,
  as a timeout's does. It had the connection's timeout alone, so with the
  timeout lifted, as a migration lifts it, a server that never closed the
  request's connection held the lender forever.
- A row or chunk function that raises cancels its statement at the server
  as the connection closes, as a timeout does, and its exception still
  propagates as raised. The connection closed alone, and the server ran
  the statement to its end with nobody to read it.
- Breaking: `Conninfo.protocol_minor` is no longer exported. It was a
  step of the start-up, the minor version a StartupMessage carries, and
  nothing outside the driver used it.
- A `connect_timeout_s` of zero or less falls back to the connection's
  `timeout_s`, as `Conninfo` documents. A `Conninfo.t` built by hand with
  `Some 0.` timed out every attempt at once; a parsed connection string
  never carried one.

## 0.1.0 (2026-10-06)

First release.

- Protocol 3.0 and 3.2 over TCP, Unix sockets and TLS, with multi-host
  failover, load balancing and `target_session_attrs`.
- Sign-in by SCRAM-SHA-256 with channel binding, MD5, client certificates,
  trust, and a cleartext password inside TLS only, held to `require_auth`.
- libpq's connection strings, both forms, with the `PG*` variables and
  `.pgpass` on request.
- Statements cached, pipelined and batched in one round trip, with text or
  binary results.
- Cells read as OCaml values, text or binary alike: dates and instants as
  `Ptime` values, uuids as `Uuidm.t`, intervals as their months, days and
  microseconds, and the whole of an `int8` as an `int64`.
- COPY in and out, streamed.
- LISTEN/NOTIFY with heartbeats and reconnection.
- A timeout on every wait for the server, and a running statement
  cancelled at the server.
- A connection pool that lends every connection in a clean state, shared
  by borrowers on every domain.
- Every failure a value: a `result` with a variant error, never an
  exception.
