let from_environment pgpass_contents =
  Postgres_eio.Conninfo.of_string
    ~defaults:(Postgres_eio.Conninfo.environment Sys.getenv_opt)
    "dbname=shop"
  |> Result.map (Postgres_eio.Conninfo.passfile pgpass_contents)
