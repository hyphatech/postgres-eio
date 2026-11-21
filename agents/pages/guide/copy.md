# COPY

COPY moves bulk data in both directions, streamed, without holding a whole
table. It takes no parameters.

## Rows in

```ocaml
let load conn rows =
  Postgres_eio.copy_in_rows conn ~table:"orders" ~columns:[ "id"; "total" ]
    (Seq.map
       (fun (id, total) -> [| Some id; Some (string_of_int total) |])
       rows)
```

`copy_in_rows` runs `COPY "schema"."table" ("a", "b") FROM STDIN` in text
format, escaping each row. Cells follow `columns`' order, `None` for NULL;
empty `columns` means every column, in the table's order. The sequence is
read lazily. Names are quoted as given, so `"Jobs"` is not `jobs`.

If the producer raises, the COPY is aborted, nothing is written and the
connection stays usable; the exception propagates, and the server is sent
a fixed message, never the exception. A NUL in a name is refused before
anything is sent; a NUL in a value fails the COPY, the connection still
usable.

## Rows out

`copy_out_rows` streams a select the other way:

```ocaml
let sum conn =
  Postgres_eio.copy_out_rows conn ~select:"select total from orders" ~init:0
    ~row:(fun sum row ->
      match row with
      | [| Some total |] ->
          sum + Option.value ~default:0 (Postgres_eio.Text.to_int total)
      | _ -> sum)
```

It runs `COPY (select) TO STDOUT` and decodes each row for `row`, `None`
for NULL, like `query`, for a very large result.

## Bytes in and out

`copy_in` and `copy_out` run a COPY statement of your own, in its own
format, CSV say, and move its bytes unchanged:

```ocaml
let import conn source =
  Postgres_eio.copy_in conn
    "copy orders (id, total) from stdin with (format csv, header)" source
```

```ocaml
let export conn sink =
  Postgres_eio.copy_out conn "copy orders to stdout with (format csv)" ~init:()
    ~chunk:(fun () data -> Eio.Flow.copy_string data sink)
```

`copy_in` streams an Eio source, and `copy_out` folds each chunk into
`chunk` as it arrives. Any other statement is refused, after it has run.
If `chunk` raises, the connection is closed, the statement cancelled at
the server, and the exception propagates. A cancellation of `copy_in`
closes the connection.

A COPY given to `query` or `script` is refused, and the connection stays
usable.
