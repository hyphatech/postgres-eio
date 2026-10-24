let export conn sink =
  Postgres_eio.copy_out conn "copy orders to stdout with (format csv)" ~init:()
    ~chunk:(fun () data -> Eio.Flow.copy_string data sink)
