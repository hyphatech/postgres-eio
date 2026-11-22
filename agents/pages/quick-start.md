# Quick start

A program that connects, runs one query with a parameter and prints what
it finds. Put it in `bin/main.ml`:

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

and name its libraries in `bin/dune`:

```lisp
(executable
 (name main)
 (libraries postgres-eio eio_main))
```

Run it with `dune exec ./bin/main.exe`. It connects as `app` to the
database `shop` on this machine; the
[connection strings](guide/connection-strings.md) guide says how
to name another.

## What it does

`Conninfo.of_string` reads the connection string, and `connect` opens the
connection on the switch `sw`, with the network and the clock Eio hands the
program. The connection is closed when the switch ends, or earlier by
`close`.

Parameters are `$1`, `$2`, ... with `None` for NULL. Rows are folded as they
arrive and never buffered: `row` is called once for each, with the result
so far, and its last answer is the query's, beside the statement's tag.

Every failure is a value, so `connect` and `query` answer a `result`, and
`error_to_string` prints any of them. The [errors](guide/errors.md)
guide says what each failure means and what to do about it.

## A statement for its effect

A statement run for its effect needs no fold, and answers its tag:

```ocaml
let add_order conn ~id ~total =
  Postgres_eio.execute conn "insert into orders values ($1, $2)"
    ~params:[ Some id; Some total ]
```

## Next

- [Queries and values](guide/queries.md): parameters and cells
  of every type, text and binary.
- [Pool](guide/pool.md): connections shared by a server's
  fibers.
- [TLS and signing in](guide/tls.md): a connection for
  production.
