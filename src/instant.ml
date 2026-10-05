(* Ptime keeps an instant as days and picoseconds into the day, the
   picoseconds never negative, so the day is the floor of the division. *)

let us_per_day = 86_400_000_000
let ps_per_us = 1_000_000L

let of_us us =
  let day = if us >= 0 then us / us_per_day else ((us + 1) / us_per_day) - 1 in
  let into_day = Int64.mul (Int64.of_int (us - (day * us_per_day))) ps_per_us in
  Option.bind (Ptime.Span.of_d_ps (day, into_day)) Ptime.of_span

let to_us t =
  let day, ps = Ptime.Span.to_d_ps (Ptime.to_span t) in
  (day * us_per_day) + Int64.to_int (Int64.div ps ps_per_us)

let date_of_days days = Option.map Ptime.to_date (of_us (days * us_per_day))
