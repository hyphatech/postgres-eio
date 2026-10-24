let server_version conn = Postgres_eio.parameter conn "server_version"

let in_transaction conn =
  match Postgres_eio.status conn with
  | Idle -> false
  | In_transaction | Failed -> true
