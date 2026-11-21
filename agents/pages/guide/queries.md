# Queries and values

A statement is SQL with `$1`, `$2`, ... for its parameters. `query` folds
its rows, `execute` runs it for its effect, and both answer the statement's
tag.

## Parameters and rows

Parameters are sent as text, `None` for NULL, and a cell comes back as
text, `None` for NULL. `Text` writes an OCaml value as Postgres reads it
and reads back what Postgres writes:

```ocaml
type order = { id : int; total : int; placed_at : Ptime.t }

let recent conn ~since ~limit =
  Postgres_eio.query conn
    "select id, total, placed_at from orders where placed_at >= $1 order by \
     placed_at limit $2"
    ~params:
      [
        Some (Postgres_eio.Text.timestamptz since);
        Some (Postgres_eio.Text.int limit);
      ]
    ~init:[]
    ~row:(fun orders row ->
      match row with
      | [| Some id; Some total; Some placed_at |] -> (
          match
            ( Postgres_eio.Text.to_int id,
              Postgres_eio.Text.to_int total,
              Postgres_eio.Text.to_timestamptz placed_at )
          with
          | Some id, Some total, Some placed_at ->
              { id; total; placed_at } :: orders
          | _ -> orders)
      | _ -> orders)
  |> Result.map (fun (orders, _tag) -> List.rev orders)
```

Rows are folded as they arrive and never buffered. If `row` raises, the
connection is closed, the statement cancelled at the server, and the
exception propagates.

`columns`, when given, is called once before any row, even with no rows,
with each column's name, type and format.

NULL is `None`, as a parameter too:

```ocaml
let forget_phone conn ~customer =
  Postgres_eio.execute conn "update customers set phone = $1 where id = $2"
    ~params:[ None; Some customer ]
```

`execute` discards any rows the statement returns. `script` runs one or
more statements without parameters, by the simple protocol, discarding
their rows: `script conn "create table t (id int); create index on t
(id)"`.

## Text

Each encoder writes what Postgres reads, and each decoder answers `None` on
a form it does not read.

| Type | Write | Read |
|---|---|---|
| integers | `Text.int`, `Text.int64` | `Text.to_int`, `Text.to_int64` |
| `float8` | `Text.float`, 17 digits, so a double round-trips | `Text.to_float` |
| `bool` | `Text.bool` | `Text.to_bool` |
| `bytea` | `Text.bytes`, the hex form | `Value.bytes` |
| `timestamptz` | `Text.timestamptz`, in UTC, to the microsecond | `Text.to_timestamptz` |
| `timestamp` | `Text.timestamp`, the reading in UTC | `Value.timestamp` |
| `date` | `Text.date` | `Text.to_date` |
| `interval` | `Text.interval` | `Text.to_interval` |

An instant is a `Ptime.t`, a date a `Ptime.date`. A BC date, a year past
9999 and `infinity` read as `None`. An `Interval.t` keeps months, days and
microseconds apart, as Postgres does, since a month is no fixed number of
days and a day, across a change of clocks, no fixed number of hours.

## Session settings

Every connection sets the session settings the decoders read text by, over
the database's and the role's defaults: `client_encoding=UTF8`,
`DateStyle=ISO`, `IntervalStyle=postgres` and `extra_float_digits=3`. Text
is UTF-8 in a `LATIN1` database too, and a float reads back to its last
digit. A parameter or an `options` setting that changes one of them is
refused.

Other settings are startup parameters, given to `connect` as
`~parameters:[ ("statement_timeout", "10s") ]` or in the string's
`options`. They are sent again whenever the connection is made again, so
they last for its life.

## Text and binary results

`~binary:true` asks for the binary form of the types `Value` reads, and
text for the rest. `Value`'s decoders read a cell in either form, by its
column, so the same code reads both:

```ocaml
let placed conn =
  let columns = ref [||] in
  Postgres_eio.query conn ~binary:true
    ~columns:(fun c -> columns := c)
    "select total, placed_at from orders" ~params:[] ~init:[]
    ~row:(fun placed row ->
      match (!columns, row) with
      | [| total_column; at_column |], [| Some total; Some at |] -> (
          match
            ( Postgres_eio.Value.int total_column total,
              Postgres_eio.Value.timestamptz at_column at )
          with
          | Some total, Some at -> (total, at) :: placed
          | _ -> placed)
      | _ -> placed)
```

`Value` reads `bool`, `bytea`, `int2`, `int4`, `int8`, `oid`, `text`,
`varchar`, `json`, `jsonb`, `float4`, `float8`, `date`, `timestamp`,
`timestamptz`, `interval` and `uuid`. A type with no reader -- `numeric`,
`time`, a range, `inet` -- is always sent as text, and a decoder reads it
if its text is that decoder's form: `Value.int` reads a `numeric` of `42`.
`Value.text` hands a cell over as text, converting a binary one only for
types whose text depends on no setting.

Binary needs the columns' types before the statement is bound, which costs
one extra round trip on a statement's first run, and is refused when the
statement cache is off.

## The statement cache

A statement is parsed once: its first run sends Parse with the run, at no
extra round trip, and later runs only bind. The cache keeps 256 statements
by their SQL text, the least recently used dropped first; `connect`'s
`~statement_cache` changes the number. If a statement's result type
changed, because its table was altered, it is parsed again and retried
once outside a transaction; inside one, the error is returned.
`DISCARD ALL` or `DEALLOCATE` empties the cache.

`~statement_cache:0` turns it off, for a pooler without named statements:
pgbouncer before 1.21 in transaction mode.

## Describing a statement

`describe` answers a statement's parameter types and result columns
without running it:

```ocaml
let columns_of conn sql =
  Postgres_eio.describe conn sql
  |> Result.map (fun (d : Postgres_eio.description) ->
      Array.to_list
        (Array.map (fun (c : Postgres_eio.Column.t) -> c.name) d.columns))
```

A column is its `name`, its `type_oid`, the row of `pg_type` that is its
type, and its `format`, text or binary.

## Tags, the session and timeouts

A statement's tag says what it did: `Tag.command` is `INSERT`, `UPDATE`,
`COMMIT`, ..., and `Tag.rows` the rows changed or returned. After `COMMIT`,
check the command: in an aborted transaction the server answers
`ROLLBACK`.

```ocaml
let server_version conn = Postgres_eio.parameter conn "server_version"

let in_transaction conn =
  match Postgres_eio.status conn with
  | Idle -> false
  | In_transaction | Failed -> true
```

`parameter` answers the latest value of a setting the server reports, such
as `server_version`, `TimeZone` or `DateStyle`. `status` answers whether the
connection is in a transaction, as of the last answer read.

`connect`'s `~timeout` (30 s) is the longest the connection waits on the
server for bytes to move, in either direction; the program's own `row`
function is not timed. For work that waits longer, a migration say,
`set_timeout conn ~timeout:None` lifts it. Bound how long a statement runs
with `statement_timeout`. `cancel`, from another fiber, asks the server to
cancel the running statement, which then fails with SQLSTATE 57014.

A connection is used from one fiber at a time, which may be on any domain;
only `cancel` may be called from another.
