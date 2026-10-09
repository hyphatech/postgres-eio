# Changes

## Unreleased

- Breaking: OCaml 5.5 or later is required. The opam files asked for 5.4,
  which CI tested and nothing else did; every switch the code is written
  in is 5.5.
- A row function that raises while `Pool.use` drains its unread answers no
  longer takes the connection out of the pool for good: the connection goes
  back, is made again at the next lend, and the exception reaches the
  caller as raised, not wrapped in `Fun.Finally_raised`.

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
