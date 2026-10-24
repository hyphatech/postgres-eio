let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match Postgres_eio.Conninfo.of_string "postgres://app@localhost/shop" with
  | Error e -> prerr_endline e
  | Ok conninfo -> (
      match
        Postgres_eio.Pool.create ~sw ~net:(Eio.Stdenv.net env)
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          ~size:16
          ~wait:Mtime.Span.(500 * ms)
          conninfo
      with
      | Error e -> prerr_endline (Postgres_eio.error_to_string e)
      | Ok pool ->
          let stats = Postgres_eio.Pool.stats pool in
          Printf.printf "%d connections, %d idle\n" stats.size stats.idle;
          Postgres_eio.Pool.close pool)
