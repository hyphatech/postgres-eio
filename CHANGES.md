# Changes

## Unreleased

- `execute` and `Pipeline.execute` run a statement for its effect and
  answer its tag, where `query` needed `~init:() ~row:(fun () _ -> ())`.
- A RowDescription with a column format other than text or binary is
  refused without quoting the column's name, as no other protocol error
  quotes what the server sent.
- A connection, pooled or not, is safe to use from a domain other than the
  one that made it. A statement timing out there failed the switch the
  connection was made on, and a reconnect there raised `Invalid_argument`
  from `reset` and `Pool.use`. Timing a statement now costs about 5 µs of
  CPU per round trip.
- `execute_many` reads its answers while it writes, where a batch whose
  answers outgrew the socket buffers stalled until the timeout and lost
  the connection.
- A connection string whose password holds a malformed percent escape, or
  an unescaped `?` or `/`, is refused without quoting the password in the
  error.
- A binary `timestamp` or `timestamptz` past year 292,000 or so is refused
  as text refuses it, where it read as a date before year 2000.
- `Text.to_int`, `to_int64` and `to_float`, and a connection string's
  `port` and `connect_timeout`, read decimals only, as documented: OCaml's
  `0x`, `0o`, `0b`, `0u` and `_` forms are refused, where a hex one past the
  range read as a wrong number.
- `Text.to_timestamptz` reads what `Text.timestamptz` and `Text.timestamp`
  write, so the pair round-trips.
- Breaking: `Value`'s decoders read a text cell only where they would read
  its binary form, so `~binary` no longer changes the answer: `Value.int` on
  a `text` column, or `Value.timestamp` on a `timestamptz` one, is `None`
  either way. A type always sent as text, such as `numeric`, is still read
  from its text.
- Breaking: `set_timeout` takes `~timeout_s`, and `timeout` is renamed
  `timeout_s`, so the unit is named where the value is.
- Breaking: `Pool.use` returns `` `Busy `` with no payload; the float was the
  wait the caller had passed.
- Breaking: a pool made with `~reset:false` now ends a borrower's `LISTEN`
  on give-back, as it already rolled back an open transaction. A pooled
  connection left listening reads nothing and fills the server's
  notification queue.

## 0.1.0 (2026-10-06)

First release.

- Protocol 3.0 and 3.2 over TCP, Unix sockets and TLS, with multi-host
  failover, load balancing and `target_session_attrs`.
- Sign-in by SCRAM-SHA-256 with channel binding, MD5, client certificates
  and trust, held to `require_auth`.
- libpq's connection strings, both forms, with the `PG*` variables and
  `.pgpass` on request.
- Statement caching, pipelining, `execute_many`, text and binary results.
- Cells read as OCaml values, text or binary alike: dates and instants as
  `Ptime` values, uuids as `Uuidm.t`, intervals as their months, days and
  microseconds, and the whole of an `int8` as an `int64`.
- COPY in and out, streamed.
- LISTEN/NOTIFY with heartbeats and reconnection.
- A connection pool that resets every connection it lends.
