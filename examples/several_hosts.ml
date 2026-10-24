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
