(** SASLprep (RFC 4013), as Postgres applies it to a password. *)

val password : string -> string
(** The prepared password, or the input unchanged where Postgres uses it as is:
    all ASCII, not UTF-8, empty after mapping, or refused (a prohibited or
    unassigned character, or mixed directions). *)
