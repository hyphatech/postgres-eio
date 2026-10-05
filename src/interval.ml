type t = { months : int; days : int; microseconds : int }

let equal a b =
  a.months = b.months && a.days = b.days && a.microseconds = b.microseconds
