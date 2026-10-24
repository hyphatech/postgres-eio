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
