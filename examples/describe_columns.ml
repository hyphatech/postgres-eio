let columns_of conn sql =
  Postgres_eio.describe conn sql
  |> Result.map (fun (d : Postgres_eio.description) ->
      Array.to_list
        (Array.map (fun (c : Postgres_eio.Column.t) -> c.name) d.columns))
