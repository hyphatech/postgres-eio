let still_in_transaction conn =
  Postgres_eio.Pipeline.drain conn
  |> Result.map (fun () ->
      match Postgres_eio.status conn with
      | Idle -> false
      | In_transaction | Failed -> true)
