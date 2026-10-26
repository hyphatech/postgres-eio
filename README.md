# postgres-eio

[![ci](https://img.shields.io/github/actions/workflow/status/hyphatech/postgres-eio/ci.yml?branch=main&label=ci)](https://github.com/hyphatech/postgres-eio/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/hyphatech/postgres-eio?label=release)](https://github.com/hyphatech/postgres-eio/releases)
[![license](https://img.shields.io/github/license/hyphatech/postgres-eio)](LICENSE)
![OCaml 5.5+](https://img.shields.io/badge/OCaml-5.5%2B-EC6813?logo=ocaml&logoColor=white)
[![Hypha Stack](https://img.shields.io/badge/Hypha-Stack-d4a820?labelColor=15120e)](https://hyphatech.io/stack/)

The Postgres driver for modern OCaml.
Fast, secure and feature-complete. Eio-native and multicore-ready.

**Documentation**: [hyphatech.github.io/postgres-eio](https://hyphatech.github.io/postgres-eio/)

## Features

- **Secure by default**: TLS, SCRAM-SHA-256 with channel binding and client certificates; a connection that crosses a network is encrypted unless its string says otherwise.
- **Pool and failover**: one pool serves every domain, across several hosts, with failover and load balancing.
- **One round trip**: statement caching, pipelining and batches.
- **Streams**: COPY in and out, and rows folded as they arrive, never buffered.
- **LISTEN/NOTIFY**: a listener that reconnects by itself and says so.
- **Failures you can act on**: each says whether the statement may have run, so a retry is never blind.

## Install

```sh
opam repo add hypha https://github.com/hyphatech/opam-repository.git
opam install postgres-eio
```

```lisp
(libraries postgres-eio eio_main)
```

## Example

```ocaml
let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match Postgres_eio.Conninfo.of_string "postgres://app@localhost/shop" with
  | Error e -> prerr_endline e
  | Ok conninfo -> (
      match
        Postgres_eio.connect ~sw ~net:(Eio.Stdenv.net env)
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          conninfo
      with
      | Error e -> prerr_endline (Postgres_eio.error_to_string e)
      | Ok conn ->
          (match
             Postgres_eio.query conn
               "select name from customers where country = $1"
               ~params:[ Some "GB" ] ~init:[] ~row:(fun names row ->
                 match row with [| Some name |] -> name :: names | _ -> names)
           with
          | Ok (names, _tag) -> List.iter print_endline names
          | Error e -> prerr_endline (Postgres_eio.error_to_string e));
          Postgres_eio.close conn)
```

## Contributing

See [AGENTS.md](AGENTS.md).

## Licence

MIT, copyright Hypha Technologies Ltd. See [LICENSE](LICENSE).
