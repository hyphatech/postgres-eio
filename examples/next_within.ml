let next_within ~clock listener =
  Eio.Time.Timeout.run
    (Eio.Time.Timeout.v clock Mtime.Span.(1 * s))
    (fun () -> Postgres_eio.Listener.next listener)
