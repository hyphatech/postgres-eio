# postgres-eio

[![ci](https://img.shields.io/github/actions/workflow/status/hyphatech/postgres-eio/ci.yml?branch=main&label=ci)](https://github.com/hyphatech/postgres-eio/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/hyphatech/postgres-eio?label=release)](https://github.com/hyphatech/postgres-eio/releases)
[![license](https://img.shields.io/github/license/hyphatech/postgres-eio)](LICENSE)
![OCaml 5.4+](https://img.shields.io/badge/OCaml-5.4%2B-EC6813?logo=ocaml&logoColor=white)
![PostgreSQL 14–18](https://img.shields.io/badge/PostgreSQL-14%E2%80%9318-336791?logo=postgresql&logoColor=white)

A native Postgres driver for OCaml 5 and Eio.

- Protocol 3.0 and 3.2 over TCP, Unix sockets and TLS, with multi-host
  failover and load balancing.
- SCRAM-SHA-256 with channel binding, MD5, client certificates.
- Statement caching, pipelining and batches in one round trip.
- COPY in and out, streamed. LISTEN/NOTIFY with automatic reconnection.
- Text and binary results.
- A connection pool that lends every connection in a clean state.
- Every failure is a value, and no log line or error contains a secret.

Works with Postgres 14 to 18.

## Install

```sh
opam pin add postgres-eio https://github.com/hyphatech/postgres-eio.git
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
          ~clock:(Eio.Stdenv.mono_clock env) conninfo
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
| `sslmode` | `disable`, `allow`, `prefer`, `require`, `verify-ca`, `verify-full` | `prefer` |
| `sslrootcert` | PEM file of trusted CAs | system CAs |
| `sslcert`, `sslkey` | PEM client certificate and unencrypted key | |
| `sslnegotiation` | `postgres`, or `direct` for TLS from the first byte (needs `require` or stronger) | `postgres` |
| `channel_binding` | `disable`, `prefer`, `require` | `prefer` |
| `require_auth` | list of `password`, `md5`, `scram-sha-256`, `none`, or each negated with `!` | all |
| `connect_timeout` | seconds per address attempt | none |
| `application_name` | | |
| `keepalives` | `1`, `0` | `1` |
| `target_session_attrs` | `any`, `read-write`, `read-only`, `primary`, `standby`, `prefer-standby` | `any` |
| `load_balance_hosts` | `disable`, `random` | `disable` |
| `min_protocol_version`, `max_protocol_version` | `3.0`, `3.2`, `latest` | `3.0` |
| `options` | `-c name=value` settings, sent as startup parameters | |

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
locks, `LISTEN`), and the reset costs the next borrower no round trip.

```ocaml
let count pool =
  Postgres_eio.Pool.use pool (fun conn ->
      Postgres_eio.query conn "select count(*) from orders" ~params:[]
        ~init:None ~row:(fun _ row ->
          match row with [| Some n |] -> Postgres_eio.Text.to_int n | _ -> None))
```

`Pool.use` returns `` `Busy `` if no connection frees up within `wait_s`
(5 s). Cancelling a borrower cancels its statement at the server, so the
transaction rolls back.

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

A `Listener` is its own connection. It detects a dead server with a
heartbeat, reconnects with backoff and listens again, and returns
`Reconnected` because notifications sent meanwhile are lost.

## Performance

Median time per operation, lower is better, beside `postgres_async`, a
native OCaml driver on Async, and libpq, the C library, through the
`postgresql` bindings.

| | postgres-eio | postgres_async | libpq |
|---|--:|--:|--:|
| Round trip, `select $1::int` | 316 µs | 591 µs | 283 µs |
| Insert, one round trip each | 323 µs | 603 µs | 296 µs |
| Insert, 1,000 pipelined in one round trip | 3.2 µs | n/a | n/a |
| Read a 100,000-row result, per row | 157 ns | 168 ns | 186 ns |
| Client CPU per round trip | 30 µs | 44 µs | 15 µs |

postgres-eio 0.1.0, postgres_async 0.17.0, postgresql 5.4.0. Apple M4 Pro,
Postgres 18.6 in Docker, one connection per driver, text results, median of
three 5 s runs.

## Documentation

Each module's interface (`.mli`) is its reference: `make doc` builds it
with odoc. Start with `Postgres_eio` (connections), `Pool` and `Conninfo`.

## Contributing

See [AGENTS.md](AGENTS.md).

## Licence

MIT, copyright Hypha Technologies Ltd. See [LICENSE](LICENSE).
