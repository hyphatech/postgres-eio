(** Between the driver's own arithmetic, in microseconds and days since
    1970-01-01, and Ptime's types, which its interface speaks. *)

val of_us : int -> Ptime.t option
(** Microseconds since the epoch; [None] outside Ptime's years 0 to 9999. *)

val to_us : Ptime.t -> int
(** Microseconds since the epoch, below the microsecond dropped towards the
    past. *)

val date_of_days : int -> Ptime.date option
(** Days since 1970-01-01; [None] outside Ptime's years. *)
