(** Text encodings of scalars. Parameters are always sent as text; results are
    text unless binary was requested ({!Value} reads either). Decoders return
    [None] on malformed input. *)

val int : int -> string
(** In decimal. *)

val to_int : string -> int option
(** Decimal, within OCaml's [int]. *)

val float : float -> string
(** 17 significant digits, so a double round-trips; [NaN] and infinities as
    Postgres spells them. *)

val to_float : string -> float option
(** A decimal, or [NaN] and the infinities as Postgres spells them. *)

val bool : bool -> string
(** [true] or [false], which Postgres reads. *)

val to_bool : string -> bool option
(** [t] or [f], which Postgres writes. *)

val bytes : string -> string
(** [bytea] hex form ([\x...]). Decode with {!Value.bytes}. *)

val timestamptz : int -> string
(** Microseconds since the epoch, as ISO 8601 in UTC (valid in any [DateStyle]).
*)

val to_date : string -> int option
(** [YYYY-MM-DD] ([DateStyle=ISO]) as days since 1970-01-01. BC dates and years
    past 9999 are [None]. *)

val to_timestamptz : string -> int option
(** [DateStyle=ISO] output, in any time zone, as microseconds since the epoch.
    BC dates, years past 9999 and [infinity] are [None]. *)
