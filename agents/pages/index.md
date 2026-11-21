# Getting Started

The Postgres driver for modern OCaml.

postgres-eio is a Postgres driver for OCaml 5, written for Eio. A connection
that crosses a network is encrypted unless its string says otherwise, and
signs in with SCRAM-SHA-256 and channel binding. One pool serves every
domain, across several hosts, with failover. Statements are cached and
pipelined, COPY streams both ways, rows are folded as they arrive, and a
listener reconnects by itself. Each failure says whether the statement may
have run, so a retry is never blind.

```ocaml title="main.ml"
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

## Install

It needs opam, with a switch of OCaml 5.5 or later, and a Postgres server
to connect to.

```sh
opam repo add open-opam https://github.com/open-opam/opam-repository.git
opam install postgres-eio eio_main
```

A program runs the driver inside Eio's event loop, which `eio_main` starts,
and names both in its `dune` file:

```lisp
(libraries postgres-eio eio_main)
```

The [quick start](quick-start.md) connects and runs a query,
next.
