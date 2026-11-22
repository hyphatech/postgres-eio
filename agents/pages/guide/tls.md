# TLS and signing in

A connection for production checks the server's certificate, names the
ways it may sign in, and refuses before sending a secret when the server
asks for something else:

```ocaml
let production =
  "host=db.internal user=app dbname=shop sslmode=verify-full \
   sslrootcert=/etc/ssl/db-ca.pem channel_binding=require \
   require_auth=scram-sha-256"

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match Postgres_eio.Conninfo.of_string production with
  | Error e -> prerr_endline e
  | Ok conninfo -> (
      match
        Postgres_eio.connect ~sw ~net:(Eio.Stdenv.net env)
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          conninfo
      with
      | Ok conn ->
          print_endline "signed in";
          Postgres_eio.close conn
      | Error (`Refused m) -> prerr_endline ("not signed in: " ^ m)
      | Error e -> prerr_endline (Postgres_eio.error_to_string e))
```

## sslmode

`sslmode` means what it means to libpq. `require` encrypts and checks no
certificate, so it keeps out a listener but not a server that pretends;
`verify-ca` checks the certificate against `sslrootcert`, and
`verify-full` checks too that it names the host -- the mode for
production. With no `sslmode`, a host on this machine (`localhost`,
127.0.0.0/8, `::1`, a Unix socket) is `prefer`, and any other host is
`require`, so a connection that crosses a network is encrypted unless the
string says `sslmode=disable` or `prefer`. `sslrootcert` is refused with
any mode but `verify-full` and `verify-ca`, or with none, since nothing
else reads it: write `sslmode=verify-full` to check against the file.

| Mode | The connection |
|---|---|
| `disable` | never TLS |
| `allow` | plain, and TLS only if the server refuses plain |
| `prefer` | TLS if the server offers it and the handshake succeeds, else plain |
| `require` | encrypted, and the server's certificate not checked |
| `verify-ca` | encrypted, and the certificate checked against `sslrootcert`, or the system's authorities when absent |
| `verify-full` | as `verify-ca`, and the certificate checked to name the host |

The mode is decided for each host by where the connection goes: `hostaddr`
when given, else `host`. With `prefer`, a server that refuses TLS, a
handshake that fails or a sign-in that fails inside TLS is tried again
without it, as libpq does. A Unix socket never uses TLS.

`sslnegotiation=direct` starts TLS from the first byte, with ALPN
`postgresql`, which saves a round trip. It needs `sslmode=require` or
stronger, and with no `sslmode` every host is `require`.

## What the driver reads

The driver reads files only from `sslrootcert`, `sslcert` and `sslkey`, and
the system's authorities only for `verify-ca` or `verify-full` with no
`sslrootcert`. What a connection reads is what its string names.

`sslcert` is a PEM certificate chain and `sslkey` its key, unencrypted,
for a server that signs in by client certificate.

## Signing in

The driver signs in by SCRAM-SHA-256 (RFC 7677), bound to the TLS channel
when the server offers it, by MD5, by client certificate, by trust, or by a
cleartext password inside TLS only. A server that asks for a cleartext
password on a connection that is not encrypted is refused, and the
password is not sent.

`channel_binding` decides what SCRAM does with the TLS channel:

| Value | |
|---|---|
| `disable` | never bind |
| `prefer` | bind when the server offers it -- the default |
| `require` | refuse, before sending a secret, a sign-in that is not bound |

Binding ties the sign-in to the server's certificate, so a server in the
middle that holds another certificate cannot relay it.

`require_auth` lists the ways the server may ask for, of `password`,
`md5`, `scram-sha-256` and `none` (trust), or each negated with `!`. A
server that asks for another is refused, and nothing is sent.

A refusal is `` `Refused ``, with a sentence saying what was refused; see
[errors](errors.md).

## Randomness

TLS and SCRAM draw from mirage-crypto's default random generator. One the
application set is kept, and where it set none the first connection sets
`Mirage_crypto_rng_unix.use_default`'s.
