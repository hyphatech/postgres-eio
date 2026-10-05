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

val timestamptz : Ptime.t -> string
(** As ISO 8601 in UTC, to the microsecond (valid in any [DateStyle]). Below the
    microsecond, which a [timestamptz] cannot hold, is dropped towards the past.
*)

val timestamp : Ptime.t -> string
(** As ISO 8601 with no zone, for a [timestamp]: the reading in UTC, to the
    microsecond. *)

val date : Ptime.date -> string
(** [YYYY-MM-DD]. A date that is not one, or a year outside 1 to 9999, is the
    server's to refuse. *)

val to_date : string -> Ptime.date option
(** [YYYY-MM-DD] ([DateStyle=ISO]). BC dates, years past 9999 and a date that is
    not one are [None]. *)

val to_timestamptz : string -> Ptime.t option
(** [DateStyle=ISO] output, in any time zone. BC dates, years past 9999,
    [infinity] and a time that is not one are [None]. *)
