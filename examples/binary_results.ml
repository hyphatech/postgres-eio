let placed conn =
  let columns = ref [||] in
  Postgres_eio.query conn ~binary:true
    ~columns:(fun c -> columns := c)
    "select total, placed_at from orders" ~params:[] ~init:[]
    ~row:(fun placed row ->
      match (!columns, row) with
      | [| total_column; at_column |], [| Some total; Some at |] -> (
          match
            ( Postgres_eio.Value.int total_column total,
              Postgres_eio.Value.timestamptz at_column at )
          with
          | Some total, Some at -> (total, at) :: placed
          | _ -> placed)
      | _ -> placed)
