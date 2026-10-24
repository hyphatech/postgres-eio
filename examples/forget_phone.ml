let forget_phone conn ~customer =
  Postgres_eio.execute conn "update customers set phone = $1 where id = $2"
    ~params:[ None; Some customer ]
