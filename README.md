# postgres-eio

[![ci](https://img.shields.io/github/actions/workflow/status/hyphatech/postgres-eio/ci.yml?branch=main&label=ci)](https://github.com/hyphatech/postgres-eio/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/hyphatech/postgres-eio?label=release)](https://github.com/hyphatech/postgres-eio/releases)
[![license](https://img.shields.io/github/license/hyphatech/postgres-eio)](LICENSE)
![OCaml 5.5+](https://img.shields.io/badge/OCaml-5.5%2B-EC6813?logo=ocaml&logoColor=white)
[![Hypha Stack](https://img.shields.io/badge/Hypha-Stack-d4a820?labelColor=15120e)](https://hyphatech.io/stack/)

A native Postgres driver for OCaml 5 and Eio.

- Protocol 3.0 and 3.2 over TCP, Unix sockets and TLS, with multi-host
  failover and load balancing.
- SCRAM-SHA-256 (RFC 7677) with channel binding, MD5, client certificates.
- Statement caching, pipelining and batches in one round trip.
- COPY in and out, streamed. LISTEN/NOTIFY with automatic reconnection.
- Text and binary results.
- A connection pool that lends every connection in a clean state.
- Every failure is a value. Driver errors and logs never contain
  parameters, passwords, sign-in exchanges or message bytes; a server's
  error is in its own words, which can quote a value that failed its cast.

## Install

```sh
opam repo add hypha https://github.com/hyphatech/opam-repository.git
opam install postgres-eio
```

```lisp
(libraries postgres-eio eio_main)
```

## Quick start

```ocaml
let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match Postgres_eio.Conninfo.of_string "postgres://app@localhost/shop" with
  | Error e -> prerr_endline e
  | Ok conninfo -> (
      match
        Postgres_eio.connect ~sw ~net:(Eio.Stdenv.net env)
          ~mono_clock:(Eio.Stdenv.mono_clock env) conninfo
      with
      | Error e -> prerr_endline (Postgres_eio.error_to_string e)
      | Ok conn ->
          (match
             Postgres_eio.query conn
               "select name from customers where country = $1"
               ~params:[ Some "GB" ] ~init:[]
               ~row:(fun names row ->
                 match row with [| Some name |] -> name :: names | _ -> names)
           with
          | Ok (names, _tag) -> List.iter print_endline names
          | Error e -> prerr_endline (Postgres_eio.error_to_string e));
          Postgres_eio.close conn)
```

Parameters are `$1`, `$2`, ... with `None` for NULL. Rows are folded as they
arrive and never buffered.

Every connection sets the session settings the decoders read text by, over
the database's and the role's defaults: `client_encoding=UTF8`,
`DateStyle=ISO`, `IntervalStyle=postgres` and `extra_float_digits=3`. Text
is UTF-8 in a `LATIN1` database too, and a float reads back to its last
digit. A parameter or an `options` setting that changes one of them is
refused.

Every failure is a polymorphic variant, so a connection's failures join a
pool's and your own in one result:

| | |
|---|---|
| `` `Server e `` | the server refused, and said why (`Server_error`) |
| `` `Refused m `` | the driver refused: an unsafe sign-in, an untrusted certificate, a value it cannot send |
| `` `Lost m `` | sent, and no answer came back -- a timeout, a broken socket; the statement may have run, so it is not run again blindly |
| `` `Unsent m `` | connecting failed before anything was sent; connecting again is safe |
| `` `Connection `Closed `` | the connection was closed before the statement was sent |

A statement run for its effect needs no fold, and answers its tag:

```ocaml
Postgres_eio.execute conn "insert into orders values ($1, $2)"
  ~params:[ Some id; Some total ]
```

## Connection strings

Both libpq forms are accepted: `postgres://user:pass@host:5432/db?sslmode=require`
and `host=db user=app sslmode=require`. Unknown keys are an error, not
ignored.

| Key | Values | Default |
|---|---|---|
| `host` | name, address, or a Unix socket directory (starts with `/`); comma-separated for several | `localhost` |
| `hostaddr` | IP address to connect to without a lookup; `host` stays the name TLS verifies | |
| `port` | one for all hosts, or one per host | `5432` |
| `user` | | required |
| `password` | | |
| `dbname` | | `user` |
| `sslmode` | `disable`, `allow`, `prefer`, `require`, `verify-ca`, `verify-full` | `prefer` on this machine, `require` elsewhere |
| `sslrootcert` | PEM file of trusted CAs, for `verify-ca` and `verify-full` | system CAs |
| `sslcert`, `sslkey` | PEM client certificate and unencrypted key | |
| `sslnegotiation` | `postgres`, or `direct` for TLS from the first byte (needs `require` or stronger) | `postgres` |
| `channel_binding` | `disable`, `prefer`, `require` | `prefer` |
| `require_auth` | list of `password`, `md5`, `scram-sha-256`, `none`, or each negated with `!` | all |
| `connect_timeout` | whole seconds per address attempt | the connection's `timeout` (30 s) |
| `application_name` | | |
| `keepalives` | `1`, `0` | `1` |
| `target_session_attrs` | `any`, `read-write`, `read-only`, `primary`, `standby`, `prefer-standby` | `any` |
| `load_balance_hosts` | `disable`, `random` | `disable` |
| `min_protocol_version`, `max_protocol_version` | `3.0`, `3.2`, `latest` | `3.0` |
| `options` | `-c name=value` settings, sent as startup parameters | |

`sslmode` means what it means to libpq. `require` encrypts and checks no
certificate, so it keeps out a listener but not a server that pretends;
`verify-ca` checks the certificate against `sslrootcert`, and
`verify-full` checks too that it names the host -- the mode for
production. With no `sslmode`, a host on this machine (`localhost`,
127.0.0.0/8, `::1`, a Unix socket) is `prefer`, and any other host is
`require`, so a connection that crosses a network is encrypted unless the
string says `sslmode=disable` or `prefer`. `sslrootcert` is refused with
any mode but `verify-full` and `verify-ca`, or with none, since nothing
else reads it: write `sslmode=verify-full` to check against the file.

The driver reads no environment variables or files unless you pass them in:

```ocaml
Postgres_eio.Conninfo.of_string
  ~defaults:(Postgres_eio.Conninfo.environment Sys.getenv_opt)
  "dbname=shop"
|> Result.map (Postgres_eio.Conninfo.passfile pgpass_contents)
```

## Pool

All connections open at startup, so a bad configuration fails at once. A
returned connection is reset (open transaction, settings, temporary tables,
locks, `LISTEN`), and the reset costs the next borrower no round trip. One
pool serves borrowers on every domain, and bounds a reconnect's name
lookup by `connect_timeout` on each of them.

```ocaml
let count pool =
  Postgres_eio.Pool.use pool (fun conn ->
      Postgres_eio.query conn "select count(*) from orders" ~params:[]
        ~init:None ~row:(fun _ row ->
          match row with [| Some n |] -> Postgres_eio.Text.to_int n | _ -> None))
```

`Pool.use` returns `` `Pool `Busy `` if no connection frees up within
its `wait` (5 s, or `~wait:Mtime.Span.(500 * ms)`), and `` `Pool `Closed `` at once after `Pool.close`;
`Pool.error_to_string` prints either, and a connection's errors
too, so `Result.join (Pool.use pool f)` is printed by one function. Cancelling a borrower stops it at
once, wherever it waits: its statement is cancelled at the server, so the
transaction rolls back, and its connection is closed and made again at the
next lend.

## Pipelining and batches

```ocaml
let answers =
  List.map
    (fun id ->
      Postgres_eio.Pipeline.query conn "select total from orders where id = $1"
        ~params:[ Some id ] ~init:[] ~row:(fun acc row -> row :: acc))
    ids
in
List.map Postgres_eio.Pipeline.get answers
```

`execute_many` runs one statement over many parameter lists in one round
trip and one transaction.

## COPY

```ocaml
Postgres_eio.copy_in_rows conn ~table:"orders" ~columns:[ "id"; "total" ]
  (Seq.map (fun (id, total) -> [| Some id; Some (string_of_int total) |]) rows)
```

`copy_out_rows` streams a select the other way. If the producer raises, the
COPY is aborted, nothing is written and the connection stays usable.

## LISTEN/NOTIFY

```ocaml
let rec follow listener =
  match Postgres_eio.Listener.next listener with
  | Ok (Notification { payload; _ }) -> handle payload; follow listener
  | Ok Reconnected -> reload (); follow listener
  | Error e -> Error e
```

A `Listener` is its own connection. It detects a dead server by pinging
it after `keep_alive` (10 s) of silence, reconnects with backoff and listens again, and returns
`Reconnected` because notifications sent meanwhile are lost. `next` can
be raced against a timer, however short its tick: a cancelled wait keeps
the connection and loses nothing, and the ping still comes.

## Performance

Median time per operation, lower is better, beside `postgres_async`, a
native OCaml driver on Async, and libpq, the C library, through the
`postgresql` bindings.

| | postgres-eio | postgres_async | libpq |
|---|--:|--:|--:|
| Round trip, `select $1::int` | 329 µs | 582 µs | 287 µs |
| Insert, one round trip each | 337 µs | 594 µs | 296 µs |
| Insert, 1,000 pipelined in one round trip | 5.0 µs | n/a | n/a |
| Read a 100,000-row result, per row | 138 ns | 142 ns | 169 ns |
| Client CPU per round trip | 41 µs | 51 µs | 21 µs |

Measured with postgres-eio 0.1.0, postgres_async 0.17.0, postgresql 5.4.0. Apple M4 Pro,
Postgres 18.6 in Docker, one connection per driver, text results, median of
three 5 s runs.

## Documentation

Each module's interface (`.mli`) is its reference: `make doc` builds it
with odoc. Start with `Postgres_eio` (connections), `Pool` and `Conninfo`.

## Contributing

See [AGENTS.md](AGENTS.md).

## Licence

MIT, copyright Hypha Technologies Ltd. See [LICENSE](LICENSE).
