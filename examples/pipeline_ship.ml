let ship conn ids =
  List.map
    (fun id ->
      Postgres_eio.Pipeline.execute conn
        "update orders set shipped = true where id = $1" ~params:[ Some id ])
    ids
  |> List.map Postgres_eio.Pipeline.get
