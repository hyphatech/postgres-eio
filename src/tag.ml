type t = { command : string; rows : int option }

let empty = { command = ""; rows = None }

(* 54.7 CommandComplete: INSERT has an oid before its count; SELECT,
   UPDATE, DELETE, MERGE, FETCH, MOVE and COPY have a count; others none. *)
let of_string tag =
  match String.split_on_char ' ' tag with
  | [ ("INSERT" as command); _oid; n ] ->
      { command; rows = int_of_string_opt n }
  | [
   (("SELECT" | "UPDATE" | "DELETE" | "MERGE" | "FETCH" | "MOVE" | "COPY") as
    command);
   n;
  ] ->
      { command; rows = int_of_string_opt n }
  | _ -> { command = tag; rows = None }

let command t = t.command
let rows t = t.rows
