(* The frontend/backend protocol as values and bytes, without IO.

   Section numbers are chapter 54 of the Postgres 18 docs (54.7 is Message
   Formats). The docs are the authority, not what a server tolerates. *)

type transaction_status = Idle | In_transaction | Failed

(* Frontend messages *)

type target = Statement | Portal
type format = Text | Binary

type frontend =
  | Startup of { minor : int; parameters : (string * string) list }
  | Ssl_request
  | Cancel_request of { pid : int; key : string }
  | Password of string
  | Sasl_initial_response of { mechanism : string; data : string }
  | Sasl_response of string
  | Query of string
  | Parse of { name : string; query : string }
  | Bind of {
      portal : string;
      statement : string;
      params : string option list;
      results : format list;
    }
  | Execute of { portal : string; max_rows : int }
  | Describe of { target : target; name : string }
  | Close of { target : target; name : string }
  | Sync
  | Terminate
  | Copy_data of string
  | Copy_done
  | Copy_fail of string

let ssl_request_code = 80877103
let cancel_request_code = 80877102
let int32_max = 0x7fff_ffff
let int16_max = 0xffff
let add_int32 b n = Buffer.add_int32_be b (Int32.of_int n)
let add_int16 b n = Buffer.add_uint16_be b n

(* A NUL inside a String would end it early and shift every later field. *)
let add_cstring b what s =
  if String.contains s '\000' then
    Error
      (Printf.sprintf "%s holds a NUL byte, which the protocol cannot carry"
         what)
  else (
    Buffer.add_string b s;
    Buffer.add_char b '\000';
    Ok ())

let ( let* ) = Result.bind

let each f l =
  List.fold_left
    (fun acc x ->
      let* () = acc in
      f x)
    (Ok ()) l

(* The length counts itself and the body, not the type byte. *)
let framed tag body =
  let* body =
    let b = Buffer.create 64 in
    let* () = body b in
    Ok (Buffer.contents b)
  in
  if String.length body + 4 > int32_max then
    Error "a message longer than its length field can say"
  else
    let b = Buffer.create (String.length body + 5) in
    Option.iter (Buffer.add_char b) tag;
    add_int32 b (String.length body + 4);
    Buffer.add_string b body;
    Ok (Buffer.contents b)

let targeted target name b =
  Buffer.add_char b (match target with Statement -> 'S' | Portal -> 'P');
  add_cstring b
    (match target with
    | Statement -> "a statement's name"
    | Portal -> "a portal's name")
    name

let encode = function
  | Startup { minor; parameters } ->
      framed None (fun b ->
          add_int32 b ((3 lsl 16) lor minor);
          let* () =
            each
              (fun (k, v) ->
                if String.equal k "" then
                  Error "a startup parameter with no name ends the list early"
                else
                  let* () = add_cstring b "a startup parameter's name" k in
                  add_cstring b "a startup parameter's value" v)
              parameters
          in
          Buffer.add_char b '\000';
          Ok ())
  | Ssl_request ->
      framed None (fun b ->
          add_int32 b ssl_request_code;
          Ok ())
  | Cancel_request { pid; key } ->
      framed None (fun b ->
          add_int32 b cancel_request_code;
          add_int32 b pid;
          Buffer.add_string b key;
          Ok ())
  | Password p -> framed (Some 'p') (fun b -> add_cstring b "a password" p)
  | Sasl_initial_response { mechanism; data } ->
      framed (Some 'p') (fun b ->
          let* () = add_cstring b "a SASL mechanism" mechanism in
          add_int32 b (String.length data);
          Buffer.add_string b data;
          Ok ())
  | Sasl_response data ->
      framed (Some 'p') (fun b ->
          Buffer.add_string b data;
          Ok ())
  | Query q -> framed (Some 'Q') (fun b -> add_cstring b "a query" q)
  | Parse { name; query } ->
      framed (Some 'P') (fun b ->
          let* () = add_cstring b "a statement's name" name in
          let* () = add_cstring b "a query" query in
          (* No parameter types: the server infers them. *)
          add_int16 b 0;
          Ok ())
  | Bind { portal; statement; params; results } ->
      framed (Some 'B') (fun b ->
          let* () = add_cstring b "a portal's name" portal in
          let* () = add_cstring b "a statement's name" statement in
          if List.length params > int16_max then
            Error
              (Printf.sprintf "%d parameters, where a Bind carries at most %d"
                 (List.length params) int16_max)
          else (
            (* Parameters in text; no result formats means all text. *)
            add_int16 b 0;
            add_int16 b (List.length params);
            List.iter
              (function
                | None -> add_int32 b (-1)
                | Some v ->
                    add_int32 b (String.length v);
                    Buffer.add_string b v)
              params;
            add_int16 b (List.length results);
            List.iter
              (fun f -> add_int16 b (match f with Text -> 0 | Binary -> 1))
              results;
            Ok ()))
  | Execute { portal; max_rows } ->
      framed (Some 'E') (fun b ->
          let* () = add_cstring b "a portal's name" portal in
          add_int32 b max_rows;
          Ok ())
  | Describe { target; name } -> framed (Some 'D') (targeted target name)
  | Close { target; name } -> framed (Some 'C') (targeted target name)
  | Sync -> framed (Some 'S') (fun _ -> Ok ())
  | Terminate -> framed (Some 'X') (fun _ -> Ok ())
  | Copy_data data ->
      framed (Some 'd') (fun b ->
          Buffer.add_string b data;
          Ok ())
  | Copy_done -> framed (Some 'c') (fun _ -> Ok ())
  | Copy_fail m -> framed (Some 'f') (fun b -> add_cstring b "a message" m)

