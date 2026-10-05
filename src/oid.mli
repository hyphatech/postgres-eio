(** An object identifier: a row of a system catalogue, such as a type in
    [pg_type] ([23] is [int4]) or a table in [pg_class]. Unsigned, four bytes.
*)

type t

val of_int : int -> t option
(** [None] outside [0] to [4294967295]. *)

val to_int : t -> int
val equal : t -> t -> bool
