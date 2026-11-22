# Pipelining and batches

A statement normally waits for its answer before the next is sent. A
pipeline sends many and reads their answers after, in one round trip.

## A pipeline

```ocaml
let totals conn ids =
  let answers =
    List.map
      (fun id ->
        Postgres_eio.Pipeline.query conn
          "select total from orders where id = $1" ~params:[ Some id ] ~init:[]
          ~row:(fun acc row -> row :: acc))
      ids
  in
  List.map Postgres_eio.Pipeline.get answers
```

`Pipeline.query` and `Pipeline.execute` queue a statement, as `query` and
`execute` run one, and answer a handle to its answer. Nothing is sent until
an answer is asked for; then `Pipeline.get` sends everything queued and
reads answers up to the one asked for, writing while it reads, so no
pipeline is too long.

```ocaml
let ship conn ids =
  List.map
    (fun id ->
      Postgres_eio.Pipeline.execute conn
        "update orders set shipped = true where id = $1" ~params:[ Some id ])
    ids
  |> List.map Postgres_eio.Pipeline.get
```

Each statement gets its own Sync, so it behaves as if sent alone: a
failure does not stop the next, and inside `begin` and `commit` a failure
aborts the transaction as usual. Answers are read in the order the
statements were sent, across `query`, the pipeline, `execute_many` and
`script`.

## Draining

```ocaml
let still_in_transaction conn =
  Postgres_eio.Pipeline.drain conn
  |> Result.map (fun () ->
      match Postgres_eio.status conn with
      | Idle -> false
      | In_transaction | Failed -> true)
```

`Pipeline.drain` sends everything and reads every answer still owed, so
`status` is current. It fails only if the connection failed; a statement's
error stays in its answer. `Pipeline.flush` sends everything without
reading, and whoever reads next gets the answers; it is for a few
statements only, since a pipeline long enough to fill the server's output
buffer stalls until the timeout.

## A batch

`execute_many` runs one statement over many parameter lists in one round
trip and one transaction:

```ocaml
let add_orders conn orders =
  Postgres_eio.execute_many conn
    "insert into orders (id, total) values ($1, $2)"
    ~params:
      (List.map
         (fun (id, total) -> [ Some id; Some (Postgres_eio.Text.int total) ])
         orders)
```

If any run fails, none apply. It answers each run's tag, and discards any
rows.