(* Backend messages *)

type authentication =
  | Accepted
  | Kerberos_v5
  | Cleartext_password
  | Md5_password of string
  | Gss
  | Gss_continue of string
  | Sspi
  | Sasl of string list
  | Sasl_continue of string
  | Sasl_final of string

type field = {
  name : string;
  table : Oid.t;
  column : int;
  type_oid : Oid.t;
  type_size : int;
  type_modifier : int;
  format : format;
}

type copy = { format : format; columns : format list }

type backend =
  | Authentication of authentication
  | Backend_key_data of { pid : int; key : string }
  | Parameter_status of { name : string; value : string }
  | Ready_for_query of transaction_status
  | Row_description of field list
  | Data_row of string option array
  | Command_complete of string
  | Empty_query_response
  | Error_response of (char * string) list
  | Notice_response of (char * string) list
  | Notification_response of { pid : int; channel : string; payload : string }
  | Parse_complete
  | Bind_complete
  | Close_complete
  | No_data
  | Portal_suspended
  | Parameter_description of Oid.t list
  | Copy_in_response of copy
  | Copy_out_response of copy
  | Copy_both_response of copy
  | Copy_data of string
  | Copy_done
  | Function_call_response of string option
  | Negotiate_protocol_version of {
      newest_minor : int;
      unrecognised : string list;
    }

(* Every read is bounds-checked, and leftover bytes are refused like missing
   ones: either means the sides disagree on where the message ends. *)
type cursor = { body : string; mutable at : int; what : string }

exception Short of string

let refuse c detail =
  raise (Short (Printf.sprintf "54.7 Message Formats: %s %s" c.what detail))

let left c = String.length c.body - c.at
let need c n detail = if left c < n then refuse c detail

let int8 c =
  need c 1 "ends inside a byte";
  let v = Char.code c.body.[c.at] in
  c.at <- c.at + 1;
  v

let int16 c =
  need c 2 "ends inside an Int16";
  let v = String.get_uint16_be c.body c.at in
  c.at <- c.at + 2;
  v

