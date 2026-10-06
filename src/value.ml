(* Binary forms follow Postgres's send functions: big-endian integers, IEEE
   floats, dates and times since 2000-01-01, jsonb's text after a version
   byte. *)

(* pg_type oids. *)
let bool_oid = 16
let bytea_oid = 17
let int8_oid = 20
let int2_oid = 21
let int4_oid = 23
let text_oid = 25
let oid_oid = 26
let json_oid = 114
let float4_oid = 700
let float8_oid = 701
let varchar_oid = 1043
let date_oid = 1082
let timestamp_oid = 1114
let timestamptz_oid = 1184
let interval_oid = 1186
let uuid_oid = 2950
let jsonb_oid = 3802

let binary oid =
  List.exists
    (Int.equal (Oid.to_int oid))
    [
      bool_oid;
      bytea_oid;
      int8_oid;
      int2_oid;
      int4_oid;
      text_oid;
      oid_oid;
      json_oid;
      float4_oid;
      float8_oid;
      varchar_oid;
      date_oid;
      timestamp_oid;
      timestamptz_oid;
      interval_oid;
      uuid_oid;
      jsonb_oid;
    ]

let is (c : Column.t) oid = Int.equal (Oid.to_int c.type_oid) oid

(* A text cell is read only where its binary form would be, so text and
   binary give the same answer. A type always sent as text ([numeric], a
   domain) has no binary answer to match, and is read as its text says. *)
let readable (c : Column.t) oids =
  (not (binary c.type_oid)) || List.exists (is c) oids

let in_text c oids decode s = if readable c oids then decode s else None
let integers = [ int2_oid; int4_oid; int8_oid; oid_oid ]

(* Postgres's epoch, 2000-01-01, relative to Unix's; and years 1 to 9999,
   the range the text forms read, in days. *)
let epoch_days = 10957
let epoch_us = 946_684_800_000_000
let first_day = -719162
let past_last_day = 2932897
let us_per_day = 86_400_000_000

let bool (c : Column.t) s =
  match c.format with
  | Column.Text -> in_text c [ bool_oid ] Text.to_bool s
  | Column.Binary -> (
      if not (is c bool_oid && String.length s = 1) then None
      else
        match s.[0] with
        | '\001' -> Some true
        | '\000' -> Some false
        | _ -> None)

