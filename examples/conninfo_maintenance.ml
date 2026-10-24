let maintenance conninfo =
  let conninfo = Postgres_eio.Conninfo.with_database conninfo "postgres" in
  Postgres_eio.Conninfo.with_connect_timeout conninfo Mtime.Span.(10 * s)
