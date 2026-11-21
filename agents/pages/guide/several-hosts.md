# Several hosts

A connection string can name several hosts, comma-separated, each with its
port or one port for all: `host=a,b port=1,2`, or `postgres://a:1,b:2/`.
The driver tries each address of each host in turn until one answers and
is what `target_session_attrs` asks for, so a connection fails over to the
next host when one is down.

```
postgres://app@db1.internal,db2.internal,db3.internal/shop?target_session_attrs=read-write
host=db2.internal,db3.internal user=app dbname=shop target_session_attrs=prefer-standby load_balance_hosts=random
```

The first connects to whichever host is the primary now; the second
spreads its connections over the standbys.

## Failover

Each host's name is looked up, and each of its addresses tried, bounded by
`connect_timeout` if it is not zero, else by the connection's `timeout`. A
host that does not answer, or is not the kind asked for, is passed over
for the next. When none is left, the connection fails with the last
reason.

`target_session_attrs` says which kind of host will do:

| Value | A host that is |
|---|---|
| `any` | any -- the default |
| `read-write` | not a standby, and not `default_transaction_read_only` |
| `read-only` | a standby, or `default_transaction_read_only` |
| `primary` | not a standby |
| `standby` | a standby |
| `prefer-standby` | a standby if any answers, else any host |

The driver tells them apart by the settings the server reports as it
starts a session, `in_hot_standby` and `default_transaction_read_only`, at
no extra round trip. Postgres 14 and later report both; an older server is
refused for any value but `any` and `prefer-standby`, since it does not say
what it is.

## Load balancing

`load_balance_hosts=random` shuffles the hosts, and each host's addresses,
for every connection, so clients spread over them instead of all trying
the first. `disable`, the default, keeps the order given.

## A pool over several hosts

A pool makes its connections from the same string, so each one fails over
on its own, and one made again after a host went down finds the next.
Writes and reads can go to pools of their own:

```ocaml
(* Writes go to whichever host is the primary now, and reads are spread
   over the standbys. *)
let primary =
  "postgres://app@db1.internal,db2.internal,db3.internal/shop?target_session_attrs=read-write"

let standbys =
  "host=db2.internal,db3.internal user=app dbname=shop \
   target_session_attrs=prefer-standby load_balance_hosts=random"

let open_pool ~sw env url =
  match Postgres_eio.Conninfo.of_string url with
  | Error e -> Error e
  | Ok conninfo ->
      Postgres_eio.Pool.create ~sw ~net:(Eio.Stdenv.net env)
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        conninfo
      |> Result.map_error Postgres_eio.error_to_string

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match (open_pool ~sw env primary, open_pool ~sw env standbys) with
  | Ok writes, Ok reads ->
      Postgres_eio.Pool.close writes;
      Postgres_eio.Pool.close reads
  | Error e, _ | _, Error e -> prerr_endline e
```

A connection's `revive`, and a pool's lend of a connection that was
closed, connect again by the same search.
