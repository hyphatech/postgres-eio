(* A failure returns before the commit; the transaction left open is rolled
   back when the connection goes back. *)
let transfer pool ~from ~into ~amount =
  Postgres_eio.Pool.use pool (fun conn ->
      let ( let* ) = Result.bind in
      let amount = Postgres_eio.Text.int amount in
      let* (_ : Postgres_eio.Tag.t) =
        Postgres_eio.execute conn "begin" ~params:[]
      in
      let* (_ : Postgres_eio.Tag.t) =
        Postgres_eio.execute conn
          "update accounts set balance = balance - $1 where id = $2"
          ~params:[ Some amount; Some from ]
      in
      let* (_ : Postgres_eio.Tag.t) =
        Postgres_eio.execute conn
          "update accounts set balance = balance + $1 where id = $2"
          ~params:[ Some amount; Some into ]
      in
      Postgres_eio.execute conn "commit" ~params:[])
  |> Result.join
