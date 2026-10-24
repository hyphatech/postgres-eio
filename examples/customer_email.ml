let email pool ~customer =
  match
    Postgres_eio.Pool.use pool (fun conn ->
        Postgres_eio.query conn "select email from customers where id = $1"
          ~params:[ Some customer ] ~init:None ~row:(fun _ row ->
            match row with [| Some email |] -> Some email | _ -> None))
    |> Result.join
  with
  | Ok (Some email, _tag) -> Ok email
  | Ok (None, _tag) -> Error `Not_found
  | Error e -> Error e

let error_to_string = function
  | `Not_found -> "no such customer"
  | (#Postgres_eio.error | #Postgres_eio.Pool.error) as e ->
      Postgres_eio.Pool.error_to_string e
