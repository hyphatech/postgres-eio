# Errors

Every failure is a value. Driver errors and logs never contain parameters,
passwords, sign-in exchanges or message bytes; a server's error is in its
own words, which can quote a value that failed its cast.

## What failed

Every failure is a polymorphic variant, so a connection's failures join a
pool's and your own in one result:

| | |
|---|---|
| `` `Server e `` | the server refused, and said why (`Server_error`) |
| `` `Refused m `` | the driver refused: an unsafe sign-in, an untrusted certificate, a value it cannot send |
| `` `Lost m `` | sent, and no answer came back -- a timeout, a broken socket; the statement may have run, so it is not run again blindly |
| `` `Unsent m `` | connecting failed before anything was sent; connecting again is safe |
| `` `Connection `Closed `` | the connection was closed before the statement was sent |

Each one says what to do next, so a program matches the ones it handles:

```ocaml
type outcome = Added | Taken | Unknown | Not_sent | Failed of string

let add_customer conn ~email =
  match
    Postgres_eio.execute conn "insert into customers (email) values ($1)"
      ~params:[ Some email ]
  with
  | Ok (_ : Postgres_eio.Tag.t) -> Added
  | Error (`Server e)
    when String.equal (Postgres_eio.Server_error.sqlstate e) "23505" ->
      Taken
  | Error (`Lost _) -> Unknown
  | Error (`Unsent _ | `Connection `Closed) -> Not_sent
  | Error ((`Server _ | `Refused _) as e) ->
      Failed (Postgres_eio.error_to_string e)
```

`error_to_string` prints any of them as a sentence safe to log.

## Which close the connection

A server's error keeps the connection, since the server marks where its
answer ends, and the next statement runs as usual. A failure that leaves
the two sides out of step closes it: a timeout, a broken socket or TLS, or
bytes that break the protocol, and its statement answers `` `Lost ``. An
exception from a `row` function closes it too, and propagates. Every
statement after it answers `` `Connection `Closed `` until `revive` connects again with the same
string and parameters. A pool makes a closed connection again by itself at
its next lend.

On a timeout, a cancellation, or an exception from a callback, the running
statement is first cancelled at the server, as `cancel` does; the request
is given 5 s, or the connection's timeout if that is shorter.

## The server's error

`` `Server e `` holds every field the server sent:

```ocaml
let explain e =
  let constraint_name =
    match Postgres_eio.Server_error.constraint_name e with
    | Some name -> " (" ^ name ^ ")"
    | None -> ""
  in
  Postgres_eio.Server_error.sqlstate e
  ^ ": "
  ^ Postgres_eio.Server_error.message e
  ^ constraint_name
```

| | |
|---|---|
| `Server_error.sqlstate` | the five-character SQLSTATE, e.g. `23505`, a unique violation |
| `Server_error.message` | the primary message, in the server's `lc_messages` |
| `Server_error.detail` | a secondary message, which may quote the row a write was refused for |
| `Server_error.hint` | what the server suggests doing about it |
| `Server_error.constraint_name` | the constraint that refused a write, where one did |
| `Server_error.severity` | `Error`, `Fatal`, which ends the session, `Panic`, which ends every session, ... |
| `Server_error.field` | any field by its code byte: `'R'` is the routine that raised it |

`Server_error.to_string` writes `ERROR 23505: duplicate key value violates
unique constraint ...`. It leaves out the detail, which quotes the refused
row; a message of class 22 still quotes the value that failed its cast.

The server's notices are logged on the `postgres-eio` log source, each at
its own level.

## Joining failures

A borrow from a pool answers the pool's failures around what the
connection answered; `Result.join` makes them one result, and the
program's own tags join them too:

```ocaml
let email pool ~customer =
  match
    Postgres_eio.Pool.use pool (fun conn ->
        Postgres_eio.query conn "select email from customers where id = $1"
          ~params:[ Some customer ] ~init:None ~row:(fun _ row ->
            match row with [| Some email |] -> Some email | _ -> None))
    |> Result.join
  with
  | Ok (Some email, _tag) -> Ok email
  | Ok (None, _tag) -> Error `Not_found
  | Error e -> Error e

let error_to_string = function
  | `Not_found -> "no such customer"
  | (#Postgres_eio.error | #Postgres_eio.Pool.error) as e ->
      Postgres_eio.Pool.error_to_string e
```

`Pool.error_to_string` prints a pool's failures and a connection's alike.

## Exceptions

Only the program's own exceptions pass through: one raised by a callback
(a `row` function, a COPY source) and Eio's cancellation propagate as they
came. Every failure of the driver's own is a value.
