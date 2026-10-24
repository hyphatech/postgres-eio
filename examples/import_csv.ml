let import conn source =
  Postgres_eio.copy_in conn
    "copy orders (id, total) from stdin with (format csv, header)" source
