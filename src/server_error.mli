(** A server error: every field of its ErrorResponse (protocol 54.8). *)

type t

val of_fields : (char * string) list -> t
(** From an ErrorResponse's or a NoticeResponse's fields, as {!module-Protocol}
    reads them. *)

val fields : t -> (char * string) list
(** Every field, by its code byte, in the order the server sent them. *)

val field : t -> char -> string option
(** One field by its code byte -- ['R'] is the routine that raised it. *)

val sqlstate : t -> string
(** The five-character SQLSTATE, e.g. ["23505"] (unique violation). *)

val severity : t -> string
(** [ERROR], [FATAL] or [PANIC]; unlocalised where the server sends it so. *)

val message : t -> string
(** The primary message, in the server's [lc_messages]. *)

val detail : t -> string option
(** A secondary message, which may quote the row a write was refused for. *)

val hint : t -> string option
(** What the server suggests doing about it. *)

val constraint_name : t -> string option
(** The constraint that refused a write, where one did. *)

val to_string : t -> string
(** ["ERROR 23505: duplicate key value violates unique constraint ..."]. Omits
    the detail, which quotes the refused row. Class 22 messages still quote the
    value that failed its cast. *)