(* An [int8] may not fit OCaml's 63-bit [int]. *)
let int_of_int64 v =
  if
    Int64.compare v (Int64.of_int max_int) <= 0
    && Int64.compare v (Int64.of_int min_int) >= 0
  then Some (Int64.to_int v)
  else None

let int (c : Column.t) s =
  match c.format with
  | Column.Text -> in_text c integers Text.to_int s
  | Column.Binary -> (
      match String.length s with
      | 2 when is c int2_oid -> Some (String.get_int16_be s 0)
      | 4 when is c int4_oid -> Some (Int32.to_int (String.get_int32_be s 0))
      | 4 when is c oid_oid ->
          Some (Int32.to_int (String.get_int32_be s 0) land 0xFFFF_FFFF)
      | 8 when is c int8_oid -> int_of_int64 (String.get_int64_be s 0)
      | _ -> None)

let int64 (c : Column.t) s =
  match c.format with
  | Column.Text -> in_text c integers Text.to_int64 s
  | Column.Binary -> (
      match String.length s with
      | 2 when is c int2_oid -> Some (Int64.of_int (String.get_int16_be s 0))
      | 4 when is c int4_oid -> Some (Int64.of_int32 (String.get_int32_be s 0))
      | 4 when is c oid_oid ->
          Some
            (Int64.logand
               (Int64.of_int32 (String.get_int32_be s 0))
               0xFFFF_FFFFL)
      | 8 when is c int8_oid -> Some (String.get_int64_be s 0)
      | _ -> None)

(* Microseconds, then days and months, as Postgres's [interval_send] writes
   them; microseconds past OCaml's [int] are refused. *)
let interval (c : Column.t) s =
  match c.format with
  | Column.Text -> in_text c [ interval_oid ] Text.to_interval s
  | Column.Binary ->
      if not (is c interval_oid && String.length s = 16) then None
      else
        Option.map
          (fun microseconds ->
            {
              Interval.months = Int32.to_int (String.get_int32_be s 12);
              days = Int32.to_int (String.get_int32_be s 8);
              microseconds;
            })
          (int_of_int64 (String.get_int64_be s 0))

(* Round to single precision, so text and binary float4 agree. *)
let single x = Int32.float_of_bits (Int32.bits_of_float x)

let float (c : Column.t) s =
  match c.format with
  | Column.Text ->
      let v = in_text c [ float4_oid; float8_oid ] Text.to_float s in
      if is c float4_oid then Option.map single v else v
  | Column.Binary -> (
      match String.length s with
      | 4 when is c float4_oid ->
          Some (Int32.float_of_bits (String.get_int32_be s 0))
      | 8 when is c float8_oid ->
          Some (Int64.float_of_bits (String.get_int64_be s 0))
      | _ -> None)

let hex_value c =
  match c with
  | '0' .. '9' -> Some (Char.code c - 48)
  | 'a' .. 'f' -> Some (Char.code c - 87)
  | 'A' .. 'F' -> Some (Char.code c - 55)
  | _ -> None

(* bytea text: [\x] hex, or the escape form ([\\] or three octal digits). *)
let bytea_of_text s =
  let n = String.length s in
  if n >= 2 && String.starts_with ~prefix:"\\x" s then
    if (n - 2) mod 2 <> 0 then None
    else
      let b = Bytes.create ((n - 2) / 2) in
      let rec go i =
        if i >= Bytes.length b then Some (Bytes.to_string b)
        else
          match (hex_value s.[2 + (2 * i)], hex_value s.[3 + (2 * i)]) with
          | Some h, Some l ->
              Bytes.set b i (Char.chr ((h * 16) + l));
              go (i + 1)
          | _ -> None
      in
      go 0
  else
    let b = Buffer.create n in
    let octal c = match c with '0' .. '7' -> true | _ -> false in
    let rec go i =
      if i >= n then Some (Buffer.contents b)
      else if not (Char.equal s.[i] '\\') then (
        Buffer.add_char b s.[i];
        go (i + 1))
      else if i + 1 < n && Char.equal s.[i + 1] '\\' then (
        Buffer.add_char b '\\';
        go (i + 2))
      else if i + 3 < n && octal s.[i + 1] && octal s.[i + 2] && octal s.[i + 3]
      then (
        let d j = Char.code s.[i + j] - 48 in
        Buffer.add_char b (Char.chr (((d 1 * 64) + (d 2 * 8) + d 3) land 0xff));
        go (i + 4))
      else None
    in
    go 0

let bytes (c : Column.t) s =
  match c.format with
  | Column.Text -> in_text c [ bytea_oid ] bytea_of_text s
  | Column.Binary -> if is c bytea_oid then Some s else None

let uuid (c : Column.t) s =
  match c.format with
  | Column.Text -> in_text c [ uuid_oid ] Uuidm.of_string s
  | Column.Binary ->
      if is c uuid_oid && String.length s = 16 then Uuidm.of_binary_string s
      else None

let date (c : Column.t) s =
  match c.format with
  | Column.Text -> in_text c [ date_oid ] Text.to_date s
  | Column.Binary ->
      if not (is c date_oid && String.length s = 4) then None
      else
        let days = Int32.to_int (String.get_int32_be s 0) + epoch_days in
        if days >= first_day && days < past_last_day then
          Instant.date_of_days days
        else None

(* Years 1 to 9999 are read, as in text, and the rest refused, [infinity]
   and [-infinity] (the int64 extremes) among them. The bounds are checked
   on the int64: one past OCaml's [int] would wrap into range. *)
let first_us = Int64.of_int ((first_day * us_per_day) - epoch_us)
let past_last_us = Int64.of_int ((past_last_day * us_per_day) - epoch_us)

let microseconds (c : Column.t) oid s =
  if not (is c oid && String.length s = 8) then None
  else
    let v = String.get_int64_be s 0 in
    if Int64.compare v first_us >= 0 && Int64.compare v past_last_us < 0 then
      Instant.of_us (Int64.to_int v + epoch_us)
    else None

let timestamp (c : Column.t) s =
  match c.format with
  | Column.Text -> in_text c [ timestamp_oid ] Text.to_timestamptz s
  | Column.Binary -> microseconds c timestamp_oid s

let timestamptz (c : Column.t) s =
  match c.format with
  | Column.Text -> in_text c [ timestamptz_oid ] Text.to_timestamptz s
  | Column.Binary -> microseconds c timestamptz_oid s

let json (c : Column.t) s =
  match c.format with
  | Column.Text -> in_text c [ json_oid; jsonb_oid ] Option.some s
  | Column.Binary ->
      if is c json_oid then Some s
      else if is c jsonb_oid && String.length s >= 1 && Char.equal s.[0] '\001'
      then Some (String.sub s 1 (String.length s - 1))
      else None

let text (c : Column.t) s =
  match c.format with
  | Column.Text -> Some s
  | Column.Binary ->
      if is c text_oid || is c varchar_oid || is c json_oid then Some s
      else if is c jsonb_oid then json c s
      else if is c uuid_oid then Option.map Uuidm.to_string (uuid c s)
      else if is c bool_oid then
        Option.map (fun b -> if b then "t" else "f") (bool c s)
      else if is c int8_oid && String.length s = 8 then
        Some (Int64.to_string (String.get_int64_be s 0))
      else if is c int2_oid || is c int4_oid || is c oid_oid then
        Option.map string_of_int (int c s)
      else None
