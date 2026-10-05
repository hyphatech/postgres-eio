type t = (char * string) list

let of_fields fields = fields
let fields t = t
let field t code = List.assoc_opt code t
let sqlstate t = Option.value (field t 'C') ~default:""

type severity =
  | Error
  | Fatal
  | Panic
  | Warning
  | Notice
  | Debug
  | Info
  | Log
  | Other of string

(* V is never localised; S is in the session's language. *)
let severity_text t =
  match field t 'V' with
  | Some v -> v
  | None -> Option.value (field t 'S') ~default:"ERROR"

let severity t =
  match severity_text t with
  | "ERROR" -> Error
  | "FATAL" -> Fatal
  | "PANIC" -> Panic
  | "WARNING" -> Warning
  | "NOTICE" -> Notice
  | "DEBUG" -> Debug
  | "INFO" -> Info
  | "LOG" -> Log
  | other -> Other other

let message t = Option.value (field t 'M') ~default:""
let detail t = field t 'D'
let hint t = field t 'H'
let constraint_name t = field t 'n'

(* No detail: it quotes the refused row, which may hold a secret. The
   message stays although class 22 messages quote the failed value. *)
let to_string t =
  Printf.sprintf "%s %s: %s" (severity_text t) (sqlstate t) (message t)
