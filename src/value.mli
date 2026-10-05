(** Cell decoders that give the same value for text and binary results.

    Each returns [None] for a cell of another type or an unreadable form. Binary
    forms are Postgres's send functions, unchanged since Postgres 10 for these
    types.

    Text [float4] is rounded to single precision so it matches binary, given
    [extra_float_digits >= 1] (the default since Postgres 12). Text dates and
    times are read in [DateStyle=ISO]. An instant within a day of year 1 or
    10000 may print, in a distant time zone, as a year no decoder reads.

    A type with no reader here -- [numeric], [time], a range, [inet] -- is
    always sent as text, since {!binary} asks for no other, and {!text} hands
    it over as the server printed it. *)

val binary : int -> bool
(** Whether this module decodes the type's binary form: [bool], [bytea], [int8],
    [int2], [int4], [text], [oid], [json], [float4], [float8], [varchar],
    [date], [timestamp], [timestamptz], [interval], [uuid] and [jsonb]. *)

val text : Column.t -> string -> string option
(** The cell's text form. Binary cells are converted only for types whose text
    is setting-independent: [text], [varchar], [json], [jsonb], [uuid], [bool]
    and the integers. Others are [None], since their text depends on
    [DateStyle], [TimeZone], [extra_float_digits] or [bytea_output]. *)

val bool : Column.t -> string -> bool option
(** [bool]'s [t] and [f], or its byte. *)

val int : Column.t -> string -> int option
(** [int2], [int4], [int8], [oid], or any integer in text; [None] if it exceeds
    OCaml's [int]. *)

val int64 : Column.t -> string -> int64 option
(** As {!int}, the whole of an [int8]'s range. *)

val float : Column.t -> string -> float option
(** [float4] and [float8], and any number in text. *)

val bytes : Column.t -> string -> string option
(** [bytea]'s bytes: in text, the hex form or the escape form. *)

val uuid : Column.t -> string -> Uuidm.t option
val date : Column.t -> string -> Ptime.date option

val timestamp : Column.t -> string -> Ptime.t option
(** A [timestamp], which has no zone: the instant whose reading in UTC it is, to
    the microsecond. *)

val timestamptz : Column.t -> string -> Ptime.t option
(** The instant, to the microsecond, whatever the session's time zone. *)

val interval : Column.t -> string -> Interval.t option
(** Its binary form, or its text in [IntervalStyle=postgres], the default. *)

val json : Column.t -> string -> string option
(** [json] and [jsonb]'s text; binary [jsonb] is a version byte before it. *)
