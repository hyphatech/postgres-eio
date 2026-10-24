let explain e =
  let constraint_name =
    match Postgres_eio.Server_error.constraint_name e with
    | Some name -> " (" ^ name ^ ")"
    | None -> ""
  in
  Postgres_eio.Server_error.sqlstate e
  ^ ": "
  ^ Postgres_eio.Server_error.message e
  ^ constraint_name
