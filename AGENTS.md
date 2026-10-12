# AGENTS.md

The postgres-eio library is a native Postgres driver for OCaml 5 and Eio. This file is
for anyone changing it, human or agent. Users start at [README.md](README.md).

## Commands

```sh
make setup   # once: local opam switch in ./_opam, all dependencies
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

## House style

The house style, the OCaml checklist and the OCaml tools are
[OCAML.md](OCAML.md), the same in every Hypha OCaml repository and changed
in all of them together, never in one. It is imported here, so it is read
with this file:

@OCAML.md

## Git

How work becomes a commit -- its format, where it happens, what is pushed
-- is [GIT.md](GIT.md), the same in every Hypha repository and changed in
all of them together, never in one. It is imported here, so it is read
with this file:

@GIT.md

## Changes

- A user-visible change adds a line under `## Unreleased` in
  [CHANGES.md](CHANGES.md), in the same commit. A breaking one says so.
- A change that makes a sentence in a document false edits that sentence in
  the same commit.
- A user-visible change updates the `.mli` it touches; a new supported
  feature or a removed limitation updates the README.

## Releases

[Semantic Versioning 2.0.0](https://semver.org). Before 1.0, a breaking
change bumps the minor version and anything else the patch.

Breaking means a user's code may stop compiling or behave differently:
removing or renaming anything in an `.mli`, changing a type, adding a
constructor to a public variant (it breaks exhaustive matches), adding a
required argument, or changing a default or documented behaviour. Adding a
function, a module or an optional argument is not breaking, and neither is
the wording of an error or a log line.

The version lives only in the git tag (`0.1.0`, no `v`). A release renames
`## Unreleased` in CHANGES.md to the version and date, and tags it. The GitHub
release notes are that entry with each paragraph and bullet on one line,
since GitHub keeps every line break in release notes. A release is
pushed first and tagged only once CI is green on the commit the tag
names: a broken build is never tagged.
