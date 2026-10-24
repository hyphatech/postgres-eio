let totals conn ids =
  let answers =
    List.map
      (fun id ->
        Postgres_eio.Pipeline.query conn
          "select total from orders where id = $1" ~params:[ Some id ] ~init:[]
          ~row:(fun acc row -> row :: acc))
      ids
  in
  List.map Postgres_eio.Pipeline.get answers
