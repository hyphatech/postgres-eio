(** A Postgres [interval]: months, days and microseconds, each kept apart as
    Postgres keeps them, since a month is no fixed number of days and a day,
    across a change of clocks, no fixed number of hours. Each part carries its
    own sign: [1 mon -1 days] is one month less a day. *)

type t = { months : int; days : int; microseconds : int }

val equal : t -> t -> bool
