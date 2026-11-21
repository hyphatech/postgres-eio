# LISTEN/NOTIFY

A notification is a message a session sends on a channel, delivered to
every session listening on it when the transaction commits.

## Listening

```ocaml
let handle payload = print_endline ("order " ^ payload)
let reload () = print_endline "reloading every order"

let rec follow listener =
  match Postgres_eio.Listener.next listener with
  | Ok (Notification { payload; _ }) ->
      handle payload;
      follow listener
  | Ok Reconnected ->
      reload ();
      follow listener
  | Error e -> Error e
```

A `Listener` is its own connection. It detects a dead server by pinging
it after `keep_alive` (10 s) of silence, reconnects with backoff and listens again, and returns
`Reconnected` because notifications sent meanwhile are lost. `next` can
be raced against a timer, however short its tick: a cancelled wait keeps
the connection and loses nothing, and the ping still comes.

A program connects a listener, listens on a channel and waits:

```ocaml
let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env and mono_clock = Eio.Stdenv.mono_clock env in
  match Postgres_eio.Conninfo.of_string "postgres://app@localhost/shop" with
  | Error e -> prerr_endline e
  | Ok conninfo -> (
      match Postgres_eio.Listener.connect ~sw ~net ~mono_clock conninfo with
      | Error e -> prerr_endline (Postgres_eio.error_to_string e)
      | Ok listener ->
          (match Postgres_eio.Listener.listen listener "orders" with
          | Error e -> prerr_endline (Postgres_eio.error_to_string e)
          | Ok () -> (
              match Postgres_eio.Listener.next listener with
              | Ok (Notification { payload; _ }) -> print_endline payload
              | Ok Reconnected -> print_endline "reconnected"
              | Error e -> prerr_endline (Postgres_eio.error_to_string e)));
          Postgres_eio.Listener.close listener)
```

`Listener.connect` takes `connect`'s options and `~keep_alive`.
`Listener.listen` quotes the channel: `"Jobs"` hears
`pg_notify('Jobs', ...)`, not an unquoted `NOTIFY Jobs`, which Postgres
folds to `jobs`. `Listener.unlisten` stops one, which is then not listened
to again on reconnect. Notifications arrive in order, each with its
channel, its payload and the `pid` of the session that sent it.

## Reconnecting

`next` notices a dead server within `keep_alive` and the connection's
`timeout`, with no fiber in the background. It reconnects at once, then
with backoff from 1 s to 30 s, logging each failure as a `warn`, and
answers `Reconnected`: re-read any state the notifications kept current. A
server that is starting up, which answers with an error of class 57P, is
retried as a failed connection is; any other refusal, of the sign-in or of
`LISTEN`, is returned as an error. After `Listener.close`, `next` answers
`` `Connection `Closed ``.

## A timer

```ocaml
let next_within ~clock listener =
  Eio.Time.Timeout.run
    (Eio.Time.Timeout.v clock Mtime.Span.(1 * s))
    (fun () -> Postgres_eio.Listener.next listener)
```

A tick shorter than `keep_alive` does not put the ping off, and a ping
under way when the wait is cancelled is finished first, within the
timeout.

## Notifying

```ocaml
let order_placed conn ~id = Postgres_eio.notify conn ~channel:"orders" id
```

`notify` runs `select pg_notify(channel, payload)` on any connection. It is
delivered on commit, not on rollback. The channel is case-sensitive, and a
payload of 8000 bytes or more is refused before it is sent.

## Limits

A listener that stops reading fills the server's notification queue, after
which every NOTIFY in the database fails. For many subjects, listen on one
channel and route by payload. A pooled connection never listens. LISTEN
does not work through pgbouncer in transaction mode.
