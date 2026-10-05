let int = string_of_int
let to_int = int_of_string_opt

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

(* ISO 8601 in UTC, read whatever the server's DateStyle. *)
let timestamptz us =
  let day = floor_div us us_per_day in
  let rest = us - (day * us_per_day) in
  let y, m, d = civil_from_days day in
  let s = rest / 1_000_000 in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%06dZ" y m d (s / 3600)
    (s / 60 mod 60)
    (s mod 60) (rest mod 1_000_000)

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
    Some (days_from_civil y m d)

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
  let i, frac =
    if at 19 '.' then
      let rec fend j =
        if j < String.length s && s.[j] >= '0' && s.[j] <= '9' then fend (j + 1)
        else j
      in
      let j = fend 20 in
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
  Some ((seconds * 1_000_000) + frac)
