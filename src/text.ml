let int = string_of_int
let to_int = int_of_string_opt
let int64 = Int64.to_string
let to_int64 = Int64.of_string_opt

(* 17 significant digits round-trip a double exactly. *)
let float f =
  if Float.is_nan f then "NaN"
  else if Float.equal f Float.infinity then "Infinity"
  else if Float.equal f Float.neg_infinity then "-Infinity"
  else Printf.sprintf "%.17g" f

let to_float = function
  | "NaN" -> Some Float.nan
  | "Infinity" -> Some Float.infinity
  | "-Infinity" -> Some Float.neg_infinity
  | s -> float_of_string_opt s

let bool b = if b then "true" else "false"
let to_bool = function "t" -> Some true | "f" -> Some false | _ -> None

(* Hex, which the server reads whatever its [bytea_output]. *)
let bytes s =
  let hex = "0123456789abcdef" in
  let out = Buffer.create (2 + (2 * String.length s)) in
  Buffer.add_string out "\\x";
  String.iter
    (fun c ->
      Buffer.add_char out hex.[Char.code c lsr 4];
      Buffer.add_char out hex.[Char.code c land 0xf])
    s;
  Buffer.contents out

(* Howard Hinnant's days_from_civil and civil_from_days. *)

let days_from_civil y m d =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let mp = (m + 9) mod 12 in
  let doy = (((153 * mp) + 2) / 5) + d - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

let civil_from_days z =
  let z = z + 719468 in
  let era = (if z >= 0 then z else z - 146096) / 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let d = doy - (((153 * mp) + 2) / 5) + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  ((yoe + (era * 400) + if m <= 2 then 1 else 0), m, d)

let floor_div a b = if a >= 0 then a / b else ((a + 1) / b) - 1
let us_per_day = 86_400_000_000

(* ISO 8601, read whatever the server's DateStyle: [zone] is [Z] for an
   instant and empty for a reading on no clock. *)
let iso ~zone t =
  let us = Instant.to_us t in
  let day = floor_div us us_per_day in
  let rest = us - (day * us_per_day) in
  let y, m, d = civil_from_days day in
  let s = rest / 1_000_000 in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%06d%s" y m d (s / 3600)
    (s / 60 mod 60)
    (s mod 60) (rest mod 1_000_000) zone

let timestamptz t = iso ~zone:"Z" t
let timestamp t = iso ~zone:"" t
let date (y, m, d) = Printf.sprintf "%04d-%02d-%02d" y m d
let is_digit = function '0' .. '9' -> true | _ -> false

let digits s i n =
  if i + n > String.length s then None
  else
    let rec go j acc =
      if j = i + n then Some acc
      else
        match s.[j] with
        | '0' .. '9' as c -> go (j + 1) ((acc * 10) + Char.code c - 48)
        | _ -> None
    in
    go i 0

(* [YYYY-MM-DD]; BC dates are refused. *)
let to_date s =
  let ( let* ) = Option.bind in
  let at i c = i < String.length s && Char.equal s.[i] c in
  if String.length s <> 10 then None
  else
    let* y = digits s 0 4 in
    let* m = if at 4 '-' then digits s 5 2 else None in
    let* d = if at 7 '-' then digits s 8 2 else None in
    Option.map Ptime.to_date (Ptime.of_date (y, m, d))

(* [YYYY-MM-DD HH:MM:SS[.ffffff]+HH[:MM[:SS]]] in any time zone. BC dates,
   years past 9999 and infinity are refused. *)
let to_timestamptz s =
  let ( let* ) = Option.bind in
  let at i c = i < String.length s && Char.equal s.[i] c in
  let* y = digits s 0 4 in
  let* mo = if at 4 '-' then digits s 5 2 else None in
  let* d = if at 7 '-' then digits s 8 2 else None in
  let* h = if at 10 ' ' || at 10 'T' then digits s 11 2 else None in
  let* mi = if at 13 ':' then digits s 14 2 else None in
  let* sec = if at 16 ':' then digits s 17 2 else None in
  let* _ = Ptime.of_date_time ((y, mo, d), ((h, mi, sec), 0)) in
  let i, frac =
    if at 19 '.' then
      let rec fraction_end j =
        if j < String.length s && is_digit s.[j] then fraction_end (j + 1)
        else j
      in
      let j = fraction_end 20 in
      let f = String.sub (String.sub s 20 (j - 20) ^ "000000") 0 6 in
      (j, int_of_string_opt f)
    else (19, Some 0)
  in
  let* frac = frac in
  let* offset_s =
    if i >= String.length s then Some 0
    else
      let* sign =
        match s.[i] with '+' -> Some 1 | '-' -> Some (-1) | _ -> None
      in
      let* oh = digits s (i + 1) 2 in
      let part j =
        if at j ':' then Option.map (fun v -> (v, j + 3)) (digits s (j + 1) 2)
        else Some (0, j)
      in
      let* om, j = part (i + 3) in
      let* os, j = part j in
      (* A trailing " BC" lands here. *)
      if j = String.length s then Some (sign * ((oh * 3600) + (om * 60) + os))
      else None
  in
  let seconds =
    (days_from_civil y mo d * 86_400) + (h * 3600) + (mi * 60) + sec - offset_s
  in
  Instant.of_us ((seconds * 1_000_000) + frac)

let us_per_hour = 3_600_000_000

(* ISO 8601 with designators, which the server reads whatever its
   IntervalStyle: each part signed on its own, as an interval's are. The
   server reads a number with a fraction as a double, so the time is whole
   hours and then seconds under an hour, both exact in a double. *)
let interval (i : Interval.t) =
  let sign = if i.microseconds < 0 then "-" else "" in
  (* Split before taking magnitudes: [abs min_int] is still negative. *)
  let hours = abs (i.microseconds / us_per_hour) in
  let rest = abs (i.microseconds mod us_per_hour) in
  Printf.sprintf "P%dM%dDT%s%dH%s%d.%06dS" i.months i.days sign hours sign
    (rest / 1_000_000) (rest mod 1_000_000)

(* [IntervalStyle=postgres], the default: [1 year 2 mons -3 days
   -04:05:06.789], each part signed on its own, a part that is zero left out,
   the time last, and [00:00:00] for no time at all. *)
let to_interval s =
  let ( let* ) = Option.bind in
  let natural t =
    if String.length t > 0 && String.for_all is_digit t then int_of_string_opt t
    else None
  in
  let signed t =
    let n = String.length t in
    if n > 1 && Char.equal t.[0] '-' then
      Option.map Int.neg (natural (String.sub t 1 (n - 1)))
    else if n > 1 && Char.equal t.[0] '+' then natural (String.sub t 1 (n - 1))
    else natural t
  in
  let time t =
    let n = String.length t in
    let negative = n > 0 && Char.equal t.[0] '-' in
    let t =
      if n > 0 && (negative || Char.equal t.[0] '+') then String.sub t 1 (n - 1)
      else t
    in
    match String.split_on_char ':' t with
    | [ h; m; sec ] ->
        let whole, frac =
          match String.split_on_char '.' sec with
          | [ whole ] -> (whole, Some 0)
          | [ whole; f ] when String.length f <= 6 ->
              (whole, natural (f ^ String.make (6 - String.length f) '0'))
          | _ -> (sec, None)
        in
        let* h = natural h in
        let* m = natural m in
        let* whole = natural whole in
        let* frac = frac in
        if m >= 60 || whole >= 60 then None
        else
          (* Postgres keeps an [int64]; past OCaml's [int] is refused, as an
             [int8] past it is. A negative time reaches one microsecond
             further, to [min_int], so its bound is worked out below zero. *)
          let rest = (((m * 60) + whole) * 1_000_000) + frac in
          let most_hours =
            if negative then (min_int + rest) / -us_per_hour
            else (max_int - rest) / us_per_hour
          in
          if h > most_hours then None
          else if negative then Some (-(h * us_per_hour) - rest)
          else Some ((h * us_per_hour) + rest)
    | _ -> None
  in
  let rec parts (acc : Interval.t) = function
    | [ t ] ->
        let* microseconds = time t in
        Some { acc with microseconds }
    | n :: unit :: rest -> (
        let* n = signed n in
        let* acc =
          match unit with
          | "year" | "years" -> Some { acc with months = acc.months + (12 * n) }
          | "mon" | "mons" -> Some { acc with months = acc.months + n }
          | "day" | "days" -> Some { acc with days = acc.days + n }
          | _ -> None
        in
        match rest with [] -> Some acc | _ -> parts acc rest)
    | [] -> None
  in
  parts { months = 0; days = 0; microseconds = 0 } (String.split_on_char ' ' s)
