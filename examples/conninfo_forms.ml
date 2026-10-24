let url =
  Postgres_eio.Conninfo.of_string
    "postgres://app:secret@db.internal:5432/shop?sslmode=verify-full"

let keywords =
  Postgres_eio.Conninfo.of_string
    "host=db.internal port=5432 user=app password='a secret' dbname=shop \
     sslmode=verify-full"