(* Counts are unsigned Int16; attribute numbers, type sizes and format codes
   are signed (a varlena's size is -1). *)
let sint16 c =
  need c 2 "ends inside an Int16";
  let v = String.get_int16_be c.body c.at in
  c.at <- c.at + 2;
  v

let int32 c =
  need c 4 "ends inside an Int32";
  let v = Int32.to_int (String.get_int32_be c.body c.at) in
  c.at <- c.at + 4;
  v

(* An OID is unsigned: past 2^31 it would read as negative. *)
let oid c =
  let n = int32 c land 0xFFFF_FFFF in
  match Oid.of_int n with
  | Some oid -> oid
  | None -> refuse c (Printf.sprintf "has an OID %d past four bytes" n)

let format_of c =
  match sint16 c with
  | 0 -> Text
  | 1 -> Binary
  | n -> refuse c (Printf.sprintf "gives a column the format %d, not 0 or 1" n)

let bytes c n =
  need c n "ends inside a value";
  let v = String.sub c.body c.at n in
  c.at <- c.at + n;
  v

let rest c = bytes c (left c)

let cstring c =
  match String.index_from_opt c.body c.at '\000' with
  | None -> refuse c "has a String with no terminator"
  | Some j ->
      let v = String.sub c.body c.at (j - c.at) in
      c.at <- j + 1;
      v

(* AuthenticationSASL's mechanisms: Strings ended by an empty one. *)
let cstrings c =
  let rec go acc =
    match cstring c with "" -> List.rev acc | s -> go (s :: acc)
  in
  go []

let fields c =
  let rec go acc =
    match int8 c with
    | 0 -> List.rev acc
    | code -> go ((Char.chr code, cstring c) :: acc)
  in
  go []

let count c n what =
  if n < 0 then refuse c (Printf.sprintf "says %d %s" n what) else n

let copy c =
  let format =
    match int8 c with
    | 0 -> Text
    | 1 -> Binary
    | n -> refuse c (Printf.sprintf "has an overall format %d, not 0 or 1" n)
  in
  let n = int16 c in
  { format; columns = List.init n (fun _ -> format_of c) }

let authentication c =
  match int32 c with
  | 0 -> Accepted
  | 2 -> Kerberos_v5
  | 3 -> Cleartext_password
  | 5 -> Md5_password (bytes c 4)
  | 7 -> Gss
  | 8 -> Gss_continue (rest c)
  | 9 -> Sspi
  | 10 -> Sasl (cstrings c)
  | 11 -> Sasl_continue (rest c)
  | 12 -> Sasl_final (rest c)
  | n ->
      refuse c
        (Printf.sprintf "asks for authentication %d, which no section defines" n)

let message tag c =
  match tag with
  | 'R' -> Authentication (authentication c)
  | 'K' ->
      let pid = int32 c in
      (* 4 bytes in 3.0, 4 to 256 in 3.2. *)
      let n = left c in
      if n < 4 || n > 256 then
        refuse c (Printf.sprintf "has a key of %d bytes, not 4 to 256" n);
      Backend_key_data { pid; key = rest c }
  | 'S' ->
      let name = cstring c in
      Parameter_status { name; value = cstring c }
  | 'Z' ->
      Ready_for_query
        (match Char.chr (int8 c) with
        | 'I' -> Idle
        | 'T' -> In_transaction
        | 'E' -> Failed
        | s -> refuse c (Printf.sprintf "has a transaction status %C" s))
  | 'T' ->
      let n = int16 c in
      Row_description
        (List.init n (fun _ ->
             let name = cstring c in
             let table = oid c in
             let column = sint16 c in
             let type_oid = oid c in
             let type_size = sint16 c in
             let type_modifier = int32 c in
             let format = format_of c in
             { name; table; column; type_oid; type_size; type_modifier; format }))
  | 'D' ->
      let n = int16 c in
      Data_row
        (Array.init n (fun _ ->
             match int32 c with
             | -1 -> None
             | len when len < 0 ->
                 refuse c (Printf.sprintf "has a column of length %d" len)
             | len -> Some (bytes c len)))
  | 'C' -> Command_complete (cstring c)
  | 'I' -> Empty_query_response
  | 'E' -> Error_response (fields c)
  | 'N' -> Notice_response (fields c)
  | 'A' ->
      let pid = int32 c in
      let channel = cstring c in
      Notification_response { pid; channel; payload = cstring c }
  | '1' -> Parse_complete
  | '2' -> Bind_complete
  | '3' -> Close_complete
  | 'n' -> No_data
  | 's' -> Portal_suspended
  | 't' ->
      let n = int16 c in
      Parameter_description (List.init n (fun _ -> oid c))
  | 'G' -> Copy_in_response (copy c)
  | 'H' -> Copy_out_response (copy c)
  | 'W' -> Copy_both_response (copy c)
  | 'd' -> Copy_data (rest c)
  | 'c' -> Copy_done
  | 'V' -> (
      match int32 c with
      | -1 -> Function_call_response None
      | len when len < 0 ->
          refuse c (Printf.sprintf "has a result of length %d" len)
      | len -> Function_call_response (Some (bytes c len)))
  | 'v' ->
      let newest_minor = int32 c in
      let n = count c (int32 c) "unrecognised options" in
      Negotiate_protocol_version
        { newest_minor; unrecognised = List.init n (fun _ -> cstring c) }
  | t ->
      refuse c (Printf.sprintf "is of type %C, which no backend message has" t)

let name_of = function
  | 'R' -> "an Authentication message"
  | 'K' -> "a BackendKeyData"
  | 'S' -> "a ParameterStatus"
  | 'Z' -> "a ReadyForQuery"
  | 'T' -> "a RowDescription"
  | 'D' -> "a DataRow"
  | 'C' -> "a CommandComplete"
  | 'I' -> "an EmptyQueryResponse"
  | 'E' -> "an ErrorResponse"
  | 'N' -> "a NoticeResponse"
  | 'A' -> "a NotificationResponse"
  | '1' -> "a ParseComplete"
  | '2' -> "a BindComplete"
  | '3' -> "a CloseComplete"
  | 'n' -> "a NoData"
  | 's' -> "a PortalSuspended"
  | 't' -> "a ParameterDescription"
  | 'G' -> "a CopyInResponse"
  | 'H' -> "a CopyOutResponse"
  | 'W' -> "a CopyBothResponse"
  | 'd' -> "a CopyData"
  | 'c' -> "a CopyDone"
  | 'V' -> "a FunctionCallResponse"
  | 'v' -> "a NegotiateProtocolVersion"
  | _ -> "a message"

let decode tag body =
  let c = { body; at = 0; what = name_of tag } in
  match
    let m = message tag c in
    if left c > 0 then
      refuse c (Printf.sprintf "has %d bytes past its last field" (left c));
    m
  with
  | m -> Ok m
  | exception Short detail -> Error detail

(* The reader *)

(* Unread bytes are [data] from [start] to [stop]; space before [start] is
   reclaimed when more is needed. *)
type reader = {
  mutable data : Bytes.t;
  mutable start : int;
  mutable stop : int;
  limit : int;
}

let default_limit = 1 lsl 30

let reader ?(limit = default_limit) () =
  { data = Bytes.create 4096; start = 0; stop = 0; limit }

let feed r cs =
  let len = Cstruct.length cs in
  if len > 0 then begin
    let held = r.stop - r.start in
    if r.stop + len > Bytes.length r.data then begin
      let room = max (Bytes.length r.data) 1 in
      let rec size n = if n >= held + len then n else size (n * 2) in
      let target = size room in
      let data =
        if target > Bytes.length r.data then Bytes.create target else r.data
      in
      Bytes.blit r.data r.start data 0 held;
      r.data <- data;
      r.start <- 0;
      r.stop <- held
    end;
    Cstruct.blit_to_bytes cs 0 r.data r.stop len;
    r.stop <- r.stop + len
  end

let buffered r = r.stop - r.start

let next r =
  let held = r.stop - r.start in
  if held < 5 then Ok None
  else
    let tag = Bytes.get r.data r.start in
    let len = Int32.to_int (Bytes.get_int32_be r.data (r.start + 1)) in
    if len < 4 then
      Error
        (Printf.sprintf
           "54.7 Message Formats: %s says its length is %d, less than the four \
            bytes that say it"
           (name_of tag) len)
    else if len > r.limit then
      Error
        (Printf.sprintf
           "54.7 Message Formats: %s of %d bytes, past the %d this reader holds"
           (name_of tag) len r.limit)
    else if held < 1 + len then Ok None
    else
      let body = Bytes.sub_string r.data (r.start + 5) (len - 4) in
      r.start <- r.start + 1 + len;
      if r.start = r.stop then (
        r.start <- 0;
        r.stop <- 0);
      Result.map Option.some (decode tag body)
