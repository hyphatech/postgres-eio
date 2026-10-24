let handle payload = print_endline ("order " ^ payload)
let reload () = print_endline "reloading every order"

let rec follow listener =
  match Postgres_eio.Listener.next listener with
  | Ok (Notification { payload; _ }) ->
      handle payload;
      follow listener
  | Ok Reconnected ->
      reload ();
      follow listener
  | Error e -> Error e
