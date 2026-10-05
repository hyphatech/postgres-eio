# AGENTS.md

postgres-eio is a native Postgres driver for OCaml 5 and Eio. This file is
for anyone changing it, human or agent. Users start at [README.md](README.md).

## Commands

```sh
make setup   # once: local opam switch in ./_opam, all dependencies
make test    # starts the test Postgres in Docker, runs every test
make lint    # formatting, odoc, and the release build
make fmt     # format in place
```

Nothing is on PATH: run OCaml tools through the Makefile, or prefix them
with `opam exec --switch=. --`. `make test` needs `docker compose`. Without
`POSTGRES_EIO_TEST_PG` the cases that need a server are skipped, and the test
output says so. CI runs `make lint` and `make test` on OCaml 5.4 and 5.5.

## Layout

```
src/                 the library; every module has an .mli
  protocol           messages to and from bytes, no IO
  auth, saslprep     SCRAM-SHA-256 and MD5, no IO
  conninfo           connection strings, the PG* variables, .pgpass, no IO
  text, value        cell encoding and decoding, text and binary
  connection         a connection: TLS, sign-in, statements, COPY, LISTEN
  pool               a fixed-size pool
test/
  test_postgres_eio  protocol cases, fake servers, and a real Postgres
  test_style         the house rules that can be checked mechanically
  postgres/          the test server's image: certificates and pg_hba.conf
```

Each module's contract is its `.mli`. Read the `.mli` before changing a
module.

## Rules that must hold

Each rule comes with why it exists and the test that catches a break.

- **Every protocol requirement the driver meets has a test case named by
  its section** of chapter 54 of the Postgres 18 docs (e.g. `54.2.4 ...`).
  Backend messages are read whole, a byte at a time, and at generated
  splits. A requirement the driver does not meet goes under *Not supported*
  in the README. Why: review by example misses the requirement nobody
  thought of.
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
  or both sides deadlock. Tests: `54.2.4 answers asked for out of order`,
  `54.2.4 longer than the buffers, and no deadlock`.
- **A pooled connection is lent in a clean state**: no transaction, no
  session state, its original timeout. The reset is queued at give-back and
  read at the next lend, never awaited at give-back. It is `DISCARD ALL`
  minus `DEALLOCATE ALL` and `DISCARD PLANS`, because the statement cache is
  shared by every borrower. Tests: `a borrower's session is not the next
  one's`, `a transaction left open is rolled back`.
- **Only a `Listener` keeps notifications; a pooled connection never
  listens.** The reset runs `UNLISTEN *`. Why: a notification belongs to the
  session that asked for it, not to whoever borrows the connection next.
- **No secret reaches a log or a driver error**: no parameter, password,
  SCRAM exchange or message bytes, at any level. The exception is a server
  error's message, returned as the server wrote it, which can quote a value
  that failed its cast (class 22). The TLS library's own `tls.tracing` and
  `handshake` sources are the application's to cap. Test: `no secret in the
  log`.
- **The driver's own failures are values; only the caller's exceptions
  pass through.** Failures inside an exchange raise `Fail` internally and
  are caught where the exchange began. An exception from a caller's
  callback (a row function, a COPY source) and Eio's cancellation propagate
  as they came. A failure that leaves the stream out of step (timeout,
  broken socket, malformed bytes, a raise from a row function) closes the
  connection. A server error does not, since the server marks where its
  reply ends.

## House style

The rules are ranked, because they conflict:

1. **Simple and obvious beats clever.** If a reviewer has to reconstruct
   why something works, it is wrong even when it is correct.
2. **Locality of behaviour beats DRY.** Code that changes together lives
   together, and a function reads top to bottom. Code that only looks alike
   is not duplication.
3. **No layer without a job.** No abstraction with one implementation
   unless the signature is the point, no functor for a choice made once.
4. **Comments say why, never what**, in a sentence or two: the RFC or
   protocol section, a constraint that is not visible, the reason for a
   number. Never history; that is the commits'. A comment the names already
   say is deleted.

### OCaml checklist

A change is done when every box holds:

- [ ] `make lint` and `make test` pass.
- [ ] **A change brings its tests**: the typical corner cases (empty, one,
  the boundaries, invalid input, a failure partway through), a property
  test wherever a round trip exists, and the real server wherever a test
  can run one, never a mock of it; a stub stands in only for a third
  party's service.
- [ ] **No partial functions**: no `failwith`, `invalid_arg`, `Option.get`,
  `Result.get_ok`, `List.hd`, `List.tl`, `List.nth`, `Obj.magic`. Errors are
  values: a `result` with a variant error, and `let*` over it.
- [ ] **No polymorphic `compare`**, and no `=` on a type that has a module:
  `Int.compare`, `String.equal`, `Char.equal`. `=` on `int` is fine.
- [ ] **No `open`.** Alias modules instead: `module P = Protocol`.
- [ ] **No silenced warnings.** The warning set in `dune` is the linter, and
  a warning that looks wrong is a code shape that is wrong.
- [ ] **An `.mli` per module.** Abstract types, hidden constructors; the
  contract in odoc in the `.mli`, the reasons in the `.ml`. It exports
  what a user needs, and nothing more.
- [ ] **The library never prints, exits or reads the environment.** It logs
  on its own `Logs` source.
- [ ] **A meaning is a type.** A state is a variant, never a string or a
  boolean; a unit or an identifier that travels unnamed -- a column, an
  element, a returned value -- is a type of its own, never a bare `int` or
  `string` whose meaning the caller has to remember. A labelled argument
  that names its unit at every call (`~timeout_s`) is enough.
- [ ] **Cancellation leaves nothing held.** A fiber cancelled at any effect
  releases what it held: a connection goes back to its pool or is closed,
  and a lock is let go.
- [ ] **Labelled arguments** where a call would otherwise be ambiguous, and
  optional arguments with defaults, followed by `()`.
- [ ] **Stdlib naming**: `t`, `create`/`make`, `of_x`/`to_x`, `*_opt`,
  stdlib argument order.
- [ ] **A name says what a thing is or does.** No metaphors or
  abbreviations beyond the stdlib's (`b` a buffer, `n` a count, `f` a
  function).
- [ ] **A number with a reason is a named constant**, the reason beside it.
- [ ] **No needless cost.** No quadratic walk where a linear one is as
  clear, and no whole result held where streaming is as simple. A claim
  about speed comes with a measurement.
- [ ] **Plain stdlib.** No Base, Core or Lwt.
- [ ] **`ocamlformat` decides layout.** Never format by hand.

## Changes

- A user-visible change adds a line under `## Unreleased` in
  [CHANGES.md](CHANGES.md), in the same commit. A breaking one says so.
- A change that makes a sentence in a document false edits that sentence in
  the same commit.
- A user-visible change updates the `.mli` it touches; a new supported
  feature or a removed limitation updates the README.
- Commit subjects are imperative, under 72 characters, with no full stop.
  The body says why, wrapped at 72. No trailers.

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
`## Unreleased` in CHANGES.md to the version and date, tags it, and submits
the package to opam-repository from the `hyphatech` fork. The GitHub
release notes are that entry with each paragraph and bullet on one line,
since GitHub keeps every line break in release notes.
