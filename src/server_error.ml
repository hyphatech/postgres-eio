type t = (char * string) list

let of_fields fields = fields
let fields t = t
let field t code = List.assoc_opt code t
let sqlstate t = Option.value (field t 'C') ~default:""

(* V is never localised; S is in the session's language. *)
let severity t =
  match field t 'V' with
  | Some v -> v
  | None -> Option.value (field t 'S') ~default:"ERROR"

let message t = Option.value (field t 'M') ~default:""
let detail t = field t 'D'
let hint t = field t 'H'
let constraint_name t = field t 'n'

(* No detail: it quotes the refused row, which may hold a secret. The
   message stays although class 22 messages quote the failed value. *)
let to_string t =
  Printf.sprintf "%s %s: %s" (severity t) (sqlstate t) (message t)
