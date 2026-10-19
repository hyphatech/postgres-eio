# AGENTS.md

postgres-eio is an OCaml library of Hypha Stack: a native Postgres driver
for OCaml 5 and Eio. This file is for anyone changing it, human or agent.
Users start at [README.md](README.md).

## Commands

```sh
make setup   # once: the switch hypha-postgres-eio, all dependencies
make test    # starts the test Postgres in Docker, runs every test
make lint    # formatting, odoc, and the release build
make fmt     # format in place
```

`make test` needs `docker compose`. Without
`POSTGRES_EIO_TEST_PG` the cases that need a server are skipped, and the test
output says so. CI runs `make lint` and `make test` on OCaml 5.5.

## Layout

```
src/                 the library; every module has an .mli
  postgres_eio       the entry point: the connection, and the modules users reach
  protocol           messages to and from bytes, no IO
  server_error, tag  a server's error and a statement's command tag, no IO
  auth, saslprep     SCRAM-SHA-256 and MD5, no IO
  conninfo           connection strings, the PG* variables, .pgpass, no IO
  column, oid        a result's columns, and the identifiers of their types
  text, value        cell encoding and decoding, text and binary
  interval, instant  intervals, and instants between microseconds and Ptime
  connection         a connection: TLS, sign-in, statements, COPY, LISTEN
  pool               a fixed-size pool
test/
  test_postgres_eio  protocol cases, fake servers, and a real Postgres
  postgres/          the test server's image: certificates and pg_hba.conf
```

Each module's contract is its `.mli`. Read the `.mli` before changing a
module.

## Rules that must hold

Each rule comes with why it exists and the test that catches a break.

- **Every protocol requirement the driver meets has a test case named by
  its section** of chapter 54 of the Postgres 18 docs (e.g. `54.2.4 ...`).
  Backend messages are read whole, a byte at a time, and at generated
  splits. Why: review by example misses the requirement nobody thought
  of. Test: the cases of that name in `test_postgres_eio`.
- **The driver reads only what the connection string names, unless the
  caller hands it more.** Files only from `sslrootcert`, `sslcert` and
  `sslkey`. The system CAs only for a verified mode with no `sslrootcert`.
  `PG*` variables only through `Conninfo.environment`, and `.pgpass` only as
  contents given to `Conninfo.passfile`. Why: behaviour must not depend on
  the machine. Test: `nothing from the environment unasked`.
- **Answers are read in the order the statements were sent.** Every
  exchange (query, pipelined statement, batch, script, Close) is a reply in
  the connection's one queue, and nothing reads past a reply ahead of it.
  COPY and a listener's wait read only once the queue is empty. While
  writing, every reply is read, because the server stops reading while its
  answers wait. Why: otherwise one statement's answer is read as another's,
  or both sides deadlock. Test: `54.2.4 answers asked for out of order`,
  `54.2.4 longer than the buffers, and no deadlock`.
- **A pooled connection is lent in a clean state**: no transaction, no
  session state, its original timeout. The reset is queued at give-back and
  read at the next lend, never awaited at give-back. It is `DISCARD ALL`
  minus `DEALLOCATE ALL` and `DISCARD PLANS`, because the statement cache is
  shared by every borrower. Test: `a borrower's session is not the next
  one's`, `a transaction left open is rolled back`.
- **Only a `Listener` keeps notifications; a pooled connection never
  listens.** Every give-back sends `UNLISTEN *` but on a standby, which
  cannot listen, with `~reset:false` too.
  Why: a notification belongs to the session that asked for it, not to
  whoever borrows the connection next, and an idle pooled connection reads
  nothing, so one left listening fills the server's notification queue.
  Test: `a pooled connection never listens`.
- **No secret reaches a log or a driver error**: no parameter, password,
  SCRAM exchange or message bytes, at any level. The exception is a server
  error's message, returned as the server wrote it, which can quote a value
  that failed its cast (class 22). The TLS library's own `tls.tracing` and
  `handshake` sources are the application's to cap. Test: `no secret in
  the log`, `a bad escape in a password is not quoted`, `a delimiter in a
  password is not quoted`.
- **The driver's own failures are values; only the caller's exceptions
  pass through.** Failures inside an exchange raise `Fail` internally and
  are caught where the exchange began. An exception from a caller's
  callback (a row function, a COPY source) and Eio's cancellation propagate
  as they came. A failure that leaves the stream out of step (timeout,
  broken socket, malformed bytes, a raise from a row function) closes the
  connection. A server error does not, since the server marks where its
  reply ends. Test: `54.2.3 a server's error keeps the connection`,
  `54.2.6 a producer that raises is a CopyFail`.
