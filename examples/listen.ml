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
