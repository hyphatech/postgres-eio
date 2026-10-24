let healthy pool =
  let stats = Postgres_eio.Pool.stats pool in
  stats.idle > 0 || stats.waiting = 0
