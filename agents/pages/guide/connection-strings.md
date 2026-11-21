# Connection strings

Both libpq forms are accepted: `postgres://user:pass@host:5432/db?sslmode=require`
and `host=db user=app sslmode=require`. A URL may start `postgresql://` too.
Unknown keys are an error, not ignored.

```ocaml
let url =
  Postgres_eio.Conninfo.of_string
    "postgres://app:secret@db.internal:5432/shop?sslmode=verify-full"

let keywords =
  Postgres_eio.Conninfo.of_string
    "host=db.internal port=5432 user=app password='a secret' dbname=shop \
     sslmode=verify-full"
```

`Conninfo.of_string` answers the connection, or a sentence saying what is
wrong with the string. A URL is percent-decoded. A keyword value may be
single-quoted, with backslash escapes, so it can hold a space. An empty
value unsets a key.

## The keys

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

The TLS keys are explained in [TLS and signing in](tls.md),
and `target_session_attrs` and `load_balance_hosts` in
[several hosts](several-hosts.md). `sslpassword` is not
supported, and is an error like any other unknown key: a client key is read
unencrypted.

The driver speaks protocol 3.0 and 3.2, over TCP, a Unix socket or TLS.
`max_protocol_version` is `3.0` by default, since many poolers speak only
3.0; `latest` is 3.2. `options` reads `-c name=value`, `-cname=value` and
`--name=value`. `connect_timeout` of `0` or less is absent, as libpq reads
it, and the connection's `timeout` bounds each attempt instead.

## The environment and .pgpass

The driver reads no environment variables or files unless you pass them in:

```ocaml
let from_environment pgpass_contents =
  Postgres_eio.Conninfo.of_string
    ~defaults:(Postgres_eio.Conninfo.environment Sys.getenv_opt)
    "dbname=shop"
  |> Result.map (Postgres_eio.Conninfo.passfile pgpass_contents)
```

`Conninfo.environment` reads libpq's `PG*` variables for the supported keys
(`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, ...), ignoring an empty one,
and hands them to `of_string` as defaults for the keys the string leaves
out. It takes the function that reads a variable, so a test can hand it
another.

`Conninfo.passfile` takes the contents of a `.pgpass` file and fills each
host's password from it where the string gave none, as libpq does:
`host:port:database:user:password`, `*` wildcards, backslash escapes, first
match wins. Hosts match as written, a socket by its directory. Finding the
file and checking its permissions is the program's:

```ocaml
(* libpq refuses a .pgpass that others can read; checking that is the
   program's, as is finding the file. *)
let contents () =
  match Sys.getenv_opt "HOME" with
  | None -> ""
  | Some home -> (
      match
        In_channel.with_open_bin
          (Filename.concat home ".pgpass")
          In_channel.input_all
      with
      | contents -> contents
      | exception Sys_error _ -> "")
```

## Changing a connection

A connection string is read by its fields (`hosts`, `user`, `database`,
...) and made by `of_string`. Two keys can be changed after:

```ocaml
let maintenance conninfo =
  let conninfo = Postgres_eio.Conninfo.with_database conninfo "postgres" in
  Postgres_eio.Conninfo.with_connect_timeout conninfo Mtime.Span.(10 * s)
```

`with_database` connects to another database, the empty string meaning the
user's name. `with_connect_timeout` bounds each address attempt by a span.
`to_url` writes a URL that parses back to the same connection, minus the
passwords `.pgpass` gave; it writes `connect_timeout` in whole seconds,
rounded up.
