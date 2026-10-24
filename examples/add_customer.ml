type outcome = Added | Taken | Unknown | Not_sent | Failed of string

let add_customer conn ~email =
  match
    Postgres_eio.execute conn "insert into customers (email) values ($1)"
      ~params:[ Some email ]
  with
  | Ok (_ : Postgres_eio.Tag.t) -> Added
  | Error (`Server e)
    when String.equal (Postgres_eio.Server_error.sqlstate e) "23505" ->
      Taken
  | Error (`Lost _) -> Unknown
  | Error (`Unsent _ | `Connection `Closed) -> Not_sent
  | Error ((`Server _ | `Refused _) as e) ->
      Failed (Postgres_eio.error_to_string e)
