let add_orders conn orders =
  Postgres_eio.execute_many conn
    "insert into orders (id, total) values ($1, $2)"
    ~params:
      (List.map
         (fun (id, total) -> [ Some id; Some (Postgres_eio.Text.int total) ])
         orders)
