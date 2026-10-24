let add_order conn ~id ~total =
  Postgres_eio.execute conn "insert into orders values ($1, $2)"
    ~params:[ Some id; Some total ]
