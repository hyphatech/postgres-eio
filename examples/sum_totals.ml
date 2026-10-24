let sum conn =
  Postgres_eio.copy_out_rows conn ~select:"select total from orders" ~init:0
    ~row:(fun sum row ->
      match row with
      | [| Some total |] ->
          sum + Option.value ~default:0 (Postgres_eio.Text.to_int total)
      | _ -> sum)
