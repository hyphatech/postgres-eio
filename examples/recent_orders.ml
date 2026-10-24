type order = { id : int; total : int; placed_at : Ptime.t }

let recent conn ~since ~limit =
  Postgres_eio.query conn
    "select id, total, placed_at from orders where placed_at >= $1 order by \
     placed_at limit $2"
    ~params:
      [
        Some (Postgres_eio.Text.timestamptz since);
        Some (Postgres_eio.Text.int limit);
      ]
    ~init:[]
    ~row:(fun orders row ->
      match row with
      | [| Some id; Some total; Some placed_at |] -> (
          match
            ( Postgres_eio.Text.to_int id,
              Postgres_eio.Text.to_int total,
              Postgres_eio.Text.to_timestamptz placed_at )
          with
          | Some id, Some total, Some placed_at ->
              { id; total; placed_at } :: orders
          | _ -> orders)
      | _ -> orders)
  |> Result.map (fun (orders, _tag) -> List.rev orders)
