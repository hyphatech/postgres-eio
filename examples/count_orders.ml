let count pool =
  Postgres_eio.Pool.use pool (fun conn ->
      Postgres_eio.query conn "select count(*) from orders" ~params:[]
        ~init:None ~row:(fun _ row ->
          match row with
          | [| Some n |] -> Postgres_eio.Text.to_int n
          | _ -> None))
