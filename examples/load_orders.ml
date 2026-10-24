let load conn rows =
  Postgres_eio.copy_in_rows conn ~table:"orders" ~columns:[ "id"; "total" ]
    (Seq.map
       (fun (id, total) -> [| Some id; Some (string_of_int total) |])
       rows)
