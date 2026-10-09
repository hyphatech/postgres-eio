# Changes

## Unreleased

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
- `Pool.error_to_string` prints `Pool.use`'s `` `Busy ``, now named
  `Pool.error`, as `error_to_string` prints a connection's error.
- Connecting keeps a random generator the application set as
  mirage-crypto's default, and sets one only where none is. Every
  connection replaced it with `Mirage_crypto_rng_unix.use_default ()`.
- A keyword connection string whose password holds an unquoted space no
  longer quotes the part after the space in its error, which was part of
  the password. A word after `password=` is never quoted; the error says
  to quote the password, `password='a b'`.

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
