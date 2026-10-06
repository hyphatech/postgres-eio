(* Each protocol requirement is a case named by its section of chapter 54
   of the Postgres 18 docs. Backend messages are read whole, a byte at a
   time, and at generated splits. *)

module P = Postgres_eio.Protocol
module Auth = Postgres_eio.Auth
module Conninfo = Postgres_eio.Conninfo

(* Messages, as hand-written bytes, so the reader is checked against the
   spec rather than against our own encoder. *)

let int16 n =
  let b = Bytes.create 2 in
  Bytes.set_uint16_be b 0 n;
  Bytes.to_string b

let int32 n =
  let b = Bytes.create 4 in
  Bytes.set_int32_be b 0 (Int32.of_int n);
  Bytes.to_string b

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec go i =
    i + n <= h && (String.equal (String.sub haystack i n) needle || go (i + 1))
  in
  go 0

let cstr s = s ^ "\000"
let msg tag body = String.make 1 tag ^ int32 (String.length body + 4) ^ body
let feed_string r s off len = P.feed r (Cstruct.of_string ~off ~len s)

let hex s =
  String.concat " "
    (List.init (String.length s) (fun i ->
         Printf.sprintf "%02x" (Char.code s.[i])))

let show_status = function
  | P.Idle -> "I"
  | P.In_transaction -> "T"
  | P.Failed -> "E"

let show_auth = function
  | P.Accepted -> "ok"
  | P.Kerberos_v5 -> "kerberos"
  | P.Cleartext_password -> "cleartext"
  | P.Md5_password s -> "md5 " ^ hex s
  | P.Gss -> "gss"
  | P.Gss_continue s -> "gss-continue " ^ s
  | P.Sspi -> "sspi"
  | P.Sasl ms -> "sasl " ^ String.concat "|" ms
  | P.Sasl_continue s -> "sasl-continue " ^ s
  | P.Sasl_final s -> "sasl-final " ^ s

let show_fields fs =
  String.concat ";" (List.map (fun (c, v) -> Printf.sprintf "%c=%s" c v) fs)

let show_cell = function None -> "NULL" | Some v -> Printf.sprintf "%S" v

(* Formats as their wire codes, so expectations read as the bytes do. *)
let format_code = function P.Text -> 0 | P.Binary -> 1

let show_copy (c : P.copy) =
  Printf.sprintf "%b [%s]"
    (format_code c.format = 1)
    (String.concat ","
       (List.map (fun f -> string_of_int (format_code f)) c.columns))

let show = function
  | P.Authentication a -> "auth " ^ show_auth a
  | P.Backend_key_data { pid; key } -> Printf.sprintf "key %d %s" pid (hex key)
  | P.Parameter_status { name; value } ->
      Printf.sprintf "param %s=%s" name value
  | P.Ready_for_query s -> "ready " ^ show_status s
  | P.Row_description fs ->
      "row-description "
      ^ String.concat ","
          (List.map
             (fun (f : P.field) ->
               Printf.sprintf "%s/%d/%d/%d/%d/%d/%d" f.name
                 (Postgres_eio.Oid.to_int f.table)
                 f.column
                 (Postgres_eio.Oid.to_int f.type_oid)
                 f.type_size f.type_modifier (format_code f.format))
             fs)
  | P.Data_row cells ->
      "row " ^ String.concat "," (Array.to_list (Array.map show_cell cells))
  | P.Command_complete t -> "complete " ^ t
  | P.Empty_query_response -> "empty"
  | P.Error_response fs -> "error " ^ show_fields fs
  | P.Notice_response fs -> "notice " ^ show_fields fs
  | P.Notification_response { pid; channel; payload } ->
      Printf.sprintf "notification %d %s %s" pid channel payload
  | P.Parse_complete -> "parse-complete"
  | P.Bind_complete -> "bind-complete"
  | P.Close_complete -> "close-complete"
  | P.No_data -> "no-data"
  | P.Portal_suspended -> "suspended"
  | P.Parameter_description oids ->
      "parameters "
      ^ String.concat ","
          (List.map (fun o -> string_of_int (Postgres_eio.Oid.to_int o)) oids)
  | P.Copy_in_response c -> "copy-in " ^ show_copy c
  | P.Copy_out_response c -> "copy-out " ^ show_copy c
  | P.Copy_both_response c -> "copy-both " ^ show_copy c
  | P.Copy_data d -> "copy-data " ^ d
  | P.Copy_done -> "copy-done"
  | P.Function_call_response r -> "function " ^ show_cell r
  | P.Negotiate_protocol_version { newest_minor; unrecognised } ->
      Printf.sprintf "negotiate %d %s" newest_minor
        (String.concat "," unrecognised)

(* Every backend message of 54.7, as bytes and as what it reads as. *)
let messages =
  [
    ("AuthenticationOk", msg 'R' (int32 0), "auth ok");
    ("AuthenticationKerberosV5", msg 'R' (int32 2), "auth kerberos");
    ("AuthenticationCleartextPassword", msg 'R' (int32 3), "auth cleartext");
    ( "AuthenticationMD5Password",
      msg 'R' (int32 5 ^ "\001\002\003\004"),
      "auth md5 01 02 03 04" );
    ("AuthenticationGSS", msg 'R' (int32 7), "auth gss");
    ( "AuthenticationGSSContinue",
      msg 'R' (int32 8 ^ "more"),
      "auth gss-continue more" );
    ("AuthenticationSSPI", msg 'R' (int32 9), "auth sspi");
    ( "AuthenticationSASL",
      msg 'R'
        (int32 10 ^ cstr "SCRAM-SHA-256-PLUS" ^ cstr "SCRAM-SHA-256" ^ "\000"),
      "auth sasl SCRAM-SHA-256-PLUS|SCRAM-SHA-256" );
    ( "AuthenticationSASLContinue",
      msg 'R' (int32 11 ^ "r=abc,s=c2FsdA==,i=4096"),
      "auth sasl-continue r=abc,s=c2FsdA==,i=4096" );
    ( "AuthenticationSASLFinal",
      msg 'R' (int32 12 ^ "v=c2ln"),
      "auth sasl-final v=c2ln" );
    ( "BackendKeyData",
      msg 'K' (int32 4242 ^ "\222\173\190\239"),
      "key 4242 de ad be ef" );
    ( "BackendKeyData, 3.2's longer key",
      msg 'K' (int32 7 ^ String.make 32 '\171'),
      "key 7 " ^ hex (String.make 32 '\171') );
    ( "ParameterStatus",
      msg 'S' (cstr "DateStyle" ^ cstr "ISO, MDY"),
      "param DateStyle=ISO, MDY" );
    ("ReadyForQuery idle", msg 'Z' "I", "ready I");
    ("ReadyForQuery in a transaction", msg 'Z' "T", "ready T");
    ("ReadyForQuery failed", msg 'Z' "E", "ready E");
    ( "RowDescription",
      msg 'T'
        (int16 2 ^ cstr "id" ^ int32 16384 ^ int16 1 ^ int32 23 ^ int16 4
       ^ int32 (-1) ^ int16 0 ^ cstr "note" ^ int32 0 ^ int16 0 ^ int32 25
       ^ int16 0xffff ^ int32 (-1) ^ int16 0),
      "row-description id/16384/1/23/4/-1/0,note/0/0/25/-1/-1/0" );
    ( "RowDescription, OIDs past 2^31 read unsigned",
      msg 'T'
        (int16 1 ^ cstr "big" ^ int32 (-16) ^ int16 1 ^ int32 (-1) ^ int16 4
       ^ int32 (-1) ^ int16 1),
      "row-description big/4294967280/1/4294967295/4/-1/1" );
    ( "DataRow",
      msg 'D' (int16 3 ^ int32 2 ^ "42" ^ int32 (-1) ^ int32 0),
      "row \"42\",NULL,\"\"" );
    ("DataRow with no columns", msg 'D' (int16 0), "row ");
    ("CommandComplete", msg 'C' (cstr "UPDATE 3"), "complete UPDATE 3");
    ("EmptyQueryResponse", msg 'I' "", "empty");
    ( "ErrorResponse",
      msg 'E'
        ("S" ^ cstr "ERROR" ^ "C" ^ cstr "23505" ^ "M" ^ cstr "duplicate key"
       ^ "\000"),
      "error S=ERROR;C=23505;M=duplicate key" );
    ( "NoticeResponse",
      msg 'N' ("S" ^ cstr "NOTICE" ^ "M" ^ cstr "relation exists" ^ "\000"),
      "notice S=NOTICE;M=relation exists" );
    ( "NotificationResponse",
      msg 'A' (int32 7 ^ cstr "moves" ^ cstr "game 1"),
      "notification 7 moves game 1" );
    ("ParseComplete", msg '1' "", "parse-complete");
    ("BindComplete", msg '2' "", "bind-complete");
    ("CloseComplete", msg '3' "", "close-complete");
    ("NoData", msg 'n' "", "no-data");
    ("PortalSuspended", msg 's' "", "suspended");
    ( "ParameterDescription",
      msg 't' (int16 2 ^ int32 23 ^ int32 25),
      "parameters 23,25" );
    ( "CopyInResponse",
      msg 'G' ("\000" ^ int16 2 ^ int16 0 ^ int16 0),
      "copy-in false [0,0]" );
    ( "CopyOutResponse",
      msg 'H' ("\001" ^ int16 1 ^ int16 1),
      "copy-out true [1]" );
    ("CopyBothResponse", msg 'W' ("\000" ^ int16 0), "copy-both false []");
    ("CopyData", msg 'd' "1\tgo\n", "copy-data 1\tgo\n");
    ("CopyDone", msg 'c' "", "copy-done");
    ("FunctionCallResponse", msg 'V' (int32 2 ^ "ok"), "function \"ok\"");
    ("FunctionCallResponse NULL", msg 'V' (int32 (-1)), "function NULL");
    ( "NegotiateProtocolVersion",
      msg 'v' (int32 0 ^ int32 1 ^ cstr "_pq_.unknown"),
      "negotiate 0 _pq_.unknown" );
  ]

let read_all r =
  let rec go acc =
    match P.next r with
    | Ok (Some m) -> go (show m :: acc)
    | Ok None -> Ok (List.rev acc)
    | Error e -> Error e
  in
  go []

let whole bytes expected () =
  let r = P.reader () in
  feed_string r bytes 0 (String.length bytes);
  Alcotest.(check (result (list string) string))
    "whole" (Ok [ expected ]) (read_all r);
  Alcotest.(check int) "nothing held after it" 0 (P.buffered r)

let a_byte_at_a_time bytes expected () =
  let r = P.reader () in
  let seen = ref [] in
  String.iteri
    (fun i _ ->
      feed_string r bytes i 1;
      match read_all r with
      | Ok [] -> ()
      | Ok ms ->
          if i < String.length bytes - 1 then
            Alcotest.failf "a message after %d of %d bytes" (i + 1)
              (String.length bytes);
          seen := !seen @ ms
      | Error e -> Alcotest.failf "refused at byte %d: %s" i e)
    bytes;
  Alcotest.(check (list string)) "a byte at a time" [ expected ] !seen

let row_cases =
  List.concat_map
    (fun (name, bytes, expected) ->
      [
        Alcotest.test_case
          (Printf.sprintf "54.7 %s, whole" name)
          `Quick (whole bytes expected);
        Alcotest.test_case
          (Printf.sprintf "54.7 %s, a byte at a time" name)
          `Quick
          (a_byte_at_a_time bytes expected);
      ])
    messages

(* All messages in sequence, split at generated points, read back in order. *)
let at_any_split =
  let all = String.concat "" (List.map (fun (_, b, _) -> b) messages) in
  let expected = List.map (fun (_, _, e) -> e) messages in
  QCheck2.Test.make ~count:500
    ~name:"54.7 every message, at splits a generator chooses"
    QCheck2.Gen.(list_size (int_range 0 40) (int_range 0 (String.length all)))
    (fun cuts ->
      let cuts = List.sort_uniq Int.compare (0 :: String.length all :: cuts) in
      let r = P.reader () in
      let rec feed acc = function
        | a :: (b :: _ as rest) -> (
            feed_string r all a (b - a);
            match read_all r with
            | Ok ms -> feed (acc @ ms) rest
            | Error e -> QCheck2.Test.fail_reportf "refused: %s" e)
        | [ _ ] | [] -> acc
      in
      List.equal String.equal (feed [] cuts) expected)

let refused name bytes needle =
  Alcotest.test_case name `Quick (fun () ->
      let r = P.reader () in
      feed_string r bytes 0 (String.length bytes);
      match read_all r with
      | Error e ->
          Alcotest.(check bool)
            (Printf.sprintf "%S names %S" e needle)
            true
            (contains e needle && contains e "54.7")
      | Ok ms -> Alcotest.failf "read %s" (String.concat "; " ms))

let refusals =
  [
    refused "54.7 a length shorter than the length field"
      ("Z" ^ int32 3)
      "less than the four bytes";
    refused "54.7 a String with no terminator" (msg 'C' "UPDATE 3")
      "no terminator";
    refused "54.7 bytes past the last field" (msg 'Z' "II")
      "past its last field";
    refused "54.7 a message ending inside a field" (msg 'K' "ab") "ends inside";
    refused "54.7 a BackendKeyData key shorter than 3.0's"
      (msg 'K' (int32 1 ^ "ab"))
      "not 4 to 256";
    refused "54.7 a BackendKeyData key longer than 3.2's"
      (msg 'K' (int32 1 ^ String.make 257 'k'))
      "not 4 to 256";
    refused "54.7 a type no backend message has" (msg 'x' "")
      "which no backend message has";
    refused "54.7 an authentication no section defines"
      (msg 'R' (int32 6))
      "no section defines";
    refused "54.7 a transaction status that is not I, T or E" (msg 'Z' "X")
      "transaction status";
    refused "54.7 a column's format that is not 0 or 1"
      (msg 'T'
         (int16 1 ^ cstr "c" ^ int32 0 ^ int16 0 ^ int32 23 ^ int16 4
        ^ int32 (-1) ^ int16 2))
      "the format 2";
    refused "54.7 a COPY column's format that is not 0 or 1"
      (msg 'G' ("\000" ^ int16 1 ^ int16 2))
      "the format 2";
    refused "54.7 a column whose length is negative, not -1"
      (msg 'D' (int16 1 ^ int32 (-2)))
      "length -2";
    refused "54.7 a DataRow whose columns run past it"
      (msg 'D' (int16 2 ^ int32 1 ^ "a"))
      "ends inside";
    refused "54.7 an ErrorResponse with no terminating zero"
      ("E" ^ int32 (4 + 7) ^ "S" ^ cstr "ERROR")
      "ends inside";
  ]

let a_message_past_the_limit () =
  let r = P.reader ~limit:16 () in
  let bytes = msg 'd' (String.make 32 'x') in
  feed_string r bytes 0 5;
  match P.next r with
  | Error e -> Alcotest.(check bool) e true (contains e "past the 16")
  | Ok _ -> Alcotest.fail "held a message past the limit"

(* The frontend's bytes, checked against the section's layout. *)
let encodes name message expected =
  Alcotest.test_case name `Quick (fun () ->
      Alcotest.(check (result string string))
        name
        (Ok (hex expected))
        (Result.map hex (P.encode message)))

let encodings =
  [
    encodes
      "54.7 StartupMessage asks for 3.0 and ends its parameters with a zero"
      (P.Startup
         { minor = 0; parameters = [ ("user", "app"); ("database", "go") ] })
      (int32 (4 + 4 + 22)
      ^ int32 196608 ^ cstr "user" ^ cstr "app" ^ cstr "database" ^ cstr "go"
      ^ "\000");
    encodes "54.7 StartupMessage asks for 3.2"
      (P.Startup { minor = 2; parameters = [ ("user", "app") ] })
      (int32 (4 + 4 + 10) ^ int32 196610 ^ cstr "user" ^ cstr "app" ^ "\000");
    encodes "54.7 SSLRequest" P.Ssl_request (int32 8 ^ int32 80877103);
    encodes "54.7 CancelRequest carries the pid and the key"
      (P.Cancel_request { pid = 4242; key = "\222\173\190\239" })
      (int32 16 ^ int32 80877102 ^ int32 4242 ^ "\222\173\190\239");
    encodes "54.7 PasswordMessage" (P.Password "md5abc")
      (msg 'p' (cstr "md5abc"));
    encodes "54.7 SASLInitialResponse counts its data"
      (P.Sasl_initial_response
         { mechanism = "SCRAM-SHA-256"; data = "n,,n=,r=x" })
      (msg 'p' (cstr "SCRAM-SHA-256" ^ int32 9 ^ "n,,n=,r=x"));
    encodes "54.7 SASLResponse" (P.Sasl_response "c=biws") (msg 'p' "c=biws");
    encodes "54.7 Query" (P.Query "select 1") (msg 'Q' (cstr "select 1"));
    encodes "54.7 Parse names no parameter types"
      (P.Parse { name = ""; query = "select $1" })
      (msg 'P' (cstr "" ^ cstr "select $1" ^ int16 0));
    encodes "54.7 Bind sends text, NULL as -1"
      (P.Bind
         {
           portal = "";
           statement = "";
           params = [ Some "7"; None; Some "" ];
           results = [];
         })
      (msg 'B'
         (cstr "" ^ cstr "" ^ int16 0 ^ int16 3 ^ int32 1 ^ "7" ^ int32 (-1)
        ^ int32 0 ^ int16 0));
    encodes "54.7 Bind names each result column's format"
      (P.Bind
         {
           portal = "";
           statement = "s";
           params = [];
           results = [ P.Binary; P.Text; P.Binary ];
         })
      (msg 'B'
         (cstr "" ^ cstr "s" ^ int16 0 ^ int16 0 ^ int16 3 ^ int16 1 ^ int16 0
        ^ int16 1));
    encodes "54.7 Execute"
      (P.Execute { portal = ""; max_rows = 0 })
      (msg 'E' (cstr "" ^ int32 0));
    encodes "54.7 Describe a statement"
      (P.Describe { target = P.Statement; name = "s" })
      (msg 'D' ("S" ^ cstr "s"));
    encodes "54.7 Describe a portal"
      (P.Describe { target = P.Portal; name = "" })
      (msg 'D' ("P" ^ cstr ""));
    encodes "54.7 Close a statement"
      (P.Close { target = P.Statement; name = "s" })
      (msg 'C' ("S" ^ cstr "s"));
    encodes "54.7 Sync" P.Sync (msg 'S' "");
    encodes "54.7 Terminate" P.Terminate (msg 'X' "");
    encodes "54.7 CopyData carries its bytes as they are"
      (P.Copy_data "1\tgo\n\000") (msg 'd' "1\tgo\n\000");
    encodes "54.7 CopyDone" P.Copy_done (msg 'c' "");
    encodes "54.7 CopyFail" (P.Copy_fail "no") (msg 'f' (cstr "no"));
  ]

let a_nul_cannot_be_sent () =
  List.iter
    (fun (what, m) ->
      match P.encode m with
      | Error e -> Alcotest.(check bool) e true (contains e "NUL")
      | Ok _ -> Alcotest.failf "%s with a NUL was sent" what)
    [
      ("a query", P.Query "select 1\000; drop table x");
      ("a statement", P.Parse { name = ""; query = "select\000" });
      ( "a startup value",
        P.Startup { minor = 0; parameters = [ ("user", "a\000b") ] } );
      ("a password", P.Password "pa\000ss");
    ];
  (* A parameter is counted, not terminated, so a NUL in one is its own. *)
  match
    P.encode
      (P.Bind
         {
           portal = "";
           statement = "";
           params = [ Some "a\000b" ];
           results = [];
         })
  with
  | Ok _ -> ()
  | Error e -> Alcotest.failf "a counted value was refused: %s" e

let too_many_parameters () =
  match
    P.encode
      (P.Bind
         {
           portal = "";
           statement = "";
           params = List.init 65536 (fun _ -> None);
           results = [];
         })
  with
  | Error e -> Alcotest.(check bool) e true (contains e "65535")
  | Ok _ -> Alcotest.fail "a Bind that cannot count its parameters was sent"

(* Sign-in *)

(* RFC 7677 §3's example, which sends a user name where Postgres sends none. *)
let scram_rfc_7677 () =
  let scram, first =
    Auth.client_first ~user:"user" ~password:"pencil"
      ~nonce:"rOprNGfwEbeRWgbNEkqO" ()
  in
  Alcotest.(check string)
    "client-first" "n,,n=user,r=rOprNGfwEbeRWgbNEkqO" first;
  let server_first =
    "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
  in
  match Auth.client_final scram server_first with
  | Error e -> Alcotest.fail e
  | Ok (proven, final) ->
      Alcotest.(check string)
        "client-final"
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
        final;
      Alcotest.(check (result unit string))
        "the server's proof" (Ok ())
        (Auth.verify proven "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=");
      Alcotest.(check bool)
        "a proof that is not the password's" true
        (Result.is_error
           (Auth.verify proven "v=AAAATRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="));
      Alcotest.(check bool)
        "a refusal" true
        (Result.is_error (Auth.verify proven "e=invalid-proof"))

let scram_names_nobody_by_default () =
  let _, first = Auth.client_first ~password:"p" ~nonce:"abc" () in
  Alcotest.(check string)
    "54.3.1: the startup message's name is used" "n,,n=,r=abc" first;
  let _, first =
    Auth.client_first ~user:"a=b,c" ~password:"p" ~nonce:"abc" ()
  in
  Alcotest.(check string)
    "a saslname escapes = and ," "n,,n=a=3Db=2Cc,r=abc" first

let scram_refuses_a_server_it_cannot_trust () =
  let refused server_first =
    let scram, _ = Auth.client_first ~password:"p" ~nonce:"abc" () in
    Result.is_error (Auth.client_final scram server_first)
  in
  Alcotest.(check bool)
    "a nonce that does not continue ours" true
    (refused "r=xyzdef,s=c2FsdA==,i=4096");
  Alcotest.(check bool)
    "a nonce that only repeats ours" true
    (refused "r=abc,s=c2FsdA==,i=4096");
  Alcotest.(check bool)
    "a salt that is not base64" true
    (refused "r=abcdef,s=!!!,i=4096");
  Alcotest.(check bool) "no iterations" true (refused "r=abcdef,s=c2FsdA==,i=0");
  Alcotest.(check bool)
    "a mandatory extension" true
    (refused "m=ext,r=abcdef,s=c2FsdA==,i=4096");
  Alcotest.(check bool)
    "attributes out of order" true
    (refused "s=c2FsdA==,r=abcdef,i=4096")

let md5 () =
  Alcotest.(check string)
    "54.3: md5 of the md5 of the password and the user, and the salt"
    "md598a0412b9c31436fc53776e863350083"
    (Auth.md5 ~user:"alice" ~password:"secret" ~salt:"\001\002\003\004")

(* Connection strings *)

(* Every field; multi-host and sign-in fields only when not default. *)
let show_conninfo (t : Conninfo.t) =
  let endpoint (e : Conninfo.endpoint) =
    Printf.sprintf "%s%s port=%d%s"
      (match e.host with Tcp h -> "tcp " ^ h | Unix_socket d -> "unix " ^ d)
      (Option.fold ~none:""
         ~some:(fun a -> " at " ^ Ipaddr.to_string a)
         e.address)
      e.port
      (match e.password with Some p -> " pgpass=" ^ p | None -> "")
  in
  let extra =
    List.filter_map Fun.id
      [
        Option.map (( ^ ) "cert=") t.ssl_cert;
        Option.map (( ^ ) "key=") t.ssl_key;
        (match t.ssl_negotiation with
        | Postgres -> None
        | Direct -> Some "direct");
        (match t.channel_binding with
        | Binding_preferred -> None
        | Binding_disabled -> Some "binding=disable"
        | Binding_required -> Some "binding=require");
        (let m = t.require_auth in
         if m.password && m.md5 && m.scram_sha_256 && m.none then None
         else
           Some
             (Printf.sprintf "auth=%s%s%s%s"
                (if m.password then "p" else "")
                (if m.md5 then "m" else "")
                (if m.scram_sha_256 then "s" else "")
                (if m.none then "n" else "")));
        (if t.keepalives then None else Some "keepalives=0");
        (match t.target_session_attrs with
        | Any -> None
        | Read_write -> Some "attrs=read-write"
        | Read_only -> Some "attrs=read-only"
        | Primary -> Some "attrs=primary"
        | Standby -> Some "attrs=standby"
        | Prefer_standby -> Some "attrs=prefer-standby");
        (match t.load_balance_hosts with
        | In_order -> None
        | Random -> Some "random");
        (match t.min_protocol_version with
        | V3_0 -> None
        | V3_2 -> Some "min=3.2");
        (match t.max_protocol_version with
        | V3_0 -> None
        | V3_2 -> Some "max=3.2");
        (match t.options with
        | [] -> None
        | o ->
            Some
              ("options="
              ^ String.concat "," (List.map (fun (k, v) -> k ^ ":" ^ v) o)));
      ]
  in
  Printf.sprintf
    "%s user=%s password=%s dbname=%s sslmode=%s root=%s timeout=%s app=%s%s"
    (String.concat "," (List.map endpoint t.hosts))
    t.user
    (Option.value t.password ~default:"-")
    t.database
    (Conninfo.ssl_mode_to_string t.ssl_mode)
    (Option.value t.ssl_root_cert ~default:"-")
    (Option.fold ~none:"-" ~some:string_of_float t.connect_timeout_s)
    (Option.value t.application_name ~default:"-")
    (String.concat "" (List.map (( ^ ) " ") extra))

let reads name s expected =
  Alcotest.test_case name `Quick (fun () ->
      Alcotest.(check (result string string))
        s (Ok expected)
        (Result.map show_conninfo (Conninfo.of_string s)))

let refuses name s needle =
  Alcotest.test_case name `Quick (fun () ->
      match Conninfo.of_string s with
      | Error e -> Alcotest.(check bool) e true (contains e needle)
      | Ok t -> Alcotest.failf "read %s" (show_conninfo t))

let conninfo_cases =
  [
    reads "a URL, every part"
      "postgres://app:p%40ss%20word@db.example:6543/go?sslmode=verify-full&sslrootcert=/ca.pem&connect_timeout=3&application_name=demo"
      "tcp db.example port=6543 user=app password=p@ss word dbname=go \
       sslmode=verify-full root=/ca.pem timeout=3. app=demo";
    reads "postgresql:// too, and its defaults" "postgresql://app@db"
      "tcp db port=5432 user=app password=- dbname=app sslmode=prefer root=- \
       timeout=- app=-";
    reads "an IPv6 host" "postgres://app@[::1]:5433/go"
      "tcp ::1 port=5433 user=app password=- dbname=go sslmode=prefer root=- \
       timeout=- app=-";
    reads "a socket's directory, percent-encoded"
      "postgres://app@%2Fvar%2Frun%2Fpostgresql/go"
      "unix /var/run/postgresql port=5432 user=app password=- dbname=go \
       sslmode=prefer root=- timeout=- app=-";
    reads "a socket's directory, as a query" "postgres:///go?host=/tmp&user=app"
      "unix /tmp port=5432 user=app password=- dbname=go sslmode=prefer root=- \
       timeout=- app=-";
    reads "an empty value is the key unset" "postgres://app@db/go?sslmode="
      "tcp db port=5432 user=app password=- dbname=go sslmode=prefer root=- \
       timeout=- app=-";
    reads "keywords" "host=db port=6543 user=app dbname=go sslmode=require"
      "tcp db port=6543 user=app password=- dbname=go sslmode=require root=- \
       timeout=- app=-";
    reads "a quoted value holds a space" "user=app password='a b' host=db"
      "tcp db port=5432 user=app password=a b dbname=app sslmode=prefer root=- \
       timeout=- app=-";
    reads "a backslash takes the next character"
      {|user=app password='it\'s' application_name=a\ b|}
      "tcp localhost port=5432 user=app password=it's dbname=app \
       sslmode=prefer root=- timeout=- app=a b";
    reads "spaces around =" "  user = app   dbname= go "
      "tcp localhost port=5432 user=app password=- dbname=go sslmode=prefer \
       root=- timeout=- app=-";
    refuses "a key nobody reads, in a URL" "postgres://app@db/go?sslcrl=/crl"
      "sslcrl";
    refuses "a key nobody reads, in keywords" "user=app keepalives_idle=5"
      "keepalives_idle";
    refuses "sslpassword, with its reason" "user=app sslpassword=x"
      "no encrypted client key";
    reads "several hosts, a port each" "host=a,b port=1,2 user=app"
      "tcp a port=1,tcp b port=2 user=app password=- dbname=app sslmode=prefer \
       root=- timeout=- app=-";
    reads "several hosts, one port for all" "host=a,/run/pg port=7 user=app"
      "tcp a port=7,unix /run/pg port=7 user=app password=- dbname=app \
       sslmode=prefer root=- timeout=- app=-";
    reads "several hosts in a URL, one with no port"
      "postgres://app@a:1,[::1]:2,c/go"
      "tcp a port=1,tcp ::1 port=2,tcp c port=5432 user=app password=- \
       dbname=go sslmode=prefer root=- timeout=- app=-";
    refuses "ports for some hosts and not the rest"
      "host=a,b,c port=1,2 user=app" "2 ports for 3 hosts";
    reads "hostaddr: the host's name, connected to at an address"
      "host=pg_test hostaddr=127.0.0.1 user=app"
      "tcp pg_test at 127.0.0.1 port=5432 user=app password=- dbname=app \
       sslmode=prefer root=- timeout=- app=-";
    reads "hostaddr alone is the host" "hostaddr=::1 user=app"
      "tcp ::1 at ::1 port=5432 user=app password=- dbname=app sslmode=prefer \
       root=- timeout=- app=-";
    reads "hostaddr, one each, an empty one looked up"
      "postgres://app@a,b/go?hostaddr=10.0.0.5,"
      "tcp a at 10.0.0.5 port=5432,tcp b port=5432 user=app password=- \
       dbname=go sslmode=prefer root=- timeout=- app=-";
    refuses "hostaddr that is a name" "host=db hostaddr=db.internal user=app"
      "not an address";
    refuses "hostaddr for some hosts and not the rest"
      "host=a,b hostaddr=10.0.0.5 user=app" "1 addresses for 2 hosts";
    refuses "hostaddr for a socket's directory"
      "host=/run/pg hostaddr=127.0.0.1 user=app" "socket's directory";
    reads "every key of sign-in and connecting"
      "user=app sslmode=verify-full sslcert=/c.pem sslkey=/k.pem \
       sslnegotiation=direct channel_binding=require \
       require_auth=scram-sha-256 keepalives=0 target_session_attrs=read-write \
       load_balance_hosts=random min_protocol_version=3.2 \
       max_protocol_version=latest options='-c search_path=x --work-mem=4MB -c \
       a=b\\\\ c -cgeqo=off'"
      "tcp localhost port=5432 user=app password=- dbname=app \
       sslmode=verify-full root=- timeout=- app=- cert=/c.pem key=/k.pem \
       direct binding=require auth=s keepalives=0 attrs=read-write random \
       min=3.2 max=3.2 options=search_path:x,work_mem:4MB,a:b c,geqo:off";
    reads "require_auth negated" "user=app require_auth=!md5,!password"
      "tcp localhost port=5432 user=app password=- dbname=app sslmode=prefer \
       root=- timeout=- app=- auth=sn";
    refuses "require_auth mixing methods and negations"
      "user=app require_auth=md5,!password" "mixes";
    refuses "require_auth naming what is not a method"
      "user=app require_auth=kerberos" "kerberos";
    refuses "direct TLS under prefer" "user=app sslnegotiation=direct"
      "needs sslmode=require";
    refuses "a required binding with TLS never used"
      "user=app sslmode=disable channel_binding=require" "needs TLS";
    refuses "a minimum above the maximum"
      "user=app min_protocol_version=3.2 max_protocol_version=3.0" "above";
    refuses "options that are not settings" "user=app options=-X" "-X";
    Alcotest.test_case "the environment, when asked" `Quick (fun () ->
        let table =
          [
            ("PGHOST", "a,b");
            ("PGHOSTADDR", "10.0.0.5,");
            ("PGPORT", "7");
            ("PGUSER", "env");
            ("PGDATABASE", "");
            ("PGSSLMODE", "require");
            ("HOME", "/home/somebody");
          ]
        in
        let defaults = Conninfo.environment (fun v -> List.assoc_opt v table) in
        Alcotest.(check (list (pair string string)))
          "each variable for a key, an empty one unset"
          [
            ("host", "a,b");
            ("hostaddr", "10.0.0.5,");
            ("port", "7");
            ("user", "env");
            ("sslmode", "require");
          ]
          defaults;
        Alcotest.(check (result string string))
          "filling what the string leaves out"
          (Ok
             "tcp a at 10.0.0.5 port=7,tcp b port=7 user=app password=- \
              dbname=app sslmode=require root=- timeout=- app=-")
          (Result.map show_conninfo (Conninfo.of_string ~defaults "user=app")));
    Alcotest.test_case "a .pgpass, as libpq reads one" `Quick (fun () ->
        let file =
          "# a comment\n\
           db:5432:go:app:first\n\
           *:5433:*:app:any\\:host\n\
           db:5432:go:app:second\n\
           h\\:x:*:*:*:colon: in it\n"
        in
        let read s =
          match Conninfo.of_string s with
          | Ok c -> show_conninfo (Conninfo.passfile file c)
          | Error e -> Alcotest.fail e
        in
        Alcotest.(check string)
          "the first line that matches"
          "tcp db port=5432 pgpass=first user=app password=- dbname=go \
           sslmode=prefer root=- timeout=- app=-"
          (read "host=db user=app dbname=go");
        Alcotest.(check string)
          "a password for each host, * for any"
          "tcp db port=5432 pgpass=first,tcp other port=5433 pgpass=any:host \
           user=app password=- dbname=go sslmode=prefer root=- timeout=- app=-"
          (read "host=db,other port=5432,5433 user=app dbname=go");
        Alcotest.(check string)
          "an escaped colon, and one in the password"
          "tcp h:x port=5432 pgpass=colon: in it user=u password=- dbname=d \
           sslmode=prefer root=- timeout=- app=-"
          (read {|host='h:x' user=u dbname=d|});
        Alcotest.(check string)
          "the string's own password wins"
          "tcp db port=5432 user=app password=given dbname=go sslmode=prefer \
           root=- timeout=- app=-"
          (read "host=db user=app dbname=go password=given"));
    refuses "no user" "postgres://db/go" "no user";
    refuses "a port that is not one" "postgres://app@db:99999/go" "not a port";
    refuses "a port in hex" "user=app port=0x1538" "not a port";
    refuses "a connect_timeout in hex" "user=app connect_timeout=0x10"
      "not a number of seconds";
    refuses "an sslmode that is none of them" "user=app sslmode=maybe" "sslmode";
    refuses "an unterminated quote" "user=app password='open" "closing quote";
    refuses "a key with no =" "user=app dbname" "no =";
    refuses "a bad percent escape" "postgres://app@db/g%zz" "not hex";
    (* No secret reaches a driver error: the part is named, never quoted. *)
    Alcotest.test_case "a bad escape in a password is not quoted" `Quick
      (fun () ->
        List.iter
          (fun s ->
            match Conninfo.of_string s with
            | Error e ->
                Alcotest.(check bool)
                  ("names the password: " ^ e)
                  true (contains e "password");
                Alcotest.(check bool)
                  ("quotes no secret: " ^ e) false (contains e "s3cr3t")
            | Ok _ -> Alcotest.failf "read %s" s)
          [
            "postgres://app:s3cr3t%zz@db/go";
            "postgres://app:s3cr3t%4@db/go";
            "postgres://app@db/go?password=s3cr3t%g1";
          ]);
    (* A password holding an unescaped URL delimiter splits the URL there,
       and the error must not quote the piece after it. *)
    Alcotest.test_case "a delimiter in a password is not quoted" `Quick
      (fun () ->
        List.iter
          (fun s ->
            match Conninfo.of_string s with
            | Error e ->
                Alcotest.(check bool)
                  ("quotes no secret: " ^ e) false
                  (contains e "ab12" || contains e "cd34")
            | Ok _ -> ())
          [
            "postgres://app:ab12?cd34@db/go";
            "postgres://app:ab12/cd34@db/go";
            "postgres://app:ab12/cd34@db/go?user=app";
            "postgres://app:ab12#cd34@db/go";
            "postgres://app:ab12&cd34@db/go";
          ]);
    refuses "another scheme" "mysql://app@db/go" "postgres://";
  ]

(* Printed URLs round-trip for arbitrary user, password and database. *)
let a_url_reads_back =
  let text = QCheck2.Gen.(string_size ~gen:printable (int_range 1 12)) in
  let host =
    QCheck2.Gen.(
      map
        (fun ((h, address), port) ->
          let socket = String.starts_with ~prefix:"/" h in
          {
            Conninfo.host = (if socket then Unix_socket h else Tcp h);
            address = (if socket then None else address);
            port;
            password = None;
          })
        (pair
           (pair
              (oneof_list [ "db"; "::1"; "/run/pg" ])
              (oneof_list
                 [
                   None;
                   Some Ipaddr.(V4 (V4.of_string_exn "10.0.0.5"));
                   Some Ipaddr.(V6 V6.localhost);
                 ]))
           (int_range 1 65535)))
  in
  QCheck2.Test.make ~count:300 ~name:"a printed URL reads back as itself"
    QCheck2.Gen.(
      tup4 text (option text) text
        (pair (list_size (int_range 1 3) host) (list_small (pair text text))))
    (fun (user, password, database, (hosts, options)) ->
      let t =
        {
          Conninfo.hosts;
          user;
          password;
          database;
          ssl_mode = Verify_ca;
          ssl_root_cert = Some "/ca.pem";
          ssl_cert = Some "/c.pem";
          ssl_key = Some "/k.pem";
          ssl_negotiation = Direct;
          channel_binding = Binding_required;
          require_auth =
            { password = false; md5 = true; scram_sha_256 = true; none = false };
          connect_timeout_s = Some 4.;
          application_name = Some "demo app";
          keepalives = false;
          target_session_attrs = Prefer_standby;
          load_balance_hosts = Random;
          min_protocol_version = V3_0;
          max_protocol_version = V3_2;
          options =
            List.map
              (fun (k, v) ->
                (String.map (function '=' | '-' -> '_' | c -> c) k, v))
              options;
        }
      in
      match Conninfo.of_string (Conninfo.to_url t) with
      | Ok back -> String.equal (show_conninfo back) (show_conninfo t)
      | Error e -> QCheck2.Test.fail_reportf "%s: %s" (Conninfo.to_url t) e)

(* Text forms *)

module Text = Postgres_eio.Text

(* The cases write an instant as microseconds since the epoch, computed
   independently of the driver; these move one between that figure and
   Ptime, through whole seconds and their fraction. *)
let us_of t =
  match Ptime.Span.to_int_s (Ptime.to_span (Ptime.truncate ~frac_s:0 t)) with
  | None -> Alcotest.fail "an instant past an int of seconds"
  | Some s ->
      let _, ps = Ptime.Span.to_d_ps (Ptime.frac_s t) in
      (s * 1_000_000) + Int64.to_int (Int64.div ps 1_000_000L)

let instant_of_us us =
  let s = if us >= 0 then us / 1_000_000 else ((us + 1) / 1_000_000) - 1 in
  let frac = Int64.mul (Int64.of_int (us - (s * 1_000_000))) 1_000_000L in
  match
    Option.bind
      (Ptime.Span.of_d_ps (0, frac))
      (fun f -> Ptime.of_span (Ptime.Span.add (Ptime.Span.of_int_s s) f))
  with
  | Some t -> t
  | None -> Alcotest.failf "%d microseconds is no instant" us

(* Postgres's timestamptz output and the instant, computed independently. *)
let ten = 1_790_503_200_000_000 (* 2026-09-27 10:00:00 UTC *)

let instants =
  [
    ("in UTC", "2026-09-27 10:00:00+00", Some ten);
    ("a half-hour zone", "2026-09-27 15:30:00+05:30", Some ten);
    ("west of UTC", "2026-09-27 06:00:00-04", Some ten);
    ( "an offset in seconds",
      "1900-01-01 00:19:32+00:19:32",
      Some (-2_208_988_800_000_000) );
    ("a fraction", "2026-09-27 10:00:00.25+00", Some (ten + 250_000));
    ("a microsecond", "2026-09-27 10:00:00.000001+00", Some (ten + 1));
    ("before the epoch", "1969-12-31 23:59:59.5+00", Some (-500_000));
    ("a BC date", "0044-03-15 12:00:00+00 BC", None);
    ("a year past 9999", "10000-01-01 00:00:00+00", None);
    ("infinity", "infinity", None);
    ("as the driver writes it", "2026-09-27T10:00:00.000000Z", Some ten);
    ("a Z with more after it", "2026-09-27T10:00:00Z+01", None);
    ("not a date", "2026-02-30 10:00:00+00", None);
    ("not a time", "2026-09-27 24:00:00+00", None);
  ]

let reads_an_instant (name, text, expected) =
  Alcotest.test_case ("a timestamptz " ^ name) `Quick (fun () ->
      Alcotest.(check (option int))
        text expected
        (Option.map us_of (Text.to_timestamptz text)))

(* A date is read as the calendar says, and one the calendar has not is
   refused. *)
let dates =
  [
    ("2026-09-27", Some (2026, 9, 27));
    ("0001-01-01", Some (1, 1, 1));
    ("9999-12-31", Some (9999, 12, 31));
    ("2024-02-29", Some (2024, 2, 29));
    ("2026-02-29", None);
    ("2026-13-01", None);
    ("2026-9-27", None);
  ]

(* An interval as Postgres prints it by default, and the instant each part
   means, computed by hand. *)
let interval months days microseconds =
  { Postgres_eio.Interval.months; days; microseconds }

let interval_testable =
  Alcotest.testable
    (fun f (i : Postgres_eio.Interval.t) ->
      Format.fprintf f "%d mons %d days %d us" i.months i.days i.microseconds)
    Postgres_eio.Interval.equal

let intervals =
  [
    ("1 year 2 mons 3 days 04:05:06.789", Some (interval 14 3 14_706_789_000));
    ( "-1 years -2 mons +3 days -04:05:06",
      Some (interval (-14) 3 (-14_706_000_000)) );
    ("1 mon -1 days", Some (interval 1 (-1) 0));
    ("1 day", Some (interval 0 1 0));
    ("00:00:00", Some (interval 0 0 0));
    ("-00:00:01.5", Some (interval 0 0 (-1_500_000)));
    ("00:00:00.000001", Some (interval 0 0 1));
    ("1281023893:59:59.999999", Some (interval 0 0 4_611_686_018_399_999_999));
    ("1281023894:00:27.387903", Some (interval 0 0 max_int));
    ("1281023894:00:27.387904", None);
    ("-1281023894:00:27.387904", Some (interval 0 0 min_int));
    ("-1281023894:00:27.387905", None);
    ("2562047788:00:54.775807", None);
    ("04:60:00", None);
    ("1 fortnight", None);
    ("@ 1 year", None);
    ("P1Y", None);
    ("", None);
  ]

let reads_an_interval (text, expected) =
  Alcotest.test_case ("an interval " ^ text) `Quick (fun () ->
      Alcotest.(check (option interval_testable))
        text expected (Text.to_interval text))

let an_int64_reads_back =
  QCheck2.Test.make ~count:1000 ~name:"an int64 written reads back as itself"
    QCheck2.Gen.int64 (fun n ->
      Option.equal Int64.equal (Text.to_int64 (Text.int64 n)) (Some n))

let reads_a_date (text, expected) =
  Alcotest.test_case ("a date " ^ text) `Quick (fun () ->
      Alcotest.(check (option (triple int int int)))
        text expected (Text.to_date text))

let a_float_reads_back =
  QCheck2.Test.make ~count:1000 ~name:"a float written reads back as itself"
    QCheck2.Gen.float (fun f ->
      Option.equal Float.equal (Text.to_float (Text.float f)) (Some f))

let an_int_reads_back =
  QCheck2.Test.make ~count:1000 ~name:"an int written reads back as itself"
    QCheck2.Gen.int (fun n ->
      Option.equal Int.equal (Text.to_int (Text.int n)) (Some n))

let oid n =
  match Postgres_eio.Oid.of_int n with
  | Some oid -> oid
  | None -> Alcotest.failf "%d is no OID" n

let an_oid_is_four_unsigned_bytes () =
  List.iter
    (fun (n, expected) ->
      Alcotest.(check (option int))
        (string_of_int n) expected
        (Option.map Postgres_eio.Oid.to_int (Postgres_eio.Oid.of_int n)))
    [
      (-1, None);
      (0, Some 0);
      (23, Some 23);
      (4294967295, Some 4294967295);
      (4294967296, None);
    ];
  Alcotest.(check bool)
    "equal to itself" true
    (Postgres_eio.Oid.equal (oid 23) (oid 23));
  Alcotest.(check bool)
    "not to another" false
    (Postgres_eio.Oid.equal (oid 23) (oid 25))

(* 54.8: each field by its code; a missing message is empty, a missing
   detail or hint absent. *)
let a_server_errors_fields () =
  let module E = Postgres_eio.Server_error in
  let e =
    E.of_fields
      [
        ('S', "ERROR");
        ('C', "23505");
        ('M', "duplicate key");
        ('D', "Key (id)=(1) exists.");
        ('H', "Pick another.");
        ('n', "t_pkey");
      ]
  in
  Alcotest.(check string) "message" "duplicate key" (E.message e);
  Alcotest.(check (option string))
    "detail" (Some "Key (id)=(1) exists.") (E.detail e);
  Alcotest.(check (option string)) "hint" (Some "Pick another.") (E.hint e);
  Alcotest.(check (option string))
    "constraint" (Some "t_pkey") (E.constraint_name e);
  Alcotest.(check string)
    "its sentence, without the detail" "ERROR 23505: duplicate key"
    (E.to_string e);
  let bare = E.of_fields [] in
  Alcotest.(check string) "no message" "" (E.message bare);
  Alcotest.(check (option string)) "no detail" None (E.detail bare)

(* 54.7 CommandComplete: a count where the command has one, and a tag not
   known kept whole. *)
let a_command_tag () =
  List.iter
    (fun (tag, command, rows) ->
      let t = Postgres_eio.Tag.of_string tag in
      Alcotest.(check (pair string (option int)))
        tag (command, rows)
        (Postgres_eio.Tag.command t, Postgres_eio.Tag.rows t))
    [
      ("INSERT 0 3", "INSERT", Some 3);
      ("SELECT 5", "SELECT", Some 5);
      ("UPDATE 0", "UPDATE", Some 0);
      ("DELETE 2", "DELETE", Some 2);
      ("MERGE 4", "MERGE", Some 4);
      ("FETCH 1", "FETCH", Some 1);
      ("MOVE 6", "MOVE", Some 6);
      ("COPY 7", "COPY", Some 7);
      ("CREATE TABLE", "CREATE TABLE", None);
      ("COMMIT", "COMMIT", None);
      ("SELECT many", "SELECT", None);
      ("INSERT 0", "INSERT 0", None);
      ("", "", None);
    ]

(* V is never localised, so it decides; S stands in only without it. *)
let a_severity_by_its_unlocalised_name () =
  let module E = Postgres_eio.Server_error in
  let severity fields =
    match E.severity (E.of_fields fields) with
    | E.Error -> "error"
    | E.Fatal -> "fatal"
    | E.Panic -> "panic"
    | E.Warning -> "warning"
    | E.Notice -> "notice"
    | E.Debug -> "debug"
    | E.Info -> "info"
    | E.Log -> "log"
    | E.Other s -> "other " ^ s
  in
  List.iter
    (fun (fields, expected) ->
      Alcotest.(check string) expected expected (severity fields))
    [
      ([ ('V', "ERROR") ], "error");
      ([ ('V', "FATAL") ], "fatal");
      ([ ('V', "PANIC") ], "panic");
      ([ ('V', "WARNING") ], "warning");
      ([ ('V', "NOTICE") ], "notice");
      ([ ('V', "DEBUG") ], "debug");
      ([ ('V', "INFO") ], "info");
      ([ ('V', "LOG") ], "log");
      ([ ('S', "AVERTISSEMENT"); ('V', "WARNING") ], "warning");
      ([ ('S', "AVERTISSEMENT") ], "other AVERTISSEMENT");
      ([], "error");
    ]

(* bytea's hex form, read back as a text cell is. *)
let bytes_read_back =
  QCheck2.Test.make ~count:1000 ~name:"bytes written read back as themselves"
    QCheck2.Gen.string (fun s ->
      let bytea =
        { Postgres_eio.Column.name = "b"; type_oid = oid 17; format = Text }
      in
      Option.equal String.equal
        (Postgres_eio.Value.bytes bytea (Text.bytes s))
        (Some s))

(* Every day of years 1 to 9999, the years both forms read. *)
let a_date_reads_back =
  QCheck2.Test.make ~count:1000 ~name:"a date written reads back as itself"
    QCheck2.Gen.(int_range (-719_162) 2_932_896)
    (fun days ->
      match Option.bind (Ptime.Span.of_d_ps (days, 0L)) Ptime.of_span with
      | None -> QCheck2.Test.fail_reportf "day %d is no instant" days
      | Some instant ->
          let date = Ptime.to_date instant in
          Option.equal
            (fun (y, m, d) (y', m', d') -> y = y' && m = m' && d = d')
            (Text.to_date (Text.date date))
            (Some date))

(* Every microsecond of years 1 to 9999, as either writer gives it. *)
let an_instant_reads_back =
  QCheck2.Test.make ~count:1000 ~print:string_of_int
    ~name:"an instant written reads back as itself"
    QCheck2.Gen.(int_range (-62_135_596_800_000_000) 253_402_300_799_999_999)
    (fun us ->
      let t = instant_of_us us in
      List.for_all
        (fun write ->
          Option.equal Int.equal
            (Option.map us_of (Text.to_timestamptz (write t)))
            (Some us))
        [ Text.timestamptz; Text.timestamp ])

(* A decoder gives a cell's type the same answer whether the cell came as
   text or binary; a type always sent as text is read as its text says. *)
let a_decoder_answers_alike_both_ways () =
  let column type_oid format =
    { Postgres_eio.Column.name = "c"; type_oid = oid type_oid; format }
  in
  let both what decode ~oid ~text ~binary =
    Alcotest.(check (pair bool bool))
      what (false, false)
      ( Option.is_some (decode (column oid Text) text),
        Option.is_some (decode (column oid Binary) binary) )
  in
  let module V = Postgres_eio.Value in
  both "bool of a text" V.bool ~oid:25 ~text:"t" ~binary:"t";
  both "int of a text" V.int ~oid:25 ~text:"42" ~binary:"42";
  both "int64 of a text" V.int64 ~oid:25 ~text:"42" ~binary:"42";
  both "float of an int4" V.float ~oid:23 ~text:"42" ~binary:"\000\000\000*";
  both "json of a text" V.json ~oid:25 ~text:"{}" ~binary:"{}";
  both "bytes of a text" V.bytes ~oid:25 ~text:"ab" ~binary:"ab";
  both "uuid of a text" V.uuid ~oid:25
    ~text:"0190c0fe-1234-7abc-8def-0123456789ab"
    ~binary:"0190c0fe-1234-7abc-8def-0123456789ab";
  both "date of a text" V.date ~oid:25 ~text:"2026-09-27" ~binary:"2026-09-27";
  both "timestamp of a timestamptz" V.timestamp ~oid:1184
    ~text:"2026-01-01 00:00:00+00" ~binary:"\000\002\234\021\000\000\000\000";
  both "timestamptz of a timestamp" V.timestamptz ~oid:1114
    ~text:"2026-01-01 00:00:00" ~binary:"\000\002\234\021\000\000\000\000";
  both "interval of a text" V.interval ~oid:25 ~text:"1 day" ~binary:"1 day";
  Alcotest.(check (option int))
    "but a numeric, always text, is read" (Some 42)
    (V.int (column 1700 Text) "42");
  Alcotest.(check (option (float 0.)))
    "as a float too" (Some 1.5)
    (V.float (column 1700 Text) "1.5")

(* Decimal only, as Postgres writes a number: OCaml's own literals are
   refused, a hex one past the range above all, which would wrap. *)
let a_number_is_decimal () =
  let ints =
    [
      ("42", Some 42);
      ("-7", Some (-7));
      ("+5", Some 5);
      ("007", Some 7);
      ("0x10", None);
      ("0o7", None);
      ("0b11", None);
      ("0u5", None);
      ("1_000", None);
      ("0x7fffffffffffffff", None);
      ("", None);
      ("-", None);
      (" 1", None);
    ]
  in
  List.iter
    (fun (s, expected) ->
      Alcotest.(check (option int)) ("int " ^ s) expected (Text.to_int s);
      Alcotest.(check (option int64))
        ("int64 " ^ s)
        (Option.map Int64.of_int expected)
        (Text.to_int64 s))
    ints;
  Alcotest.(check (option int64))
    "int64 past its range in hex" None
    (Text.to_int64 "0xffffffffffffffff");
  List.iter
    (fun (s, expected) ->
      Alcotest.(check (option (float 0.)))
        ("float " ^ s) expected (Text.to_float s))
    [
      ("1.5", Some 1.5);
      ("-0.25", Some (-0.25));
      ("1e+100", Some 1e100);
      ("1.5e-07", Some 1.5e-07);
      ("3", Some 3.);
      ("Infinity", Some Float.infinity);
      ("0x1p3", None);
      ("1_0.5", None);
      ("nan", None);
      ("inf", None);
      ("1e", None);
      (".", None);
      ("", None);
    ]

(* A binary timestamp is microseconds since 2000-01-01 as an int8: within
   years 1 to 9999, the years text reads, it is that instant; past them,
   however far, it is refused, never wrapped back into range. The bounds
   are 0001-01-01 and 10000-01-01, in seconds since 2000-01-01. *)
let a_binary_instant_reads_as_itself =
  let first = Int64.mul (-63_082_281_600L) 1_000_000L in
  let past = Int64.mul 252_455_616_000L 1_000_000L in
  let unix_us_of_2000 = 946_684_800_000_000 in
  let column =
    { Postgres_eio.Column.name = "t"; type_oid = oid 1114; format = Binary }
  in
  QCheck2.Test.make ~count:1000 ~print:Int64.to_string
    ~name:"a binary instant reads as itself, or not at all"
    QCheck2.Gen.(
      oneof
        [
          int64;
          map Int64.of_int
            (int_range (-63_100_000_000_000_000) 252_500_000_000_000_000);
          (* Past OCaml's int, where a conversion would wrap. *)
          map
            (fun d -> Int64.sub Int64.max_int (Int64.of_int d))
            (int_range 0 Int.max_int);
        ])
    (fun v ->
      let cell = Bytes.create 8 in
      Bytes.set_int64_be cell 0 v;
      let expected =
        if Int64.compare v first >= 0 && Int64.compare v past < 0 then
          Some (Int64.to_int v + unix_us_of_2000)
        else None
      in
      Option.equal Int.equal expected
        (Option.map us_of
           (Postgres_eio.Value.timestamp column (Bytes.to_string cell))))

(* Against a real server, named by POSTGRES_EIO_TEST_PG (see compose.yaml).
   Skipped when unset. *)

module Pg = Postgres_eio

let target = Sys.getenv_opt "POSTGRES_EIO_TEST_PG"

let base () =
  match Option.map Conninfo.of_string target with
  | Some (Ok c) -> c
  | Some (Error e) -> Alcotest.failf "POSTGRES_EIO_TEST_PG: %s" e
  | None -> Alcotest.fail "POSTGRES_EIO_TEST_PG is not set"

let plain () = { (base ()) with ssl_mode = Disable }

let port_of (c : Conninfo.t) =
  match c.hosts with e :: _ -> e.port | [] -> 5432

let at ?port ?address host (c : Conninfo.t) =
  let port =
    match (port, c.hosts) with
    | Some p, _ -> p
    | None, e :: _ -> e.port
    | None, [] -> 5432
  in
  { c with hosts = [ { Conninfo.host; address; port; password = None } ] }

let ca = "postgres/ca.crt"

let with_eio f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw -> f env sw

let seconds_since clock started =
  Mtime.Span.to_float_ns (Mtime.span started (Eio.Time.Mono.now clock)) /. 1e9

let connect_with ?parameters ?timeout_s env sw c =
  Pg.connect ~sw ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.mono_clock env)
    ?parameters ?timeout_s c

let ok_pg = function
  | Ok v -> v
  | Error e -> Alcotest.failf "%s" (Pg.error_to_string e)

let connect ?parameters ?timeout_s env sw c =
  ok_pg (connect_with ?parameters ?timeout_s env sw c)

let rows t sql params =
  let rows, _ =
    ok_pg
      (Pg.query t sql ~params ~init:[] ~row:(fun acc cells ->
           Array.to_list cells :: acc))
  in
  List.rev rows

let one t sql params =
  match rows t sql params with
  | [ [ Some v ] ] -> v
  | _ -> Alcotest.failf "%s: not one value" sql

let script t sql = ok_pg (Pg.script t sql)

(* One role per sign-in method, recreated by each case since roles outlive
   a run. *)
let make_role env sw ?(encryption = "scram-sha-256") name password =
  let admin = connect env sw (plain ()) in
  script admin (Printf.sprintf "drop role if exists %s" name);
  script admin (Printf.sprintf "set password_encryption = '%s'" encryption);
  script admin
    (Printf.sprintf "create role %s login %s" name
       (match password with
       | Some p -> Printf.sprintf "password '%s'" p
       | None -> ""));
  Pg.close admin

let as_role c name password =
  { c with Conninfo.user = name; password; database = c.Conninfo.database }

let tls_in_use t =
  String.equal
    (one t "select ssl::text from pg_stat_ssl where pid = pg_backend_pid()" [])
    "true"

let a_query_by_scram () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  let result, tag =
    ok_pg
      (Pg.query t "select $1::int + 1, $2::text, $3::text, $1::int"
         ~params:[ Some "41"; Some "go"; None ] ~init:[] ~row:(fun acc cells ->
           cells :: acc))
  in
  (match result with
  | [ [| Some "42"; Some "go"; None; Some "41" |] ] -> ()
  | _ -> Alcotest.fail "the row is not what was bound");
  Alcotest.(check (pair string (option int)))
    "its tag" ("SELECT", Some 1)
    (Pg.Tag.command tag, Pg.Tag.rows tag);
  Alcotest.(check bool)
    "idle after" true
    (match Pg.status t with P.Idle -> true | _ -> false);
  Alcotest.(check bool)
    "the server said its version" true
    (match Pg.parameter t "server_version" with
    | Some v -> String.starts_with ~prefix:"18" v
    | None -> false);
  Pg.close t;
  Alcotest.(check bool) "closed" true (Pg.closed t)

(* verify-full over TLS, signed in by SCRAM. *)
let verify_full_over_tls () =
  with_eio @@ fun env sw ->
  let c = { (base ()) with ssl_mode = Verify_full; ssl_root_cert = Some ca } in
  let t = connect env sw c in
  Alcotest.(check bool) "over TLS" true (tls_in_use t);
  Alcotest.(check string) "and it answers" "1" (one t "select 1" []);
  Pg.close t;
  let t = connect env sw (at (Tcp "127.0.0.1") c) in
  Alcotest.(check bool) "an address the certificate names" true (tls_in_use t);
  Pg.close t

(* An untrusted CA is refused in the handshake, before any password. *)
let verify_full_refuses_an_untrusted_certificate () =
  with_eio @@ fun env sw ->
  match
    connect_with env sw
      { (base ()) with ssl_mode = Verify_full; ssl_root_cert = None }
  with
  | Error (Pg.Io _) -> ()
  | Error e ->
      Alcotest.failf "refused, but not in the handshake: %s"
        (Pg.error_to_string e)
  | Ok _ -> Alcotest.fail "connected to a server it had no reason to trust"

let every_sslmode () =
  with_eio @@ fun env sw ->
  List.iter
    (fun (mode, root, over_tls) ->
      let t =
        connect env sw { (base ()) with ssl_mode = mode; ssl_root_cert = root }
      in
      Alcotest.(check bool)
        (Conninfo.ssl_mode_to_string mode)
        over_tls (tls_in_use t);
      Pg.close t)
    [
      (Conninfo.Disable, None, false);
      (Allow, None, false);
      (Prefer, None, true);
      (Require, None, true);
      (Verify_ca, Some ca, true);
      (Verify_full, Some ca, true);
    ]

let signed_in_by_md5 () =
  with_eio @@ fun env sw ->
  make_role env sw ~encryption:"md5" "pgeio_md5" (Some "md5-pass");
  let t = connect env sw (as_role (plain ()) "pgeio_md5" (Some "md5-pass")) in
  Alcotest.(check string)
    "signed in by MD5" "pgeio_md5"
    (one t "select current_user" []);
  Pg.close t;
  match connect_with env sw (as_role (plain ()) "pgeio_md5" (Some "wrong")) with
  | Error (Pg.Server e) ->
      Alcotest.(check string)
        "a wrong password" "28P01"
        (Pg.Server_error.sqlstate e)
  | Error e ->
      Alcotest.failf "not the server's refusal: %s" (Pg.error_to_string e)
  | Ok _ -> Alcotest.fail "signed in with the wrong password"

let cleartext_over_tls () =
  with_eio @@ fun env sw ->
  make_role env sw "pgeio_cleartext" (Some "clear-pass");
  let t =
    connect env sw
      (as_role
         { (base ()) with ssl_mode = Require }
         "pgeio_cleartext" (Some "clear-pass"))
  in
  Alcotest.(check string)
    "signed in with a password, inside TLS" "pgeio_cleartext"
    (one t "select current_user" []);
  Pg.close t

let trust () =
  with_eio @@ fun env sw ->
  make_role env sw "pgeio_trust" None;
  let t = connect env sw (as_role (plain ()) "pgeio_trust" None) in
  Alcotest.(check string)
    "signed in by trust" "pgeio_trust"
    (one t "select current_user" []);
  Pg.close t

(* A fake server that asks for a cleartext password without TLS and records
   what the client sends. *)
let a_fake_server env sw ~answer =
  let listener =
    Eio.Net.listen ~sw ~backlog:4 (Eio.Stdenv.net env)
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr listener with `Tcp (_, p) -> p | `Unix _ -> 0
  in
  let heard = Buffer.create 64 in
  let closed, close = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Net.accept_fork ~sw listener ~on_error:raise (fun flow _ ->
          let buf = Cstruct.create 1024 in

          let n = Eio.Flow.single_read flow buf in
          ignore n;
          Option.iter (fun a -> Eio.Flow.copy_string a flow) answer;
          (try
             while true do
               let n = Eio.Flow.single_read flow buf in
               Buffer.add_string heard (Cstruct.to_string ~len:n buf)
             done
           with End_of_file | Eio.Io _ -> ());
          Eio.Promise.resolve close ());
      `Stop_daemon);
  (port, heard, closed)

let cleartext_without_tls_is_refused () =
  with_eio @@ fun env sw ->
  let port, heard, closed =
    a_fake_server env sw ~answer:(Some (msg 'R' (int32 3)))
  in
  let c =
    {
      (at ~port (Tcp "127.0.0.1") (plain ())) with
      password = Some "never-sent";
    }
  in
  (match connect_with env sw c with
  | Error (Pg.Refused m) ->
      Alcotest.(check bool) m true (contains m "cleartext")
  | Error e -> Alcotest.failf "not refused here: %s" (Pg.error_to_string e)
  | Ok _ -> Alcotest.fail "connected");
  Eio.Promise.await closed;
  Alcotest.(check bool)
    "nothing was sent after the request" false
    (contains (Buffer.contents heard) "never-sent");
  Alcotest.(check int) "not a byte" 0 (Buffer.length heard)

(* Docker cannot expose a Unix socket from its VM, so a local socket is
   relayed to the TCP port. *)
let over_a_unix_socket () =
  with_eio @@ fun env sw ->
  let c = plain () in
  (* /tmp: a sandbox's temp dir can exceed the socket path limit. *)
  let dir = Printf.sprintf "/tmp/pgeio-%d" (Unix.getpid ()) in
  (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat dir (Printf.sprintf ".s.PGSQL.%d" (port_of c)) in
  (try Unix.unlink path with Unix.Unix_error _ -> ());
  let net = Eio.Stdenv.net env in
  let listener = Eio.Net.listen ~sw ~backlog:4 net (`Unix path) in
  let server = `Tcp (Eio.Net.Ipaddr.V4.loopback, port_of c) in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Net.accept_fork ~sw listener
        ~on_error:(fun _ -> ())
        (fun client _ ->
          Eio.Switch.run @@ fun sw ->
          let upstream = Eio.Net.connect ~sw net server in
          let pass a b () =
            try
              Eio.Flow.copy a b;
              Eio.Flow.shutdown b `Send
            with Eio.Io _ -> ()
          in
          Eio.Fiber.both (pass client upstream) (pass upstream client));
      `Stop_daemon);
  let t = connect env sw (at (Unix_socket dir) c) in
  Alcotest.(check string) "a query over the socket" "7" (one t "select 7" []);
  Pg.close t

(* 54.2.3: describe returns inferred parameter types and columns without
   running; a parse error leaves the connection usable. *)
let a_statement_is_described_without_running () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  script t "create temp table d (x int4)";
  (match Pg.describe t "select $1::int4 + 1 as n, 'a'::text as t" with
  | Ok d ->
      Alcotest.(check (list int))
        "a parameter's type" [ 23 ]
        (List.map Postgres_eio.Oid.to_int d.parameters);
      Alcotest.(check (list (pair string int)))
        "each column, named and typed"
        [ ("n", 23); ("t", 25) ]
        (List.map
           (fun (c : Pg.Column.t) -> (c.name, Pg.Oid.to_int c.type_oid))
           (Array.to_list d.columns))
  | Error e -> Alcotest.failf "not described: %s" (Pg.error_to_string e));
  (match Pg.describe t "insert into d values ($1)" with
  | Ok d ->
      Alcotest.(check (list int))
        "an insert's parameter" [ 23 ]
        (List.map Postgres_eio.Oid.to_int d.parameters);
      Alcotest.(check int) "and no columns" 0 (Array.length d.columns)
  | Error e -> Alcotest.failf "not described: %s" (Pg.error_to_string e));
  Alcotest.(check string)
    "and nothing was run" "0"
    (one t "select count(*) from d" []);
  (match Pg.describe t "selec 1" with
  | Error (Pg.Server _) -> ()
  | Error e ->
      Alcotest.failf "not the server's refusal: %s" (Pg.error_to_string e)
  | Ok _ -> Alcotest.fail "a statement that does not parse was described");
  Alcotest.(check string)
    "the connection usable after" "7" (one t "select 7" []);
  Pg.close t

(* Cancelling from another fiber stops the statement and leaves the
   connection idle. *)
let a_running_statement_is_cancelled () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  let clock = Eio.Stdenv.mono_clock env in
  let started = Eio.Time.Mono.now clock in
  let answer = ref (Ok ([], Pg.Tag.empty)) in
  Eio.Fiber.both
    (fun () ->
      answer :=
        Pg.query t "select pg_sleep(5)" ~params:[] ~init:[] ~row:(fun a _ -> a))
    (fun () ->
      Eio.Time.Mono.sleep clock 0.2;
      ok_pg (Pg.cancel t));
  let took =
    Mtime.Span.to_float_ns (Mtime.span started (Eio.Time.Mono.now clock)) /. 1e9
  in
  (match !answer with
  | Error (Pg.Server e) ->
      Alcotest.(check string) "cancelled" "57014" (Pg.Server_error.sqlstate e)
  | Error e -> Alcotest.failf "not cancelled: %s" (Pg.error_to_string e)
  | Ok _ -> Alcotest.fail "the statement ran to its end");
  Alcotest.(check bool)
    (Printf.sprintf "at once, in %.2fs" took)
    true (took < 2.);
  Alcotest.(check bool)
    "idle" true
    (match Pg.status t with P.Idle -> true | _ -> false);
  Alcotest.(check string) "and usable" "1" (one t "select 1" []);
  Alcotest.(check bool)
    "nothing running is nothing to cancel" true
    (Result.is_ok (Pg.cancel t));
  Pg.close t

let a_cancel_over_tls () =
  with_eio @@ fun env sw ->
  let t = connect env sw { (base ()) with ssl_mode = Require } in
  let clock = Eio.Stdenv.mono_clock env in
  let answer = ref (Ok ([], Pg.Tag.empty)) in
  Eio.Fiber.both
    (fun () ->
      answer :=
        Pg.query t "select pg_sleep(5)" ~params:[] ~init:[] ~row:(fun a _ -> a))
    (fun () ->
      Eio.Time.Mono.sleep clock 0.2;
      ok_pg (Pg.cancel t));
  (match !answer with
  | Error (Pg.Server e) ->
      Alcotest.(check string) "cancelled" "57014" (Pg.Server_error.sqlstate e)
  | _ -> Alcotest.fail "not cancelled");
  Pg.close t

(* Until the backend has gone, so its final message has been sent. *)
let terminate env sw pid =
  let admin = connect env sw (plain ()) in
  ignore (rows admin "select pg_terminate_backend($1::int, 5000)" [ Some pid ]);
  Pg.close admin

(* A terminated backend is reported, and reset restores the startup
   parameters. *)
let a_reset_keeps_its_parameters () =
  with_eio @@ fun env sw ->
  let t =
    connect env sw
      ~parameters:
        [ ("client_min_messages", "warning"); ("statement_timeout", "7s") ]
      (plain ())
  in
  terminate env sw (one t "select pg_backend_pid()::text" []);
  (match Pg.query t "select 1" ~params:[] ~init:() ~row:(fun () _ -> ()) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a statement on a terminated backend succeeded");
  Alcotest.(check bool) "closed" true (Pg.closed t);
  Alcotest.(check bool)
    "and says so" true
    (match Pg.script t "select 1" with Error Pg.Closed -> true | _ -> false);
  ok_pg (Pg.reset t);
  Alcotest.(check string)
    "client_min_messages" "warning"
    (one t "show client_min_messages" []);
  Alcotest.(check string)
    "statement_timeout" "7s"
    (one t "show statement_timeout" []);
  Pg.close t

let a_silent_server_times_out () =
  with_eio @@ fun env sw ->
  let port, _, _ = a_fake_server env sw ~answer:None in
  let clock = Eio.Stdenv.mono_clock env in
  let started = Eio.Time.Mono.now clock in
  (match
     connect_with ~timeout_s:0.3 env sw (at ~port (Tcp "127.0.0.1") (plain ()))
   with
  | Error Pg.Timeout -> ()
  | Error e -> Alcotest.failf "not a timeout: %s" (Pg.error_to_string e)
  | Ok _ -> Alcotest.fail "connected to nothing");
  let took =
    Mtime.Span.to_float_ns (Mtime.span started (Eio.Time.Mono.now clock)) /. 1e9
  in
  Alcotest.(check bool)
    (Printf.sprintf "within the bound, in %.2fs" took)
    true (took < 2.)

let a_read_past_the_timeout () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  Pg.set_timeout t ~timeout_s:(Some 0.3);
  Alcotest.(check bool)
    "a timeout" true
    (match
       Pg.query t "select pg_sleep(2)" ~params:[] ~init:() ~row:(fun () _ -> ())
     with
    | Error Pg.Timeout -> true
    | _ -> false);
  Alcotest.(check bool)
    "and the connection closed, out of step" true (Pg.closed t);
  ok_pg (Pg.reset t);
  Pg.set_timeout t ~timeout_s:None;
  Alcotest.(check string)
    "lifted, a long statement runs" ""
    (one t "select pg_sleep(0.5)::text" []);
  Pg.close t

(* An unclosed connection's timer does not keep its switch alive. *)
let a_connection_left_open_lets_its_switch_finish () =
  with_eio @@ fun env _ ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () ->
      Eio.Switch.run (fun sw -> ignore (connect env sw (plain ()))))

(* A caller's cancellation propagates as is, never as [Timeout]. *)
let a_cancellation_from_outside_is_not_a_timeout () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  let raised = ref false in
  Eio.Fiber.first
    (fun () ->
      match one t "select pg_sleep(2)::text" [] with
      | _ -> Alcotest.fail "the statement outlived its cancellation"
      | exception (Eio.Cancel.Cancelled _ as ex) ->
          raised := true;
          raise ex)
    (fun () -> Eio.Time.Mono.sleep (Eio.Stdenv.mono_clock env) 0.2);
  Alcotest.(check bool) "the cancellation raised" true !raised;
  Alcotest.(check bool) "and the connection closed" true (Pg.closed t)

let a_server_error_keeps_the_connection () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  (match Pg.query t "select 1/0" ~params:[] ~init:() ~row:(fun () _ -> ()) with
  | Error (Pg.Server e) ->
      Alcotest.(check string)
        "its SQLSTATE" "22012"
        (Pg.Server_error.sqlstate e);
      Alcotest.(check bool)
        "its severity" true
        (match Pg.Server_error.severity e with
        | Pg.Server_error.Error -> true
        | _ -> false);
      Alcotest.(check bool)
        "every field kept" true
        (Option.is_some (Pg.Server_error.field e 'R'));
      Alcotest.(check bool)
        "in the order sent, severity first" true
        (match Pg.Server_error.fields e with
        | ('S', _) :: rest -> List.mem_assoc 'C' rest && List.mem_assoc 'M' rest
        | _ -> false);
      Alcotest.(check (option string)) "no hint" None (Pg.Server_error.hint e)
  | _ -> Alcotest.fail "not the server's error");
  (match
     Pg.query t "select no_such_function(1)" ~params:[] ~init:()
       ~row:(fun () _ -> ())
   with
  | Error (Pg.Server e) ->
      Alcotest.(check string)
        "an undefined function" "42883"
        (Pg.Server_error.sqlstate e);
      Alcotest.(check bool)
        "and the server's hint" true
        (Option.is_some (Pg.Server_error.hint e))
  | _ -> Alcotest.fail "not the server's error");
  script t "create temp table u (n int constraint u_n unique)";
  script t "insert into u values (1)";
  (match
     Pg.query t "insert into u values ($1::int)" ~params:[ Some "1" ] ~init:()
       ~row:(fun () _ -> ())
   with
  | Error (Pg.Server e) ->
      Alcotest.(check string)
        "a unique violation" "23505"
        (Pg.Server_error.sqlstate e);
      Alcotest.(check (option string))
        "its constraint" (Some "u_n")
        (Pg.Server_error.constraint_name e);
      Alcotest.(check bool)
        "the detail is kept, and not in the string" true
        (Option.is_some (Pg.Server_error.detail e)
        && not (contains (Pg.Server_error.to_string e) "(n)=(1)"))
  | _ -> Alcotest.fail "not a unique violation");
  Alcotest.(check bool) "still open" false (Pg.closed t);
  Alcotest.(check string) "and usable" "1" (one t "select 1" []);
  Pg.close t

let transaction_status () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  let status () =
    match Pg.status t with
    | P.Idle -> "idle"
    | P.In_transaction -> "in"
    | P.Failed -> "failed"
  in
  script t "begin";
  Alcotest.(check string) "54.7 ReadyForQuery T" "in" (status ());
  ignore (Pg.query t "select 1/0" ~params:[] ~init:() ~row:(fun () _ -> ()));
  Alcotest.(check string) "54.7 ReadyForQuery E" "failed" (status ());
  (match Pg.query t "commit" ~params:[] ~init:() ~row:(fun () _ -> ()) with
  | Ok ((), tag) ->
      Alcotest.(check string)
        "a commit that rolled back" "ROLLBACK" (Pg.Tag.command tag)
  | Error e -> Alcotest.fail (Pg.error_to_string e));
  Alcotest.(check string) "54.7 ReadyForQuery I" "idle" (status ());
  Pg.close t

let a_script_of_several_statements () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  script t
    "create temp table a (n int); insert into a values (1); insert into a \
     values (2)";
  Alcotest.(check string)
    "54.2.2.1 every statement ran" "2"
    (one t "select count(*) from a" []);
  (match
     Pg.script t
       "insert into a values (3); select 1/0; insert into a values (4)"
   with
  | Error (Pg.Server e) ->
      Alcotest.(check string) "the error" "22012" (Pg.Server_error.sqlstate e)
  | _ -> Alcotest.fail "no error");
  Alcotest.(check string)
    "54.2.2.1 one implicit transaction, rolled back" "2"
    (one t "select count(*) from a" []);
  Pg.close t

let the_rest_of_a_query () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  (match Pg.query t "" ~params:[] ~init:() ~row:(fun () _ -> ()) with
  | Ok ((), tag) ->
      Alcotest.(check string) "54.7 EmptyQueryResponse" "" (Pg.Tag.command tag)
  | Error e -> Alcotest.fail (Pg.error_to_string e));
  let big = one t "select repeat('x', 1000000)" [] in
  Alcotest.(check int) "a megabyte in one column" 1_000_000 (String.length big);
  script t "create temp table w (n int)";
  (match
     Pg.query t "insert into w select generate_series(1, 5)" ~params:[] ~init:()
       ~row:(fun () _ -> ())
   with
  | Ok ((), tag) ->
      Alcotest.(check (option int)) "INSERT's count" (Some 5) (Pg.Tag.rows tag)
  | Error e -> Alcotest.fail (Pg.error_to_string e));
  (match
     Pg.query t "select 1\000" ~params:[] ~init:() ~row:(fun () _ -> ())
   with
  | Error (Pg.Refused _) -> ()
  | _ -> Alcotest.fail "a NUL in a statement was sent");
  Alcotest.(check bool)
    "refused before sending, so still open" false (Pg.closed t);
  (match
     Pg.query t "select 1" ~params:[] ~init:() ~row:(fun () _ -> raise Exit)
   with
  | exception Exit -> ()
  | _ -> Alcotest.fail "the row's raise did not pass");
  Alcotest.(check bool) "a row that raised closed it" true (Pg.closed t);
  Pg.close t

let copy_is_refused () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  script t "create temp table c (n int)";
  List.iter
    (fun sql ->
      (match Pg.query t sql ~params:[] ~init:() ~row:(fun () _ -> ()) with
      | Error (Pg.Refused m) -> Alcotest.(check bool) m true (contains m "COPY")
      | _ -> Alcotest.failf "%s was not refused" sql);
      Alcotest.(check string)
        (sql ^ ", and the connection is usable")
        "1" (one t "select 1" []))
    [ "copy c from stdin"; "copy (select 1) to stdout" ];
  (match Pg.script t "copy c from stdin" with
  | Error (Pg.Refused _) -> ()
  | _ -> Alcotest.fail "a simple COPY was not refused");
  Alcotest.(check string) "and after a simple one" "1" (one t "select 1" []);
  Pg.close t

(* COPY *)

let count t table =
  int_of_string (one t ("select count(*)::text from " ^ table) [])

let in_step t =
  Alcotest.(check bool) "open" false (Pg.closed t);
  Alcotest.(check bool)
    "idle" true
    (match Pg.status t with P.Idle -> true | _ -> false);
  Alcotest.(check string) "answering" "1" (one t "select 1" [])

let show_rows rows =
  List.map (fun cells -> String.concat "|" (List.map show_cell cells)) rows

(* Every escaped character, and cells that resemble escapes or NULL. *)
let awkward =
  [
    [ Some "1"; Some "plain" ];
    [ Some "2"; Some "a\ttab" ];
    [ Some "3"; Some "a\nnewline" ];
    [ Some "4"; Some "a\rreturn" ];
    [ Some "5"; Some "a\\backslash" ];
    [ Some "6"; Some "\\N" ];
    [ Some "7"; Some "" ];
    [ Some "8"; None ];
    [ Some "9"; Some "\\." ];
    [ Some "10"; Some "\\x41\\101" ];
    [ Some "11"; Some "\xe7\xa2\x81 \xe2\x80\x94 go" ];
    (* past one CopyData in either direction *)
    [ Some "12"; Some (String.make 100_000 'x') ];
  ]

let copy_rows_both_ways () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  script t {|create temp table "Odd ""name""" (n int, "S" text)|};
  let tag =
    ok_pg
      (Pg.copy_in_rows t ~schema:"pg_temp" ~table:{|Odd "name"|}
         ~columns:[ "n"; "S" ]
         (List.to_seq (List.map Array.of_list awkward)))
  in
  Alcotest.(check (pair string (option int)))
    "its tag" ("COPY", Some 12)
    (Pg.Tag.command tag, Pg.Tag.rows tag);
  let select = {|select n, "S" from "Odd ""name""" order by n|} in
  Alcotest.(check (list string))
    "54.2.6 the rows, as a query reads them" (show_rows awkward)
    (show_rows (rows t select []));
  let back, tag =
    ok_pg
      (Pg.copy_out_rows t ~select ~init:[] ~row:(fun acc cells ->
           Array.to_list cells :: acc))
  in
  Alcotest.(check (list string))
    "54.2.6 the rows, as COPY TO STDOUT reads them" (show_rows awkward)
    (show_rows (List.rev back));
  Alcotest.(check (option int)) "that tag" (Some 12) (Pg.Tag.rows tag);
  in_step t;
  Pg.close t

(* The raw forms pass any COPY format through. *)
let copy_bytes_both_ways () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  script t "create temp table c (n int, s text)";
  let csv = "1,\"a,b\"\n2,\n3,\"say \"\"go\"\"\"\n" in
  let tag =
    ok_pg
      (Pg.copy_in t "copy c from stdin with (format csv)"
         (Eio.Flow.string_source csv))
  in
  Alcotest.(check (option int)) "54.2.6 in" (Some 3) (Pg.Tag.rows tag);
  Alcotest.(check (list string))
    "as CSV says"
    [ "\"1\"|\"a,b\""; "\"2\"|NULL"; "\"3\"|\"say \\\"go\\\"\"" ]
    (show_rows (rows t "select n::text, s from c order by n" []));
  let out, tag =
    ok_pg
      (Pg.copy_out t
         "copy (select n, s from c order by n) to stdout with (format csv)"
         ~init:"" ~chunk:( ^ ))
  in
  Alcotest.(check string) "54.2.6 out, the same bytes" csv out;
  Alcotest.(check (option int)) "out" (Some 3) (Pg.Tag.rows tag);
  in_step t;
  Pg.close t

exception Producer_failed

(* A load failing half-way writes nothing and leaves the connection usable. *)
let a_producer_that_raises () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  script t "create temp table c (n int)";
  let rows =
    Seq.init 1_000_000 (fun i ->
        if i = 500_000 then raise Producer_failed
        else [| Some (string_of_int i) |])
  in
  (match Pg.copy_in_rows t ~table:"c" ~columns:[ "n" ] rows with
  | exception Producer_failed -> ()
  | Ok _ -> Alcotest.fail "the COPY finished"
  | Error e ->
      Alcotest.failf "an error, not the raise: %s" (Pg.error_to_string e));
  Alcotest.(check int)
    "54.2.6 CopyFail: none of it is in the table" 0 (count t "c");
  in_step t;
  (* Inside a transaction, the failure aborts it. *)
  script t "begin";
  (match Pg.copy_in_rows t ~table:"c" ~columns:[ "n" ] rows with
  | exception Producer_failed -> ()
  | _ -> Alcotest.fail "the raise did not pass");
  Alcotest.(check bool)
    "the transaction is aborted" true
    (match Pg.status t with P.Failed -> true | _ -> false);
  script t "rollback";
  in_step t;
  Pg.close t

let a_refusal_part_way () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  script t "create temp table c (n int)";
  let rows = List.to_seq [ [| Some "1" |]; [| Some "two" |]; [| Some "3" |] ] in
  (match Pg.copy_in_rows t ~table:"c" ~columns:[ "n" ] rows with
  | Error (Pg.Server e) ->
      Alcotest.(check string)
        "the server's reason" "22P02"
        (Pg.Server_error.sqlstate e)
  | _ -> Alcotest.fail "not the server's refusal");
  Alcotest.(check int) "none of it" 0 (count t "c");
  in_step t;
  Pg.close t

(* Each function given the wrong statement kind, or one the server refuses,
   returns an error and leaves the connection usable. *)
let the_wrong_statement () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  script t "create temp table c (n int)";
  let refused what = function
    | Error (Pg.Refused m) ->
        Alcotest.(check bool) (what ^ ": " ^ m) true (contains m "not a COPY");
        in_step t
    | Error e -> Alcotest.failf "%s: %s" what (Pg.error_to_string e)
    | Ok _ -> Alcotest.failf "%s was carried" what
  in
  let server what = function
    | Error (Pg.Server _) -> in_step t
    | Error e -> Alcotest.failf "%s: %s" what (Pg.error_to_string e)
    | Ok _ -> Alcotest.failf "%s was carried" what
  in
  let source () = Eio.Flow.string_source "1\n" in
  let into sql = Result.map ignore (Pg.copy_in t sql (source ())) in
  let out_of sql =
    Result.map ignore (Pg.copy_out t sql ~init:() ~chunk:(fun () _ -> ()))
  in
  refused "a select, in" (into "select 1");
  refused "a COPY out, in" (into "copy (select 1) to stdout");
  refused "a COPY in, out" (out_of "copy c from stdin");
  refused "a select, out" (out_of "select 1");
  Alcotest.(check int) "nothing was copied in" 0 (count t "c");
  server "a syntax error, in" (into "copy c frm stdin");
  server "no such table, out" (out_of "copy (select * from nosuch) to stdout");
  Pg.close t

let a_nul_in_a_copy () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  script t "create temp table c (s text)";
  (match
     Pg.copy_in_rows t ~table:"c" ~columns:[ "s" ]
       (List.to_seq [ [| Some "a" |]; [| Some "b\000c" |] ])
   with
  | Error (Pg.Refused m) -> Alcotest.(check bool) m true (contains m "NUL")
  | _ -> Alcotest.fail "a value holding a NUL was not refused");
  Alcotest.(check int) "none of it" 0 (count t "c");
  in_step t;
  (* A NUL in a name is refused before sending, even on a closed connection. *)
  Pg.close t;
  match Pg.copy_in_rows t ~table:"c\000" ~columns:[] Seq.empty with
  | Error (Pg.Refused m) -> Alcotest.(check bool) m true (contains m "NUL")
  | _ -> Alcotest.fail "a name holding a NUL was not refused first"

let a_cancelled_copy_closes () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  script t "create temp table c (n int)";
  let forever =
    Seq.forever (fun () ->
        Eio.Fiber.yield ();
        [| Some "1" |])
  in
  Eio.Fiber.first
    (fun () -> ignore (Pg.copy_in_rows t ~table:"c" ~columns:[ "n" ] forever))
    (fun () -> Eio.Time.Mono.sleep (Eio.Stdenv.mono_clock env) 0.2);
  Alcotest.(check bool) "closed" true (Pg.closed t);
  ok_pg (Pg.reset t);
  in_step t;
  Pg.close t

(* Sign-in and connecting *)

let endpoint ?(port = port_of (base ())) host =
  { Conninfo.host = Tcp host; address = None; port; password = None }

let refused_saying what needle = function
  | Error (Pg.Refused m) ->
      Alcotest.(check bool) (what ^ ": " ^ m) true (contains m needle)
  | Error e ->
      Alcotest.failf "%s: not refused here: %s" what (Pg.error_to_string e)
  | Ok _ -> Alcotest.failf "%s: connected" what

let cancelled env t =
  let clock = Eio.Stdenv.mono_clock env in
  let answer = ref (Ok ((), Pg.Tag.empty)) in
  Eio.Fiber.both
    (fun () ->
      answer :=
        Pg.query t "select pg_sleep(5)" ~params:[] ~init:() ~row:(fun () _ ->
            ()))
    (fun () ->
      Eio.Time.Mono.sleep clock 0.2;
      ok_pg (Pg.cancel t));
  match !answer with
  | Error (Pg.Server e) ->
      Alcotest.(check string) "cancelled" "57014" (Pg.Server_error.sqlstate e)
  | _ -> Alcotest.fail "not cancelled"

(* A fake server that trusts everyone. It answers SSLRequest with [ssl]
   ("N"; "E" then nothing; or "S" then non-TLS bytes), and StartupMessage
   with [before], AuthenticationOk, [reported] as ParameterStatus, and
   ReadyForQuery. It counts connections. *)
let a_fake_postgres env sw ?(ssl = "N") ?(before = "") ?(reported = []) () =
  let listener =
    Eio.Net.listen ~sw ~backlog:8 (Eio.Stdenv.net env)
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr listener with `Tcp (_, p) -> p | `Unix _ -> 0
  in
  let taken = ref 0 in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Net.run_server listener ~on_error:ignore (fun flow _ ->
          incr taken;
          let r = Eio.Buf_read.of_flow flow ~max_size:65536 in
          let take_int32 () =
            Int32.to_int (String.get_int32_be (Eio.Buf_read.take 4 r) 0)
          in
          let write s = Eio.Flow.copy_string s flow in
          let rec startup () =
            let body = Eio.Buf_read.take (take_int32 () - 4) r in
            if
              String.length body = 4
              && Int32.equal (String.get_int32_be body 0) 80877103l
            then begin
              write ssl;
              if String.equal ssl "N" then startup ()
            end
            else begin
              write
                (before
                ^ msg 'R' (int32 0)
                ^ String.concat ""
                    (List.map
                       (fun (k, v) -> msg 'S' (cstr k ^ cstr v))
                       reported)
                ^ msg 'K' (int32 1 ^ "keys")
                ^ msg 'Z' "I");
              let rec until_terminate () =
                match Eio.Buf_read.any_char r with
                | 'X' -> ()
                | _ ->
                    ignore (Eio.Buf_read.take (take_int32 () - 4) r);
                    until_terminate ()
              in
              until_terminate ()
            end
          in
          try startup () with End_of_file | Eio.Io _ -> ()));
  (port, taken)

let fake port = at ~port (Tcp "127.0.0.1") (plain ())

let a_sign_in_bound_to_tls () =
  with_eio @@ fun env sw ->
  List.iter
    (fun negotiation ->
      let t =
        connect env sw
          {
            (base ()) with
            ssl_mode = Verify_full;
            ssl_root_cert = Some ca;
            ssl_negotiation = negotiation;
            channel_binding = Binding_required;
          }
      in
      Alcotest.(check bool)
        "54.3.1 SCRAM-SHA-256-PLUS, over TLS" true (tls_in_use t);
      Pg.close t)
    [ Postgres; Direct ]

(* channel_binding=require refuses a server not offering it, before SASL. *)
let a_required_binding_refuses_a_server_without_one () =
  with_eio @@ fun env sw ->
  let port, heard, closed =
    a_fake_server env sw
      ~answer:(Some (msg 'R' (int32 10 ^ cstr "SCRAM-SHA-256" ^ "\000")))
  in
  refused_saying "a server offering only SCRAM-SHA-256" "channel binding"
    (connect_with env sw
       { (fake port) with ssl_mode = Allow; channel_binding = Binding_required });
  Eio.Promise.await closed;
  Alcotest.(check int)
    "54.3.1 not a byte after the offer" 0 (Buffer.length heard)

(* require_auth=scram-sha-256 refuses trust and password requests without
   sending the password. *)
let require_auth_refuses_what_it_does_not_allow () =
  with_eio @@ fun env sw ->
  let require =
    {
      Conninfo.password = false;
      md5 = false;
      scram_sha_256 = true;
      none = false;
    }
  in
  let port, heard, closed =
    a_fake_server env sw ~answer:(Some (msg 'R' (int32 0) ^ msg 'Z' "I"))
  in
  refused_saying "a server that asks for nothing" "without asking"
    (connect_with env sw { (fake port) with require_auth = require });
  Eio.Promise.await closed;
  Alcotest.(check int) "54.2.1 nothing after" 0 (Buffer.length heard);
  let port, heard, closed =
    a_fake_server env sw ~answer:(Some (msg 'R' (int32 3)))
  in
  refused_saying "a server that asks for a password" "require_auth"
    (connect_with env sw
       { (fake port) with require_auth = require; password = Some "never-sent" });
  Eio.Promise.await closed;
  Alcotest.(check bool)
    "54.3 the password never sent" false
    (contains (Buffer.contents heard) "never-sent");

  let t = connect env sw { (plain ()) with require_auth = require } in
  Pg.close t;
  refused_saying "md5 only, where the server asks for SCRAM" "require_auth"
    (connect_with env sw
       {
         (plain ()) with
         require_auth = { require with scram_sha_256 = false; md5 = true };
       })

let direct_tls () =
  with_eio @@ fun env sw ->
  let t =
    connect env sw
      {
        (base ()) with
        ssl_mode = Verify_full;
        ssl_root_cert = Some ca;
        ssl_negotiation = Direct;
      }
  in
  Alcotest.(check bool) "54.2.10 TLS from the first byte" true (tls_in_use t);
  cancelled env t;
  Pg.close t

(* [prefer] retries without TLS where libpq does; [require] never does. *)
let prefer_falls_back () =
  with_eio @@ fun env sw ->
  List.iter
    (fun (what, ssl) ->
      let port, taken = a_fake_postgres env sw ~ssl () in
      let t = connect env sw { (fake port) with ssl_mode = Prefer } in
      Alcotest.(check int) (what ^ ": a second connection, plain") 2 !taken;
      Pg.close t;
      match connect_with env sw { (fake port) with ssl_mode = Require } with
      | Ok _ -> Alcotest.failf "%s: require connected without TLS" what
      | Error _ -> ())
    [
      ("54.2.10 an ErrorResponse to the SSLRequest", "E");
      ("a handshake that fails", "Sthis is not TLS");
    ]

let a_client_certificate () =
  with_eio @@ fun env sw ->
  make_role env sw "pgeio_cert" None;
  let c =
    {
      (as_role (base ()) "pgeio_cert" None) with
      ssl_mode = Verify_full;
      ssl_root_cert = Some ca;
      ssl_cert = Some "postgres/client.crt";
      ssl_key = Some "postgres/client.key";
    }
  in
  let t = connect env sw c in
  Alcotest.(check string)
    "signed in by the certificate" "pgeio_cert"
    (one t "select current_user::text" []);
  Pg.close t;
  (match connect_with env sw { c with ssl_cert = None; ssl_key = None } with
  | Error (Pg.Server _) -> ()
  | _ -> Alcotest.fail "the server let in a client with no certificate");
  refused_saying "an encrypted key" "encrypted"
    (connect_with env sw
       { c with ssl_key = Some "postgres/client-encrypted.key" });
  refused_saying "a certificate with no key" "come together"
    (connect_with env sw { c with ssl_key = None })

(* Multiple hosts with one refusing; random order varies. *)
let several_hosts () =
  with_eio @@ fun env sw ->
  let c =
    {
      (plain ()) with
      hosts = [ endpoint ~port:1 "127.0.0.1"; endpoint "localhost" ];
    }
  in
  let t = connect env sw c in
  Alcotest.(check string)
    "the second, since the first refuses" "1" (one t "select 1" []);
  Pg.close t;
  let a, taken_a = a_fake_postgres env sw () in
  let b, taken_b = a_fake_postgres env sw () in
  let both =
    {
      (plain ()) with
      hosts = [ endpoint ~port:a "127.0.0.1"; endpoint ~port:b "127.0.0.1" ];
    }
  in
  for _ = 1 to 10 do
    Pg.close (connect env sw both)
  done;
  Alcotest.(check (pair int int))
    "in order, the first every time" (10, 0) (!taken_a, !taken_b);
  let application's = Random.get_state () in
  for _ = 1 to 30 do
    Pg.close (connect env sw { both with load_balance_hosts = Random })
  done;
  Alcotest.(check bool) "at random, both" true (!taken_a > 10 && !taken_b > 0);
  (* The stdlib's generator starts from a fixed seed in every process, so
     shuffling with it would send every client to the same host first. *)
  Alcotest.(check int)
    "the application's generator untouched"
    (Random.State.bits application's)
    (Random.bits ())

(* Regression: a refused address's socket is closed at once, not held on
   the switch. With [::1] refused by an IPv4-only port forward, every
   connection leaked a descriptor until the process ran out. *)
let a_refused_address_leaves_no_socket () =
  with_eio @@ fun env sw ->
  let c =
    {
      (plain ()) with
      hosts = [ endpoint ~port:1 "127.0.0.1"; endpoint "localhost" ];
    }
  in
  let open_descriptors () = Array.length (Sys.readdir "/dev/fd") in
  let before = open_descriptors () in
  for _ = 1 to 20 do
    Pg.close (connect env sw c)
  done;
  Alcotest.(check int) "no descriptor left behind" before (open_descriptors ())

(* target_session_attrs: read-write skips a standby; standby finds one. *)
let the_kind_of_host_asked_for () =
  with_eio @@ fun env sw ->
  let standby, _ =
    a_fake_postgres env sw
      ~reported:
        [ ("in_hot_standby", "on"); ("default_transaction_read_only", "on") ]
      ()
  in
  let silent, _ = a_fake_postgres env sw () in
  let primary = endpoint "localhost" in
  let standing (t : Pg.t) =
    Option.value (Pg.parameter t "in_hot_standby") ~default:"?"
  in
  let at_hosts hosts attrs =
    { (plain ()) with hosts; target_session_attrs = attrs }
  in
  let reached hosts attrs =
    let t = connect env sw (at_hosts hosts attrs) in
    let s = standing t in
    Pg.close t;
    s
  in
  let standby = endpoint ~port:standby "127.0.0.1" in
  Alcotest.(check string)
    "read-write skips the standby" "off"
    (reached [ standby; primary ] Read_write);
  Alcotest.(check string)
    "primary too" "off"
    (reached [ standby; primary ] Primary);
  Alcotest.(check string)
    "standby, wherever it is" "on"
    (reached [ primary; standby ] Standby);
  Alcotest.(check string)
    "read-only takes a standby" "on"
    (reached [ standby; primary ] Read_only);
  Alcotest.(check string)
    "prefer-standby, with none, takes any" "off"
    (reached [ primary ] Prefer_standby);
  Alcotest.(check string)
    "prefer-standby, with one" "on"
    (reached [ primary; standby ] Prefer_standby);
  refused_saying "standby, with none" "target_session_attrs=standby"
    (connect_with env sw (at_hosts [ primary ] Standby));
  refused_saying "a server that does not say" "does not say"
    (connect_with env sw
       (at_hosts [ endpoint ~port:silent "127.0.0.1" ] Read_write))

let protocol_3_2 () =
  with_eio @@ fun env sw ->
  let t = connect env sw { (plain ()) with max_protocol_version = V3_2 } in
  Alcotest.(check string) "54.2.1 3.2 agreed" "1" (one t "select 1" []);
  cancelled env t;
  Pg.close t;
  (* A 3.0-only server downgrades the connection, unless min is 3.2. *)
  let port, _ =
    a_fake_postgres env sw ~before:(msg 'v' (int32 0 ^ int32 0)) ()
  in
  let asked = { (fake port) with max_protocol_version = V3_2 } in
  Pg.close (connect env sw asked);
  refused_saying "54.2.1 below min_protocol_version" "below"
    (connect_with env sw { asked with min_protocol_version = V3_2 })

let options_become_settings () =
  with_eio @@ fun env sw ->
  let c = { (plain ()) with options = [ ("search_path", "pgeio_options") ] } in
  let t = connect env sw c in
  Alcotest.(check string)
    "sent at start-up" "pgeio_options"
    (one t "show search_path" []);
  Pg.close t;
  let t = connect env sw ~parameters:[ ("search_path", "the_callers") ] c in
  Alcotest.(check string)
    "the caller's parameter wins" "the_callers"
    (one t "show search_path" []);
  Pg.close t

(* PG* variables are ignored without [~defaults]. *)
let nothing_from_the_environment_unasked () =
  with_eio @@ fun env sw ->
  List.iter
    (fun (k, v) -> Unix.putenv k v)
    [
      ("PGHOST", "nowhere.invalid");
      ("PGPASSWORD", "wrong");
      ("PGDATABASE", "nonesuch");
    ];
  let t =
    connect env sw
      (match Conninfo.of_string (Option.value target ~default:"") with
      | Ok c -> { c with ssl_mode = Disable }
      | Error e -> Alcotest.fail e)
  in
  Alcotest.(check string)
    "the string's database" "postgres_eio"
    (one t "select current_database()::text" []);
  Pg.close t;
  List.iter (fun k -> Unix.putenv k "") [ "PGHOST"; "PGPASSWORD"; "PGDATABASE" ]

let a_password_from_a_passfile () =
  with_eio @@ fun env sw ->
  make_role env sw "pgeio_pass" (Some "from the file");
  let c =
    Conninfo.passfile
      (Printf.sprintf
         "# not this\n\
          other:*:*:*:wrong\n\
          localhost:%d:*:pgeio_pass:from the file\n"
         (port_of (base ())))
      (as_role (plain ()) "pgeio_pass" None)
  in
  let t = connect env sw c in
  Alcotest.(check string)
    "signed in" "pgeio_pass"
    (one t "select current_user::text" []);
  Pg.close t

(* SASLprep agrees with the server's: equivalent passwords sign in, and
   ones preparation refuses are used as bytes on both sides. *)
let saslprep_as_the_server_does () =
  with_eio @@ fun env sw ->
  let sign_in role password =
    match connect_with env sw (as_role (plain ()) role (Some password)) with
    | Ok t ->
        Pg.close t;
        true
    | Error _ -> false
  in
  make_role env sw "pgeio_prep" (Some "IX");
  List.iter
    (fun (what, password, expected) ->
      Alcotest.(check bool) what expected (sign_in "pgeio_prep" password))
    [
      ("as set", "IX", true);
      ("a soft hyphen, mapped to nothing", "I\xc2\xadX", true);
      ("ROMAN NUMERAL NINE, IX under NFKC", "\xe2\x85\xa8", true);
      ("a non-ASCII space before, as a space", "\xc2\xa0IX", false);
      ("a wrong one", "IY", false);
    ];
  (* Mixed directions, or a control character among non-ASCII ones. *)
  let admin = connect env sw (plain ()) in
  List.iter
    (fun (role, literal, password) ->
      script admin (Printf.sprintf "drop role if exists %s" role);
      script admin
        (Printf.sprintf "create role %s login password E'%s'" role literal);
      Alcotest.(check bool) role true (sign_in role password))
    [
      ("pgeio_bidi", "\\u05d0a", "\xd7\x90a");
      ("pgeio_control", "a\\u0007\\u00e9", "a\x07\xc3\xa9");
    ];
  Pg.close admin

(* LISTEN/NOTIFY *)

let listener ?heartbeat_s ?timeout_s env sw c =
  ok_pg
    (Pg.Listener.connect ~sw ~net:(Eio.Stdenv.net env)
       ~clock:(Eio.Stdenv.mono_clock env)
       ?heartbeat_s ?timeout_s c)

(* Fails after [within] seconds instead of hanging. *)
let next_within env ?(within = 5.) l =
  Eio.Fiber.first
    (fun () -> Pg.Listener.next l)
    (fun () ->
      Eio.Time.Mono.sleep (Eio.Stdenv.mono_clock env) within;
      Alcotest.failf "no event within %gs" within)

let heard env ?within l =
  match next_within env ?within l with
  | Ok (Pg.Listener.Notification n) -> n
  | Ok Pg.Listener.Reconnected ->
      Alcotest.fail "a reconnection, not a notification"
  | Error e -> Alcotest.failf "%s" (Pg.error_to_string e)

let reconnected env ?within l =
  match next_within env ?within l with
  | Ok Pg.Listener.Reconnected -> ()
  | Ok (Pg.Listener.Notification n) -> Alcotest.failf "heard %S" n.payload
  | Error e -> Alcotest.failf "%s" (Pg.error_to_string e)

let notify t channel payload = ok_pg (Pg.notify t ~channel payload)

let terminate_by_name admin name =
  script admin
    (Printf.sprintf
       "select pg_terminate_backend(pid) from pg_stat_activity where \
        application_name = '%s'"
       name)

(* A proxy that can go silent, simulating a dropped network path: open
   connections stop passing bytes without closing. New ones work. *)
let a_proxy env sw =
  let listener =
    Eio.Net.listen ~sw ~backlog:4 (Eio.Stdenv.net env)
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr listener with `Tcp (_, p) -> p | `Unix _ -> 0
  in
  let open_ones = ref [] in
  let target = base () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Net.run_server listener ~on_error:ignore (fun client _ ->
          let silent = ref false in
          open_ones := silent :: !open_ones;
          Eio.Switch.run @@ fun sw ->
          let server =
            Eio.Net.connect ~sw (Eio.Stdenv.net env)
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, port_of target))
          in
          let pass from into () =
            let buf = Cstruct.create 4096 in
            try
              while true do
                let n = Eio.Flow.single_read from buf in
                if !silent then Eio.Fiber.await_cancel ()
                else Eio.Flow.write into [ Cstruct.sub buf 0 n ]
              done
            with End_of_file | Eio.Io _ -> ()
          in
          Eio.Fiber.first (pass client server) (pass server client)));
  let silence () = List.iter (fun s -> s := true) !open_ones in
  (port, silence)

let a_notification_committed_and_not_rolled_back () =
  with_eio @@ fun env sw ->
  let l = listener env sw (plain ()) in
  ok_pg (Pg.Listener.listen l "pgeio_jobs");
  let n = connect env sw (plain ()) in
  script n "begin";
  notify n "pgeio_jobs" "rolled back";
  script n "rollback";
  script n "begin";
  notify n "pgeio_jobs" "committed";
  script n "commit";
  let got = heard env l in
  Alcotest.(check (list string))
    "54.2.7 only the one that committed"
    [ "pgeio_jobs"; "committed"; one n "select pg_backend_pid()::text" [] ]
    [ got.channel; got.payload; string_of_int got.pid ];
  Pg.Listener.close l;
  Pg.close n

let a_channel_is_its_exact_name () =
  with_eio @@ fun env sw ->
  let l = listener env sw (plain ()) in
  ok_pg (Pg.Listener.listen l "Pgeio_Exact");
  let n = connect env sw (plain ()) in

  script n "notify Pgeio_Exact, 'folded'";
  notify n "Pgeio_Exact" "exact";
  Alcotest.(check string) "the quoted name" "exact" (heard env l).payload;
  ok_pg (Pg.Listener.unlisten l "Pgeio_Exact");
  ok_pg (Pg.Listener.listen l "pgeio_after");
  notify n "Pgeio_Exact" "unheard";
  notify n "pgeio_after" "after";
  Alcotest.(check string)
    "and not once unlistened" "after" (heard env l).payload;
  Pg.Listener.close l;
  Pg.close n

(* A notification arriving during LISTEN is kept for [next]. *)
let what_arrives_during_a_listen_is_kept () =
  with_eio @@ fun env sw ->
  let l = listener env sw (plain ()) in
  ok_pg (Pg.Listener.listen l "pgeio_a");
  let n = connect env sw (plain ()) in
  notify n "pgeio_a" "early";
  Eio.Time.Mono.sleep (Eio.Stdenv.mono_clock env) 0.2;
  ok_pg (Pg.Listener.listen l "pgeio_b");
  Alcotest.(check string) "kept" "early" (heard env ~within:1. l).payload;
  Pg.Listener.close l;
  Pg.close n

let a_killed_backend_is_a_reconnection () =
  with_eio @@ fun env sw ->
  let l =
    listener env sw { (plain ()) with application_name = Some "pgeio-killed" }
  in
  ok_pg (Pg.Listener.listen l "pgeio_killed");
  let admin = connect env sw (plain ()) in
  terminate_by_name admin "pgeio-killed";
  reconnected env l;
  notify admin "pgeio_killed" "after";
  Alcotest.(check string)
    "listening again, it hears what is sent after" "after" (heard env l).payload;
  Pg.Listener.close l;
  Pg.close admin

(* A silent network is detected within heartbeat + timeout, and the
   listener reconnects. *)
let a_silent_network_is_found () =
  with_eio @@ fun env sw ->
  let port, silence = a_proxy env sw in
  let c = at ~port (Tcp "127.0.0.1") (plain ()) in
  let l = listener ~heartbeat_s:0.3 ~timeout_s:0.5 env sw c in
  ok_pg (Pg.Listener.listen l "pgeio_silent");
  let clock = Eio.Stdenv.mono_clock env in
  silence ();
  let started = Eio.Time.Mono.now clock in
  reconnected env l;
  let took = seconds_since clock started in
  if took > 0.3 +. 0.5 +. 0.5 then
    Alcotest.failf "found after %.2fs, past the heartbeat and the timeout" took;
  let n = connect env sw (plain ()) in
  notify n "pgeio_silent" "after";
  Alcotest.(check string) "and hears again" "after" (heard env l).payload;
  Pg.Listener.close l;
  Pg.close n

(* A listener survives several silent heartbeats, over TLS too: a
   heartbeat must not cancel a TLS read, which tls-eio would re-raise on the
   next write. *)
let a_quiet_listener_outlives_its_heartbeats () =
  with_eio @@ fun env sw ->
  List.iter
    (fun (said, c) ->
      let l = listener ~heartbeat_s:0.2 env sw c in
      ok_pg (Pg.Listener.listen l "pgeio_quiet");
      let n = connect env sw (plain ()) in
      Eio.Fiber.both
        (fun () ->
          Alcotest.(check string)
            (said ^ ": heard after five heartbeats")
            "after" (heard env ~within:5. l).payload)
        (fun () ->
          Eio.Time.Mono.sleep (Eio.Stdenv.mono_clock env) 1.;
          notify n "pgeio_quiet" "after");
      Pg.Listener.close l;
      Pg.close n)
    [
      ("over TLS", { (base ()) with ssl_mode = Require });
      ("in the clear", plain ());
    ]

(* A password changed while disconnected is returned, not retried. *)
let a_refused_sign_in_is_returned () =
  with_eio @@ fun env sw ->
  make_role env sw "pgeio_listener" (Some "first");
  let l =
    listener env sw
      {
        (as_role (plain ()) "pgeio_listener" (Some "first")) with
        application_name = Some "pgeio-refused";
      }
  in
  ok_pg (Pg.Listener.listen l "pgeio_refused");
  let admin = connect env sw (plain ()) in
  script admin "alter role pgeio_listener password 'second'";
  terminate_by_name admin "pgeio-refused";
  (match next_within env ~within:2. l with
  | Error (Pg.Server e) ->
      Alcotest.(check string)
        "the server's refusal" "28P01"
        (Pg.Server_error.sqlstate e)
  | Ok _ -> Alcotest.fail "reconnected with the old password"
  | Error e -> Alcotest.failf "not the refusal: %s" (Pg.error_to_string e));
  Pg.Listener.close l;
  Pg.close admin

let a_payload_past_the_limit () =
  with_eio @@ fun env sw ->
  let l = listener env sw (plain ()) in
  ok_pg (Pg.Listener.listen l "pgeio_long");
  let n = connect env sw (plain ()) in
  notify n "pgeio_long" (String.make 7999 'x');
  Alcotest.(check int)
    "7999 bytes arrive" 7999
    (String.length (heard env l).payload);
  Pg.close n;
  (match Pg.notify n ~channel:"pgeio_long" (String.make 8000 'x') with
  | Error (Pg.Refused m) -> Alcotest.(check bool) m true (contains m "8000")
  | _ -> Alcotest.fail "8000 bytes were not refused before sending");
  Pg.Listener.close l;
  match Pg.Listener.next l with
  | Error Pg.Closed -> ()
  | _ -> Alcotest.fail "a closed listener did not say so"

(* Statements and pipelining *)

(* The server's count of our prepared statements, including this query's
   own when the cache is on. *)
let ours t =
  let n =
    rows t
      "select count(*)::text from pg_prepared_statements where name like \
       'postgres_eio_%'"
      []
  in
  match n with
  | [ [ Some n ] ] -> int_of_string n
  | _ -> Alcotest.fail "a count"

let connect_cached ?statement_cache ?timeout_s env sw c =
  ok_pg
    (Pg.connect ~sw ~net:(Eio.Stdenv.net env)
       ~clock:(Eio.Stdenv.mono_clock env)
       ?statement_cache ?timeout_s c)

let value t sql params =
  match rows t sql params with
  | [ [ Some v ] ] -> v
  | _ -> Alcotest.failf "%s: not one value" sql

let a_statement_is_parsed_once () =
  with_eio @@ fun env sw ->
  let t = connect_cached env sw (plain ()) in
  Alcotest.(check string)
    "first" "2"
    (value t "select $1::int + 1" [ Some "1" ]);
  Alcotest.(check string)
    "again" "3"
    (value t "select $1::int + 1" [ Some "2" ]);
  Alcotest.(check (list string))
    "54.2.3 one named statement, holding the text" [ "select $1::int + 1" ]
    (List.map
       (function [ Some s ] -> s | _ -> "?")
       (rows t
          "select statement from pg_prepared_statements where name like \
           'postgres_eio_%' and statement not like '%pg_prepared_statements%'"
          []));
  ok_pg (Pg.reset t);
  Alcotest.(check int) "after a reset, only the query asking" 1 (ours t);
  Pg.close t

let the_cache_is_sized_or_off () =
  with_eio @@ fun env sw ->
  let t = connect_cached ~statement_cache:2 env sw (plain ()) in
  List.iter
    (fun n -> ignore (value t (Printf.sprintf "select %d" n) []))
    [ 1; 2; 3; 4; 5 ];
  Alcotest.(check int) "54.2.3 the least recently used are closed" 2 (ours t);
  Alcotest.(check int) "its size, as made" 2 (Pg.statement_cache t);
  Pg.close t;
  let t = connect_cached ~statement_cache:0 env sw (plain ()) in
  Alcotest.(check string) "off, it still answers" "1" (value t "select 1" []);
  Alcotest.(check string) "and again" "1" (value t "select 1" []);
  Alcotest.(check int) "and parses nothing to keep" 0 (ours t);
  Alcotest.(check int) "its size, none" 0 (Pg.statement_cache t);
  Pg.close t

(* A cached statement whose result type changed is reparsed outside a
   transaction; inside one, the error is returned. *)
let a_stale_plan () =
  with_eio @@ fun env sw ->
  let t = connect_cached env sw (plain ()) in
  script t "create temp table s (a int); insert into s values (1)";
  let width () =
    match
      Pg.query t "select * from s" ~params:[] ~init:0 ~row:(fun _ cells ->
          Array.length cells)
    with
    | Ok (n, _) -> Ok n
    | Error e -> Error e
  in
  Alcotest.(check (result int reject)) "before" (Ok 1) (width ());
  script t "alter table s add column b int";
  Alcotest.(check (result int reject))
    "outside a transaction, parsed again and run" (Ok 2) (width ());
  script t "begin";
  script t "alter table s add column c int";
  (match width () with
  | Error (Pg.Server e) ->
      Alcotest.(check string)
        "inside one, the error" "0A000"
        (Pg.Server_error.sqlstate e)
  | _ -> Alcotest.fail "a stale plan inside a transaction was hidden");
  script t "rollback";
  Alcotest.(check (result int reject)) "and after" (Ok 2) (width ());
  Pg.close t

let the_columns_before_any_row () =
  with_eio @@ fun env sw ->
  List.iter
    (fun statement_cache ->
      let t = connect_cached ~statement_cache env sw (plain ()) in
      let seen = ref [] in
      let columns cs =
        seen :=
          Array.to_list
            (Array.map
               (fun (c : Pg.Column.t) ->
                 Printf.sprintf "%s/%d/%s" c.name (Pg.Oid.to_int c.type_oid)
                   (match c.format with Text -> "text" | Binary -> "binary"))
               cs)
          :: !seen
      in
      let run () =
        ok_pg
          (Pg.query t "select 1 as one, 'x'::text as two where $1" ~columns
             ~params:[ Some "false" ] ~init:0 ~row:(fun n _ -> n + 1))
      in
      ignore (run ());
      ignore (run ());
      Alcotest.(check (list (list string)))
        (Printf.sprintf "54.2.3 told twice, with no rows (cache %d)"
           statement_cache)
        [ [ "one/23/text"; "two/25/text" ]; [ "one/23/text"; "two/25/text" ] ]
        !seen;
      let told = ref false in
      ignore
        (ok_pg
           (Pg.query t "create temp table z (n int)" ~params:[]
              ~columns:(fun cs ->
                told := true;
                Alcotest.(check int) "none" 0 (Array.length cs))
              ~init:()
              ~row:(fun () _ -> ())));
      Alcotest.(check bool) "and told for a statement with no result" true !told;
      Pg.close t)
    [ 256; 0 ]

(* A failure at row 7,000 of 10,000 leaves none inserted. *)
let a_batch () =
  with_eio @@ fun env sw ->
  let t = connect_cached env sw (plain ()) in
  script t "create temp table b (n int primary key)";
  let rows ?(bad = -1) () =
    List.init 10_000 (fun i ->
        [ Some (if i = bad then "not a number" else string_of_int i) ])
  in
  let tags =
    ok_pg (Pg.execute_many t "insert into b values ($1)" ~params:(rows ()))
  in
  Alcotest.(check int) "a tag a row" 10_000 (List.length tags);
  Alcotest.(check bool)
    "each one row" true
    (List.for_all (fun tag -> Pg.Tag.rows tag = Some 1) tags);
  Alcotest.(check int) "all of them" 10_000 (count t "b");
  script t "delete from b";
  (match
     Pg.execute_many t "insert into b values ($1)" ~params:(rows ~bad:7_000 ())
   with
  | Error (Pg.Server e) ->
      Alcotest.(check string)
        "row 7,000's refusal" "22P02"
        (Pg.Server_error.sqlstate e)
  | _ -> Alcotest.fail "the batch did not fail");
  Alcotest.(check int)
    "54.2.3 one implicit transaction: none of them" 0 (count t "b");
  in_step t;
  Alcotest.(check (result (list reject) reject))
    "no rows, nothing sent" (Ok [])
    (Pg.execute_many t "insert into b values ($1)" ~params:[]);
  Pg.close t

let answer_int = function
  | Ok (v, _) -> Ok v
  | Error e -> Error (Pg.error_to_string e)

let one_value acc cells = match cells with [| Some v |] -> v :: acc | _ -> acc

(* A failing pipelined statement does not stop the next. *)
let a_pipeline () =
  with_eio @@ fun env sw ->
  let t = connect_cached env sw (plain ()) in
  let q sql = Pg.Pipeline.query t sql ~params:[] ~init:[] ~row:one_value in
  let a = q "select 'a'" and b = q "select 1/0" and c = q "select 'c'" in
  Alcotest.(check (result (list string) string))
    "a" (Ok [ "a" ])
    (answer_int (Pg.Pipeline.get a));
  (match Pg.Pipeline.get b with
  | Error (Pg.Server e) ->
      Alcotest.(check string)
        "b's own error" "22012"
        (Pg.Server_error.sqlstate e)
  | _ -> Alcotest.fail "b did not fail");
  Alcotest.(check (result (list string) string))
    "54.2.4 and c still ran" (Ok [ "c" ])
    (answer_int (Pg.Pipeline.get c));
  (* Inside a transaction, the failure aborts it. *)
  script t "create temp table p (n int)";
  let answers =
    List.map q
      [
        "begin";
        "insert into p values (1)";
        "select 1/0";
        "insert into p values (2)";
        "commit";
      ]
  in
  (match List.rev_map Pg.Pipeline.get answers with
  | Ok (_, commit) :: Error (Pg.Server e) :: _ ->
      Alcotest.(check string)
        "after the failure, refused" "25P02"
        (Pg.Server_error.sqlstate e);
      Alcotest.(check string)
        "and the commit rolled back" "ROLLBACK" (Pg.Tag.command commit)
  | _ -> Alcotest.fail "the transaction did not fail as it would one at a time");
  Alcotest.(check int) "nothing inserted" 0 (count t "p");
  in_step t;
  Pg.close t

(* Getting the second answer first reads the first on the way. *)
let answers_asked_for_out_of_order () =
  with_eio @@ fun env sw ->
  let t = connect_cached env sw (plain ()) in
  let first_ran = ref false in
  let a =
    Pg.Pipeline.query t "select 1" ~params:[] ~init:[] ~row:(fun acc cells ->
        first_ran := true;
        one_value acc cells)
  in
  let b = Pg.Pipeline.query t "select 2" ~params:[] ~init:[] ~row:one_value in
  Alcotest.(check (result (list string) string))
    "the second" (Ok [ "2" ])
    (answer_int (Pg.Pipeline.get b));
  Alcotest.(check bool) "the first read on the way" true !first_ran;
  Alcotest.(check (result (list string) string))
    "the first, its own" (Ok [ "1" ])
    (answer_int (Pg.Pipeline.get a));

  let c = Pg.Pipeline.query t "select 3" ~params:[] ~init:[] ~row:one_value in
  Alcotest.(check string) "a query behind it" "4" (value t "select 4" []);
  Alcotest.(check (result (list string) string))
    "54.2.4 and the answer ahead was read, not lost" (Ok [ "3" ])
    (answer_int (Pg.Pipeline.get c));
  Pg.close t

(* An unparseable statement used twice in a pipeline: the second use
   reports the parse error, not "does not exist". *)
let a_refused_parse_down_a_pipeline () =
  with_eio @@ fun env sw ->
  let t = connect_cached env sw (plain ()) in
  let q () =
    Pg.Pipeline.query t "selec 1" ~params:[] ~init:() ~row:(fun () _ -> ())
  in
  let a = q () and b = q () in
  List.iter
    (fun (what, answer) ->
      match Pg.Pipeline.get answer with
      | Error (Pg.Server e) ->
          Alcotest.(check string) what "42601" (Pg.Server_error.sqlstate e)
      | _ -> Alcotest.failf "%s was not refused" what)
    [ ("the first", a); ("the second", b) ];
  Alcotest.(check int) "and nothing kept but the query asking" 1 (ours t);
  in_step t;
  Pg.close t

let a_caller's_discard_empties_the_cache () =
  with_eio @@ fun env sw ->
  let t = connect_cached env sw (plain ()) in
  Alcotest.(check string) "cached" "1" (value t "select 1" []);
  script t "discard all";
  Alcotest.(check string) "after DISCARD ALL" "1" (value t "select 1" []);
  script t "deallocate all";
  Alcotest.(check string) "after DEALLOCATE ALL" "1" (value t "select 1" []);
  Alcotest.(check string) "and another" "2" (value t "select 2" []);
  script t
    ("deallocate "
    ^ value t
        "select name from pg_prepared_statements where statement = 'select 1'"
        []);
  Alcotest.(check string) "after one DEALLOCATE" "1" (value t "select 1" []);
  Alcotest.(check string) "and the other" "2" (value t "select 2" []);
  Pg.close t

(* 100,000 statements with large answers pipelined without deadlock. *)
let a_long_pipeline_completes () =
  with_eio @@ fun env sw ->
  let t = connect_cached env sw (plain ()) in
  let n = 100_000 in
  let answers =
    List.init n (fun i ->
        Pg.Pipeline.query t "select $1::int, repeat('x', 1000)"
          ~params:[ Some (string_of_int i) ]
          ~init:0
          ~row:(fun acc _ -> acc + 1))
  in
  (match List.rev answers with
  | last :: _ ->
      Alcotest.(check (result int string))
        "54.2.4 the last" (Ok 1)
        (answer_int (Pg.Pipeline.get last))
  | [] -> Alcotest.fail "no answers");
  Alcotest.(check int)
    "and every one before it" n
    (List.fold_left
       (fun sum a ->
         match Pg.Pipeline.get a with Ok (k, _) -> sum + k | Error _ -> sum)
       0 answers);
  Pg.close t

(* A fake server that answers each statement with a [size]-byte row and
   each CopyData with a [size]-byte notice, and stops reading while it
   writes. Direct on loopback: Docker's proxy buffers enough to hide a
   write-before-read deadlock. *)
let a_server_that_answers_big env sw ~size =
  let listener =
    Eio.Net.listen ~sw ~backlog:4 (Eio.Stdenv.net env)
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr listener with `Tcp (_, p) -> p | `Unix _ -> 0
  in
  let big = String.make size 'x' in
  let notice = msg 'N' ("S" ^ cstr "NOTICE" ^ "M" ^ cstr big ^ "\000") in
  let described =
    msg '1' ""
    ^ msg 't' (int16 0)
    ^ msg 'T'
        (int16 1 ^ cstr "x" ^ int32 0 ^ int16 0 ^ int32 25 ^ int16 0xffff
       ^ int32 (-1) ^ int16 0)
  in
  let answer =
    msg 'D' (int16 1 ^ int32 size ^ big) ^ msg 'C' (cstr "SELECT 1")
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Net.accept_fork ~sw listener ~on_error:ignore (fun flow _ ->
          let r = Eio.Buf_read.of_flow flow ~max_size:(1 lsl 24) in
          let take_int32 () =
            Int32.to_int (String.get_int32_be (Eio.Buf_read.take 4 r) 0)
          in
          let write s = Eio.Flow.copy_string s flow in
          ignore (Eio.Buf_read.take (take_int32 () - 4) r);
          write (msg 'R' (int32 0) ^ msg 'Z' "I");
          let rec statements ~parsed ~copy =
            let kind = Eio.Buf_read.any_char r in
            let body = Eio.Buf_read.take (take_int32 () - 4) r in
            match kind with
            | 'P' ->
                statements ~parsed:true
                  ~copy:(contains (String.lowercase_ascii body) "copy")
            | 'S' when copy ->
                write (msg '1' "" ^ msg '2' "" ^ msg 'G' ("\000" ^ int16 0));
                copying 0
            | 'S' ->
                write
                  ((if parsed then described else msg '2' "")
                  ^ answer ^ msg 'Z' "I");
                statements ~parsed:false ~copy:false
            | 'X' -> ()
            | _ -> statements ~parsed ~copy
          and copying n =
            let kind = Eio.Buf_read.any_char r in
            ignore (Eio.Buf_read.take (take_int32 () - 4) r);
            match kind with
            | 'd' ->
                write notice;
                copying (n + 1)
            | 'c' | 'f' -> copied n
            | _ -> copying n
          and copied n =
            let kind = Eio.Buf_read.any_char r in
            ignore (Eio.Buf_read.take (take_int32 () - 4) r);
            match kind with
            | 'S' ->
                write (msg 'C' (cstr (Printf.sprintf "COPY %d" n)) ^ msg 'Z' "I");
                statements ~parsed:false ~copy:false
            | _ -> copied n
          in
          try statements ~parsed:false ~copy:false
          with End_of_file | Eio.Io _ -> ());
      `Stop_daemon);
  { (at ~port (Tcp "127.0.0.1") (plain ())) with password = None }

(* A pipeline and a COPY far larger than the socket buffers, against a
   server that stops reading while writing: writing before reading would
   deadlock. *)
let longer_than_the_buffers () =
  with_eio @@ fun env sw ->
  let size = 16384 in
  let c = a_server_that_answers_big env sw ~size in
  let t = connect_cached ~timeout_s:2. env sw c in
  let param = Some (String.make size 'p') in
  let answers =
    List.init 2000 (fun _ ->
        Pg.Pipeline.query t "select $1" ~params:[ param ] ~init:0
          ~row:(fun n _ -> n + 1))
  in
  Alcotest.(check (result int string))
    "54.2.4 two thousand answers, each read" (Ok 2000)
    (List.fold_left
       (fun sum a ->
         match (sum, Pg.Pipeline.get a) with
         | Ok sum, Ok (n, _) -> Ok (sum + n)
         | Error e, _ -> Error e
         | Ok _, Error e -> Error (Pg.error_to_string e))
       (Ok 0) answers);
  let rows = Seq.init 200_000 (fun _ -> [| Some (String.make 100 'r') |]) in
  (match Pg.copy_in_rows t ~table:"any" ~columns:[] rows with
  | Ok tag ->
      Alcotest.(check bool)
        "54.2.6 a COPY answered as it went" true
        (Option.is_some (Pg.Tag.rows tag))
  | Error e -> Alcotest.failf "the COPY: %s" (Pg.error_to_string e));
  Pg.close t

(* A trigger notice per COPY row is read while writing; a refused COPY
   stops sending. *)
let a_copy_the_server_answers_as_it_goes () =
  with_eio @@ fun env sw ->
  let t = connect_cached env sw (plain ()) in
  script t
    "create temp table noisy (n int);\n\
     create function pg_temp.say() returns trigger language plpgsql as $$ \
     begin raise notice '%', repeat('n', 500); return new; end $$;\n\
     create trigger say before insert on noisy for each row execute function \
     pg_temp.say()";
  let rows = Seq.init 200_000 (fun i -> [| Some (string_of_int i) |]) in
  Alcotest.(check (option int))
    "54.2.6 every row, every notice read" (Some 200_000)
    (Pg.Tag.rows
       (ok_pg (Pg.copy_in_rows t ~table:"noisy" ~columns:[ "n" ] rows)));
  script t "create temp table strict (n int)";
  let pulled = ref 0 in
  let rows =
    Seq.init 1_000_000 (fun i ->
        incr pulled;
        [| Some (if i = 1 then "two" else string_of_int i) |])
  in
  (match Pg.copy_in_rows t ~table:"strict" ~columns:[ "n" ] rows with
  | Error (Pg.Server _) -> ()
  | _ -> Alcotest.fail "the refusal was not returned");
  if !pulled >= 1_000_000 then
    Alcotest.fail "every row was sent after the server refused the second";
  in_step t;
  Pg.close t

(* A row function slower than the timeout does not time out. *)
let a_slow_row_function_is_not_timed () =
  with_eio @@ fun env sw ->
  let t = connect_cached ~timeout_s:0.2 env sw (plain ()) in
  let clock = Eio.Stdenv.mono_clock env in
  (match
     Pg.query t "select generate_series(1, 3)" ~params:[] ~init:0
       ~row:(fun n _ ->
         Eio.Time.Mono.sleep clock 0.3;
         n + 1)
   with
  | Ok (3, _) -> ()
  | Ok _ -> Alcotest.fail "rows lost"
  | Error e -> Alcotest.failf "%s" (Pg.error_to_string e));
  (match
     Pg.query t "select pg_sleep(1)" ~params:[] ~init:() ~row:(fun () _ -> ())
   with
  | Error Pg.Timeout -> ()
  | _ -> Alcotest.fail "a server slower than the timeout was waited for");
  Alcotest.(check bool) "and that closed it" true (Pg.closed t)

(* Binary results *)

module Value = Postgres_eio.Value

(* Every type [Value] reads, at its edges, one line per cell. *)
let every_type =
  [
    ("true", "bool");
    ("false", "bool");
    ("'-32768'", "int2");
    ("'-2147483648'", "int4");
    ("4611686018427387903", "int8");
    ("9223372036854775807", "int8");
    ("4294967295", "oid");
    ("0.1", "float4");
    ("3.4028235e38", "float4");
    ("0.1", "float8");
    ("'NaN'", "float8");
    ("'-Infinity'", "float8");
    ("'-0.0'", "float8");
    ("1e-310", "float8");
    ("'text'", "text");
    ("'var char'", "varchar");
    ("'\\x00ff5c'", "bytea");
    ("'0190C0FE-1234-7ABC-8DEF-0123456789AB'", "uuid");
    ("'2026-09-27'", "date");
    ("'0001-01-01'", "date");
    ("'9999-12-31'", "date");
    ("'infinity'", "date");
    ("'2026-09-27 10:00:00.123456'", "timestamp");
    ("'2026-09-27 10:00:00.123456+02'", "timestamptz");
    ("'1900-01-01 00:00:00+00'", "timestamptz");
    ("'infinity'", "timestamptz");
    ("'1 year 2 mons -3 days 04:05:06.789'", "interval");
    ("'-178000000 years'", "interval");
    ("'0'", "interval");
    ({|'{"a": [1, 2.5], "b": null}'|}, "json");
    ({|'{"b": null, "a": [1, 2.5]}'|}, "jsonb");
    ("null", "int4");
  ]

let decoded (c : Pg.Column.t) cell =
  let show f = function Some v -> f v | None -> "-" in
  match cell with
  | None -> "NULL"
  | Some s -> (
      let text = show Fun.id (Value.text c s) in
      match Pg.Oid.to_int c.type_oid with
      | 16 -> show string_of_bool (Value.bool c s)
      | 20 | 21 | 23 | 26 ->
          show string_of_int (Value.int c s)
          ^ " "
          ^ show Int64.to_string (Value.int64 c s)
          ^ " " ^ text
      | 700 | 701 -> show (Printf.sprintf "%h") (Value.float c s)
      | 17 -> show hex (Value.bytes c s)
      | 25 | 1043 -> text
      | 2950 -> show Uuidm.to_string (Value.uuid c s) ^ " " ^ text
      | 1082 ->
          show
            (fun (y, m, d) -> Printf.sprintf "%04d-%02d-%02d" y m d)
            (Value.date c s)
      | 1114 -> show (fun t -> string_of_int (us_of t)) (Value.timestamp c s)
      | 1184 -> show (fun t -> string_of_int (us_of t)) (Value.timestamptz c s)
      | 1186 ->
          show
            (fun (i : Postgres_eio.Interval.t) ->
              Printf.sprintf "%d %d %d" i.months i.days i.microseconds)
            (Value.interval c s)
      | 114 | 3802 -> show Fun.id (Value.json c s) ^ " " ^ text
      | oid -> Printf.sprintf "a type %d" oid)

(* Binary and text decode to the same values for every type. *)
let binary_decodes_as_text_does () =
  with_eio @@ fun env sw ->
  let t = connect_cached env sw (plain ()) in
  let select =
    "select "
    ^ String.concat ", "
        (List.map (fun (v, ty) -> Printf.sprintf "%s::%s" v ty) every_type)
  in
  let fetch binary =
    let columns = ref [||] in
    let rows, _ =
      ok_pg
        (Pg.query t select ~binary ~params:[]
           ~columns:(fun cs -> columns := cs)
           ~init:[]
           ~row:(fun acc cells -> cells :: acc))
    in
    match rows with
    | [ cells ] ->
        ( !columns,
          Array.to_list (Array.mapi (fun i c -> decoded !columns.(i) c) cells)
        )
    | _ -> Alcotest.fail "not one row"
  in
  let text_columns, as_text = fetch false in
  let binary_columns, as_binary = fetch true in
  Alcotest.(check bool)
    "text asked, text sent" true
    (Array.for_all
       (fun (c : Pg.Column.t) ->
         match c.format with Text -> true | Binary -> false)
       text_columns);
  Alcotest.(check bool)
    "binary asked, binary sent for every one" true
    (Array.for_all
       (fun (c : Pg.Column.t) ->
         match c.format with Binary -> true | Text -> false)
       binary_columns);
  List.iteri
    (fun i ((v, ty), (text, binary)) ->
      Alcotest.(check string)
        (Printf.sprintf "%d: %s::%s, the same both ways" i v ty)
        text binary)
    (List.combine every_type (List.combine as_text as_binary));
  Pg.close t

(* Expected values, computed independently of the driver. *)
let binary_values_are_the_values () =
  with_eio @@ fun env sw ->
  let t = connect_cached env sw (plain ()) in
  let one_binary sql =
    let columns = ref [||] in
    match
      ok_pg
        (Pg.query t sql ~binary:true ~params:[]
           ~columns:(fun cs -> columns := cs)
           ~init:[]
           ~row:(fun acc cells -> cells :: acc))
    with
    | [ [| Some cell |] ], _ -> (!columns.(0), cell)
    | _ -> Alcotest.failf "%s: not one cell" sql
  in
  let c, s = one_binary "select '2026-09-27 10:00:00.123456+02'::timestamptz" in
  Alcotest.(check (option int))
    "an instant, in UTC"
    (Some (1_790_503_200_123_456 - 7_200_000_000))
    (Option.map us_of (Value.timestamptz c s));
  let c, s = one_binary "select '2026-09-27'::date" in
  Alcotest.(check (option (triple int int int)))
    "a date"
    (Some (2026, 9, 27))
    (Value.date c s);
  let c, s = one_binary "select '0190C0FE-1234-7ABC-8DEF-0123456789AB'::uuid" in
  Alcotest.(check (option string))
    "a uuid" (Some "0190c0fe-1234-7abc-8def-0123456789ab")
    (Option.map Uuidm.to_string (Value.uuid c s));
  let c, s = one_binary "select '1 mon -1 days -00:00:01.5'::interval" in
  Alcotest.(check (option interval_testable))
    "an interval, each part apart"
    (Some (interval 1 (-1) (-1_500_000)))
    (Value.interval c s);
  let c, s = one_binary "select (-9223372036854775807 - 1)::int8" in
  Alcotest.(check (option int64))
    "an int8 at its least" (Some Int64.min_int) (Value.int64 c s);
  let c, s = one_binary "select 4294967295::oid" in
  Alcotest.(check (option int64))
    "an oid, unsigned" (Some 4_294_967_295L) (Value.int64 c s);
  let c, s = one_binary "select 0.1::float4" in
  Alcotest.(check (option (float 0.)))
    "a float4, as the single it is"
    (Some (Int32.float_of_bits (Int32.bits_of_float 0.1)))
    (Value.float c s);
  Alcotest.(check (option string))
    "whose text is not the driver's to write" None (Value.text c s);
  let c, s = one_binary "select 9223372036854775807::int8" in
  Alcotest.(check (option int)) "an int8 past an int" None (Value.int c s);
  Alcotest.(check (option string))
    "but its text" (Some "9223372036854775807") (Value.text c s);
  List.iter
    (fun (sql, expected) ->
      let c, s = one_binary sql in
      Alcotest.(check (option int))
        sql expected
        (Option.map us_of
           (match Pg.Oid.to_int c.type_oid with
           | 1184 -> Value.timestamptz c s
           | _ -> Value.timestamp c s)))
    [
      ("select '0001-01-01 00:00'::timestamp", Some (-62_135_596_800_000_000));
      ( "select '9999-12-31 23:59:59.999999'::timestamp",
        Some 253_402_300_799_999_999 );
      ("select '10000-01-01 00:00'::timestamp", None);
      ("select '294000-06-01 00:00'::timestamp", None);
      ("select 'infinity'::timestamptz", None);
      ("select '-infinity'::timestamptz", None);
    ];
  let c, s = one_binary "select 'x'::char(3)" in
  Alcotest.(check bool)
    "a type not read here comes as text" true
    ((match c.format with Text -> true | Binary -> false)
    && String.equal s "x  ");
  Pg.close t

let binary_needs_the_statement_cache () =
  with_eio @@ fun env sw ->
  let t = connect_cached ~statement_cache:0 env sw (plain ()) in
  refused_saying "binary with the cache off" "statement cache"
    (Pg.query t "select 1" ~binary:true ~params:[] ~init:() ~row:(fun () _ ->
         ()));
  in_step t;
  Pg.close t;
  (* With the cache on, a stale plan is reparsed for binary too. *)
  let t = connect_cached env sw (plain ()) in
  script t "create temp table w (a int)";
  let width () =
    Result.map fst
      (Pg.query t "select * from w" ~binary:true ~params:[]
         ~columns:(fun _ -> ())
         ~init:0
         ~row:(fun _ cells -> Array.length cells))
  in
  ignore (ok_pg (width ()));
  script t "alter table w add column b int; insert into w values (1, 2)";
  Alcotest.(check int) "parsed again, and bound again" 2 (ok_pg (width ()));
  Pg.close t

(* A million rows each way without the heap growing by the ~17 words a row
   that buffering would take. *)
let a_million_rows_in_bounded_memory () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  script t "create temp table m (n int, s text)";
  let million = 1_000_000 in
  Gc.full_major ();
  let base = (Gc.quick_stat ()).heap_words in
  let peak = ref base in
  let sample i =
    if i mod 50_000 = 0 then peak := Int.max !peak (Gc.quick_stat ()).heap_words
  in
  let rows =
    Seq.init million (fun i ->
        sample i;
        [| Some (string_of_int i); Some "one of a million" |])
  in
  let tag = ok_pg (Pg.copy_in_rows t ~table:"m" ~columns:[ "n"; "s" ] rows) in
  Alcotest.(check (option int)) "in" (Some million) (Pg.Tag.rows tag);
  let n, tag =
    ok_pg
      (Pg.copy_out_rows t ~select:"select n, s from m" ~init:0 ~row:(fun n _ ->
           sample n;
           n + 1))
  in
  Alcotest.(check int) "out" million n;
  Alcotest.(check (option int)) "out's tag" (Some million) (Pg.Tag.rows tag);
  let grown = !peak - base in
  if grown > 2_000_000 then
    Alcotest.failf "the heap grew by %d words over a million rows" grown;
  Pg.close t

let captured f =
  let lines = ref [] in
  let report src level ~over k msgf =
    msgf (fun ?header:_ ?tags:_ fmt ->
        Format.kasprintf
          (fun line ->
            lines :=
              Printf.sprintf "%s %s %s" (Logs.Src.name src)
                (Logs.level_to_string (Some level))
                line
              :: !lines;
            over ();
            k ())
          fmt)
  in
  let before = Logs.reporter () and level = Logs.level () in
  Logs.set_reporter { Logs.report };
  Logs.set_level (Some Logs.Debug);
  Fun.protect
    ~finally:(fun () ->
      Logs.set_reporter before;
      Logs.set_level level)
    f;
  List.rev !lines

let a_notice_is_logged () =
  let lines =
    captured (fun () ->
        with_eio @@ fun env sw ->
        let t = connect env sw (plain ()) in
        script t "do $$ begin raise notice 'hello from the server'; end $$";
        Pg.close t)
  in
  Alcotest.(check bool)
    "at info, on postgres-eio" true
    (List.exists
       (fun l ->
         contains l "postgres-eio info" && contains l "hello from the server")
       lines)

(* At debug, no log line has the password, a parameter or the SASL
   exchange, except tls's own [tls.tracing] and [handshake] sources, which
   the application must cap. *)
let no_secret_in_the_log () =
  let lines =
    captured (fun () ->
        with_eio @@ fun env sw ->
        make_role env sw "pgeio_scram" (Some "pw-SECRET-1");
        List.iter
          (fun mode ->
            let t =
              connect env sw
                {
                  (as_role (base ()) "pgeio_scram" (Some "pw-SECRET-1")) with
                  ssl_mode = mode;
                }
            in
            ignore (rows t "select $1::text" [ Some "token-SECRET-2" ]);
            ignore
              (Pg.query t "select $1::int" ~params:[ Some "SECRET-3" ] ~init:()
                 ~row:(fun () _ -> ()));
            Pg.close t)
          [ Conninfo.Disable; Conninfo.Require ])
  in
  Alcotest.(check bool)
    "the case logged something" true
    (List.exists (fun l -> contains l "connected") lines);
  let transcript l =
    String.starts_with ~prefix:"tls.tracing " l
    || String.starts_with ~prefix:"handshake " l
  in
  List.iter
    (fun l ->
      if not (transcript l) then
        List.iter
          (fun word ->
            if contains l word then
              Alcotest.failf "a line carries %S: %s" word l)
          [ "SECRET"; "n,,n="; "c=biws" ])
    lines

(* Instants round-trip in any session time zone, including offsets with
   seconds. *)
let an_instant_in_every_zone () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  List.iter
    (fun zone ->
      script t (Printf.sprintf "set timezone = '%s'" zone);
      List.iter
        (fun us ->
          let printed =
            one t "select $1::timestamptz"
              [ Some (Text.timestamptz (instant_of_us us)) ]
          in
          Alcotest.(check (option int))
            (zone ^ ": " ^ printed)
            (Some us)
            (Option.map us_of (Text.to_timestamptz printed)))
        [ ten + 123_456; -2_208_988_800_000_000; 0; -1 ])
    [ "UTC"; "Asia/Kolkata"; "America/New_York"; "Europe/Amsterdam" ];
  Pg.close t

(* An interval written as ISO 8601 is the interval the server reads, whatever
   its IntervalStyle, and Postgres's own text of it reads back the same. *)
let an_interval_bound () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  let back style i =
    script t (Printf.sprintf "set intervalstyle = '%s'" style);
    let read =
      one t "select $1::interval = $2::interval"
        [
          Some (Text.interval i);
          Some
            (Printf.sprintf "%d months %d days %d microseconds" i.months i.days
               i.microseconds);
        ]
    in
    Alcotest.(check string) (style ^ ": the same interval") "t" read
  in
  let chosen =
    [
      interval 14 3 14_706_789_000;
      interval (-14) 3 (-14_706_000_000);
      interval 1 (-1) 0;
      interval 0 0 (-1_500_000);
      interval 0 0 0;
      interval 0 0 max_int;
      interval 0 0 min_int;
    ]
  in
  (* A fixed seed, so a failure names the same intervals when run again. *)
  let generated =
    QCheck2.Gen.(
      generate ~n:300
        ~rand:(Random.State.make [| 54 |])
        (map3 interval
           (int_range (-1_000_000) 1_000_000)
           (int_range (-1_000_000) 1_000_000)
           int))
  in
  List.iter
    (fun i ->
      back "iso_8601" i;
      back "postgres" i;
      Alcotest.(check (option interval_testable))
        "and its text reads back" (Some i)
        (Text.to_interval
           (one t "select $1::interval::text" [ Some (Text.interval i) ])))
    (chosen @ generated);
  Alcotest.(check string)
    "an int8 at its greatest" "9223372036854775807"
    (one t "select $1::int8::text" [ Some (Text.int64 Int64.max_int) ]);
  Pg.close t

(* A date and a timestamp written as text are read by the server as the same
   date and the same reading, whatever the session's time zone. *)
let a_date_and_a_timestamp_bound () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  script t "set timezone = 'Asia/Kolkata'";
  Alcotest.(check string)
    "a date" "2026-09-27"
    (one t "select $1::date::text" [ Some (Text.date (2026, 9, 27)) ]);
  Alcotest.(check string)
    "a date the calendar has not, refused by the server" "refused"
    (match
       Pg.query t "select $1::date"
         ~params:[ Some (Text.date (2026, 2, 30)) ]
         ~init:()
         ~row:(fun () _ -> ())
     with
    | Ok _ -> "read"
    | Error _ -> "refused");
  Alcotest.(check string)
    "a timestamp" "2026-09-27 10:00:00.123456"
    (one t "select $1::timestamp::text"
       [ Some (Text.timestamp (instant_of_us (ten + 123_456))) ]);
  Pg.close t

(* Bytes written in hex are the bytes the server holds, read back in
   binary, in hex, and in the escape form an older client may ask for; and a
   bool as the server reads it and writes it. *)
let bytes_bound () =
  with_eio @@ fun env sw ->
  let t = connect_cached env sw (plain ()) in
  let back ~binary s =
    let columns = ref [||] in
    match
      ok_pg
        (Pg.query t "select $1::bytea" ~binary
           ~params:[ Some (Text.bytes s) ]
           ~columns:(fun cs -> columns := cs)
           ~init:[]
           ~row:(fun acc cells -> cells :: acc))
    with
    | [ [| Some cell |] ], _ -> Value.bytes !columns.(0) cell
    | _ -> None
  in
  let each_byte = String.init 256 Char.chr in
  let check output ~binary =
    script t (Printf.sprintf "set bytea_output = '%s'" output);
    List.iter
      (fun s ->
        Alcotest.(check (option string))
          (Printf.sprintf "%s, binary %b, %d bytes" output binary
             (String.length s))
          (Some s) (back ~binary s))
      [ ""; "\000"; "\\x"; each_byte ]
  in
  check "hex" ~binary:false;
  check "hex" ~binary:true;
  check "escape" ~binary:false;
  List.iter
    (fun b ->
      Alcotest.(check (option bool))
        "a bool" (Some b)
        (Text.to_bool (one t "select $1::bool" [ Some (Text.bool b) ])))
    [ true; false ];
  Pg.close t

(* A host name invalid for TLS (an underscore, as in compose service
   names) works below verify-full and is refused at verify-full. Reached
   via [hostaddr], since nothing resolves it. *)
let a_name_tls_cannot_carry () =
  with_eio @@ fun env sw ->
  let c = at ~address:Ipaddr.(V4 V4.localhost) (Tcp "pg_test") (base ()) in
  List.iter
    (fun (mode, root) ->
      let t = connect env sw { c with ssl_mode = mode; ssl_root_cert = root } in
      Alcotest.(check bool)
        (Conninfo.ssl_mode_to_string mode)
        true (tls_in_use t);
      Pg.close t)
    [ (Conninfo.Prefer, None); (Require, None); (Verify_ca, Some ca) ];
  match
    connect_with env sw
      { c with ssl_mode = Verify_full; ssl_root_cert = Some ca }
  with
  | Error (Pg.Refused m) ->
      Alcotest.(check bool) m true (contains m "not a name TLS can check")
  | Error e -> Alcotest.failf "not refused here: %s" (Pg.error_to_string e)
  | Ok _ -> Alcotest.fail "connected to a name it could not check"

(* 54.2.9: close sends Terminate, and nothing after it. *)
let a_close_sends_terminate () =
  with_eio @@ fun env sw ->
  let port, heard, closed =
    a_fake_server env sw ~answer:(Some (msg 'R' (int32 0) ^ msg 'Z' "I"))
  in
  let t = connect env sw (at ~port (Tcp "127.0.0.1") (plain ())) in
  Pg.close t;
  Eio.Promise.await closed;
  Alcotest.(check string)
    "a Terminate, then the socket closed"
    (hex (msg 'X' ""))
    (hex (Buffer.contents heard))

(* 54.2.4: drain reads every answer, so the status is current, and leaves a
   statement's error in its answer; flush sends without reading. *)
let drain_and_flush () =
  with_eio @@ fun env sw ->
  let t = connect_cached env sw (plain ()) in
  let q sql = Pg.Pipeline.query t sql ~params:[] ~init:[] ~row:one_value in
  let failed = q "select 1/0" in
  ignore (q "begin");
  Alcotest.(check bool)
    "not read yet" true
    (match Pg.status t with P.Idle -> true | _ -> false);
  Alcotest.(check (result unit string))
    "drained" (Ok ())
    (Result.map_error Pg.error_to_string (Pg.Pipeline.drain t));
  Alcotest.(check bool)
    "the status current" true
    (match Pg.status t with P.In_transaction -> true | _ -> false);
  Alcotest.(check bool)
    "the error kept in its answer" true
    (match Pg.Pipeline.get failed with
    | Error (Pg.Server _) -> true
    | _ -> false);
  script t "rollback";
  let flushed = q "select 'f'" in
  Alcotest.(check (result unit string))
    "flushed" (Ok ())
    (Result.map_error Pg.error_to_string (Pg.Pipeline.flush t));
  Alcotest.(check (result (list string) string))
    "and the next reader gets the answer" (Ok [ "f" ])
    (answer_int (Pg.Pipeline.get flushed));
  in_step t;
  Pg.close t

(* From another fiber, abandon cancels the running statement and refuses
   the next until resume. *)
let abandoned_until_resumed () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  let clock = Eio.Stdenv.mono_clock env in
  let sleep () =
    Pg.query t "select pg_sleep(5)" ~params:[] ~init:() ~row:(fun () _ -> ())
  in
  let running = ref (Ok ((), Pg.Tag.empty)) in
  Eio.Fiber.both
    (fun () -> running := sleep ())
    (fun () ->
      Eio.Time.Mono.sleep clock 0.2;
      ignore (ok_pg (Pg.abandon t)));
  Alcotest.(check (option string))
    "the running one cancelled" (Some "57014")
    (match !running with
    | Error (Pg.Server e) -> Some (Pg.Server_error.sqlstate e)
    | _ -> None);
  Alcotest.(check bool)
    "the next refused" true
    (match Pg.script t "select 1" with
    | Error (Pg.Refused _) -> true
    | _ -> false);
  Pg.resume t;
  Alcotest.(check string) "and taken after resume" "1" (one t "select 1" []);
  Pg.close t

(* Any text, NULLs among it, goes in by COPY and comes back as it went,
   against the escaping a hand-picked list could miss. *)
let any_rows_through_copy () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  script t "create temp table r (n int, s text)";
  let alphabet =
    [
      'a';
      'N';
      'n';
      't';
      'x';
      '.';
      ',';
      ' ';
      '\\';
      '\t';
      '\n';
      '\r';
      '\001';
      '\'';
      '"';
    ]
  in
  (* A fixed seed, so a failure names the same rows when run again. *)
  let cells =
    QCheck2.Gen.(
      generate ~n:500
        ~rand:(Random.State.make [| 26 |])
        (option (string_size ~gen:(oneof_list alphabet) (int_range 0 12))))
  in
  let sent = List.mapi (fun i s -> [ Some (string_of_int i); s ]) cells in
  ignore
    (ok_pg
       (Pg.copy_in_rows t ~table:"r" ~columns:[ "n"; "s" ]
          (List.to_seq (List.map Array.of_list sent))));
  let back, _ =
    ok_pg
      (Pg.copy_out_rows t ~select:"select n, s from r order by n" ~init:[]
         ~row:(fun acc cells -> Array.to_list cells :: acc))
  in
  Alcotest.(check (list string))
    "54.2.6 every row as it went" (show_rows sent)
    (show_rows (List.rev back));
  Pg.close t

(* Instants across years 1 to 9999, written by the driver, read by the
   server and printed back in a distant zone. *)
let generated_instants_bound () =
  with_eio @@ fun env sw ->
  let t = connect env sw (plain ()) in
  script t "set timezone = 'Asia/Kolkata'";
  (* A fixed seed, so a failure names the same instants when run again;
     a day inside the range, since a distant zone can print year 0. *)
  let instants =
    QCheck2.Gen.(
      generate ~n:300
        ~rand:(Random.State.make [| 1 |])
        (int_range (-62_135_510_400_000_000) 253_402_214_399_999_999))
  in
  List.iter
    (fun us ->
      let printed =
        one t "select $1::timestamptz"
          [ Some (Text.timestamptz (instant_of_us us)) ]
      in
      Alcotest.(check (option int))
        printed (Some us)
        (Option.map us_of (Text.to_timestamptz printed)))
    instants;
  Pg.close t

let connection_cases =
  [
    Alcotest.test_case "a query, signed in by SCRAM" `Quick a_query_by_scram;
    Alcotest.test_case "54.2.10 verify-full, over TLS" `Quick
      verify_full_over_tls;
    Alcotest.test_case
      "54.2.10 verify-full refuses a certificate it does not trust" `Quick
      verify_full_refuses_an_untrusted_certificate;
    Alcotest.test_case "54.2.10 every sslmode" `Quick every_sslmode;
    Alcotest.test_case "54.3 MD5, signed in" `Quick signed_in_by_md5;
    Alcotest.test_case "54.3 a cleartext password, inside TLS" `Quick
      cleartext_over_tls;
    Alcotest.test_case "54.3 trust" `Quick trust;
    Alcotest.test_case "54.3 a cleartext password is not sent without TLS"
      `Quick cleartext_without_tls_is_refused;
    Alcotest.test_case "a Unix socket" `Quick over_a_unix_socket;
    Alcotest.test_case "54.2.3 a statement is described without running" `Quick
      a_statement_is_described_without_running;
    Alcotest.test_case "54.2.8 a running statement is cancelled" `Quick
      a_running_statement_is_cancelled;
    Alcotest.test_case "54.2.8 a cancel over TLS" `Quick a_cancel_over_tls;
    Alcotest.test_case "a reset keeps its parameters" `Quick
      a_reset_keeps_its_parameters;
    Alcotest.test_case "a silent server times out" `Quick
      a_silent_server_times_out;
    Alcotest.test_case "a read past the timeout" `Quick a_read_past_the_timeout;
    Alcotest.test_case "a connection left open lets its switch finish" `Quick
      a_connection_left_open_lets_its_switch_finish;
    Alcotest.test_case "a cancellation from outside is not a timeout" `Quick
      a_cancellation_from_outside_is_not_a_timeout;
    Alcotest.test_case "54.2.3 a server's error keeps the connection" `Quick
      a_server_error_keeps_the_connection;
    Alcotest.test_case "54.7 ReadyForQuery's transaction status" `Quick
      transaction_status;
    Alcotest.test_case "54.2.2 a script of several statements" `Quick
      a_script_of_several_statements;
    Alcotest.test_case "the rest of a query" `Quick the_rest_of_a_query;
    Alcotest.test_case "54.2.6 query and script refuse a COPY" `Quick
      copy_is_refused;
    Alcotest.test_case "54.2.6 COPY by rows, both ways" `Quick
      copy_rows_both_ways;
    Alcotest.test_case "54.2.6 COPY by bytes, both ways" `Quick
      copy_bytes_both_ways;
    Alcotest.test_case "54.2.6 a producer that raises is a CopyFail" `Quick
      a_producer_that_raises;
    Alcotest.test_case "54.2.6 a refusal part-way through a COPY" `Quick
      a_refusal_part_way;
    Alcotest.test_case "54.2.6 the wrong statement for a COPY" `Quick
      the_wrong_statement;
    Alcotest.test_case "54.2.6 a NUL in a COPY" `Quick a_nul_in_a_copy;
    Alcotest.test_case "54.2.6 a cancelled COPY closes the connection" `Quick
      a_cancelled_copy_closes;
    Alcotest.test_case "54.2.6 a million rows, in bounded memory" `Slow
      a_million_rows_in_bounded_memory;
    Alcotest.test_case
      "54.2.7 a notification that committed, and not one that rolled back"
      `Quick a_notification_committed_and_not_rolled_back;
    Alcotest.test_case "a channel is its exact name" `Quick
      a_channel_is_its_exact_name;
    Alcotest.test_case "54.2.7 what arrives during a LISTEN is kept" `Quick
      what_arrives_during_a_listen_is_kept;
    Alcotest.test_case "a killed backend is a reconnection" `Quick
      a_killed_backend_is_a_reconnection;
    Alcotest.test_case "a silent network is found" `Quick
      a_silent_network_is_found;
    Alcotest.test_case "a quiet listener outlives its heartbeats" `Quick
      a_quiet_listener_outlives_its_heartbeats;
    Alcotest.test_case "a refused sign-in is returned, not retried" `Quick
      a_refused_sign_in_is_returned;
    Alcotest.test_case "a payload past the limit" `Quick
      a_payload_past_the_limit;
    Alcotest.test_case "54.2.3 a statement is parsed once" `Quick
      a_statement_is_parsed_once;
    Alcotest.test_case "54.2.3 the cache is sized, or off" `Quick
      the_cache_is_sized_or_off;
    Alcotest.test_case "54.2.3 a stale plan" `Quick a_stale_plan;
    Alcotest.test_case "54.2.3 the columns, before any row" `Quick
      the_columns_before_any_row;
    Alcotest.test_case "54.2.3 a batch is one round trip and one transaction"
      `Quick a_batch;
    Alcotest.test_case "54.2.4 a pipeline" `Quick a_pipeline;
    Alcotest.test_case "54.2.4 drain reads every answer, flush none" `Quick
      drain_and_flush;
    Alcotest.test_case "an abandoned connection refuses until resumed" `Quick
      abandoned_until_resumed;
    Alcotest.test_case "54.2.9 a close sends Terminate" `Quick
      a_close_sends_terminate;
    Alcotest.test_case "54.2.6 any rows, through COPY and back" `Quick
      any_rows_through_copy;
    Alcotest.test_case "instants across the years, bound" `Quick
      generated_instants_bound;
    Alcotest.test_case "54.2.4 answers asked for out of order" `Quick
      answers_asked_for_out_of_order;
    Alcotest.test_case "54.2.4 a refused Parse down a pipeline" `Quick
      a_refused_parse_down_a_pipeline;
    Alcotest.test_case "a caller's DISCARD empties the cache" `Quick
      a_caller's_discard_empties_the_cache;
    Alcotest.test_case "54.2.4 a hundred thousand statements complete" `Slow
      a_long_pipeline_completes;
    Alcotest.test_case "54.2.4 longer than the buffers, and no deadlock" `Quick
      longer_than_the_buffers;
    Alcotest.test_case "54.2.6 a COPY the server answers as it goes" `Slow
      a_copy_the_server_answers_as_it_goes;
    Alcotest.test_case "a slow row function is not timed" `Quick
      a_slow_row_function_is_not_timed;
    Alcotest.test_case "54.2.3 binary decodes as text does" `Quick
      binary_decodes_as_text_does;
    Alcotest.test_case "binary values are the values" `Quick
      binary_values_are_the_values;
    Alcotest.test_case "binary needs the statement cache" `Quick
      binary_needs_the_statement_cache;
    Alcotest.test_case "54.2.7 a notice is logged" `Quick a_notice_is_logged;
    Alcotest.test_case "no secret in the log" `Quick no_secret_in_the_log;
    Alcotest.test_case "an instant, in every time zone" `Quick
      an_instant_in_every_zone;
    Alcotest.test_case "a date and a timestamp, bound" `Quick
      a_date_and_a_timestamp_bound;
    Alcotest.test_case "an interval and an int8, bound" `Quick an_interval_bound;
    Alcotest.test_case "bytes and a bool, bound" `Quick bytes_bound;
    Alcotest.test_case "54.2.10 a name TLS cannot carry" `Quick
      a_name_tls_cannot_carry;
    Alcotest.test_case "54.3.1 a sign-in bound to TLS" `Quick
      a_sign_in_bound_to_tls;
    Alcotest.test_case "54.3.1 a required binding refuses a server without one"
      `Quick a_required_binding_refuses_a_server_without_one;
    Alcotest.test_case "require_auth refuses what it does not allow" `Quick
      require_auth_refuses_what_it_does_not_allow;
    Alcotest.test_case "54.2.10 direct TLS" `Quick direct_tls;
    Alcotest.test_case "54.2.10 prefer falls back, require never" `Quick
      prefer_falls_back;
    Alcotest.test_case "a client certificate" `Quick a_client_certificate;
    Alcotest.test_case "several hosts" `Quick several_hosts;
    Alcotest.test_case "a refused address leaves no socket" `Quick
      a_refused_address_leaves_no_socket;
    Alcotest.test_case "the kind of host asked for" `Quick
      the_kind_of_host_asked_for;
    Alcotest.test_case "54.2.1 protocol 3.2" `Quick protocol_3_2;
    Alcotest.test_case "options become settings" `Quick options_become_settings;
    Alcotest.test_case "nothing from the environment unasked" `Quick
      nothing_from_the_environment_unasked;
    Alcotest.test_case "a password from a .pgpass" `Quick
      a_password_from_a_passfile;
    Alcotest.test_case "SASLprep, as the server does it" `Quick
      saslprep_as_the_server_does;
  ]

(* The pool *)

let pool ?parameters ?(size = 1) ?(wait_s = 2.) ?reset ?max_lifetime_s
    ?idle_check_s env sw =
  ok_pg
    (Pg.Pool.create ~sw ~net:(Eio.Stdenv.net env)
       ~clock:(Eio.Stdenv.mono_clock env)
       ?parameters ~size ~wait_s ?reset ?max_lifetime_s ?idle_check_s (plain ()))

let borrow p f =
  match Pg.Pool.use p f with
  | Ok v -> v
  | Error `Busy -> Alcotest.fail "no connection"

(* An exhausted pool returns [`Busy] within its wait, then recovers. *)
let a_held_pool_is_busy_then_serves () =
  with_eio @@ fun env sw ->
  let p = pool ~wait_s:0.2 env sw in
  let clock = Eio.Stdenv.mono_clock env in
  let answer = ref (Ok ()) in
  Eio.Fiber.both
    (fun () -> borrow p (fun _ -> Eio.Time.Mono.sleep clock 0.5))
    (fun () -> answer := Pg.Pool.use p (fun _ -> ()));
  Alcotest.(check bool)
    "busy while held" true
    (match !answer with Error `Busy -> true | Ok () -> false);
  Alcotest.(check string)
    "served once free" "1"
    (borrow p (fun t -> one t "select 1" []));
  Pg.Pool.close p

(* A cancelled borrow cancels its statement at the server, and the
   connection returns idle. *)
let an_abandoned_statement_is_stopped_at_the_server () =
  with_eio @@ fun env sw ->
  let p = pool env sw in
  let clock = Eio.Stdenv.mono_clock env in
  let started = Eio.Time.Mono.now clock in
  (match
     Eio.Time.with_timeout (Eio.Stdenv.clock env) 0.3 (fun () ->
         Ok
           (Pg.Pool.use p (fun t ->
                Pg.query t "select pg_sleep(5)" ~params:[] ~init:()
                  ~row:(fun () _ -> ()))))
   with
  | Error `Timeout -> ()
  | Ok _ -> Alcotest.fail "the borrow was not abandoned");
  let took = seconds_since clock started in
  Alcotest.(check bool)
    (Printf.sprintf "ended at the server, in %.2fs" took)
    true (took < 2.);
  borrow p (fun t ->
      Alcotest.(check bool)
        "idle" true
        (match Pg.status t with P.Idle -> true | _ -> false);
      Alcotest.(check string) "and taking statements" "1" (one t "select 1" []));
  Pg.Pool.close p

(* A cancelled borrow never sends a statement it had not sent yet. *)
let a_statement_not_yet_sent_is_never_sent () =
  with_eio @@ fun env sw ->
  let p = pool env sw in
  let clock = Eio.Stdenv.mono_clock env in
  borrow p (fun t ->
      script t
        "create table if not exists pgeio_unsent (n int); truncate pgeio_unsent");
  let second = ref (Ok ((), Pg.Tag.empty)) in
  (match
     Eio.Time.with_timeout (Eio.Stdenv.clock env) 0.2 (fun () ->
         Ok
           (Pg.Pool.use p (fun t ->
                Eio.Time.Mono.sleep clock 0.4;
                second :=
                  Pg.query t "insert into pgeio_unsent values (1)" ~params:[]
                    ~init:() ~row:(fun () _ -> ()))))
   with
  | Error `Timeout -> ()
  | Ok _ -> Alcotest.fail "the borrow was not abandoned");
  Alcotest.(check bool)
    "refused before it was sent" true
    (match !second with Error (Pg.Refused _) -> true | _ -> false);
  borrow p (fun t ->
      Alcotest.(check string)
        "and nothing reached the table" "0"
        (one t "select count(*) from pgeio_unsent" []);
      script t "drop table pgeio_unsent");
  Pg.Pool.close p

(* A connection returned inside a transaction is rolled back. *)
let a_transaction_left_open_is_rolled_back () =
  with_eio @@ fun env sw ->
  let p = pool env sw in
  borrow p (fun t ->
      script t
        "create table if not exists pgeio_open (n int); truncate pgeio_open");
  borrow p (fun t ->
      script t "begin";
      script t "insert into pgeio_open values (1)");
  borrow p (fun t ->
      Alcotest.(check bool)
        "given out idle" true
        (match Pg.status t with P.Idle -> true | _ -> false);
      Alcotest.(check string)
        "and nothing kept" "0"
        (one t "select count(*) from pgeio_open" []);
      script t "begin";
      ignore (Pg.query t "select 1/0" ~params:[] ~init:() ~row:(fun () _ -> ())));
  borrow p (fun t ->
      Alcotest.(check bool)
        "an aborted one too" true
        (match Pg.status t with P.Idle -> true | _ -> false);
      script t "drop table pgeio_open");
  Pg.Pool.close p

(* Unread pipelined answers are drained on return, so an open transaction
   is seen and rolled back. *)
let a_pipeline_left_unread () =
  with_eio @@ fun env sw ->
  let p = pool env sw in
  borrow p (fun t ->
      script t
        "create table if not exists pgeio_unread (n int); truncate pgeio_unread");
  borrow p (fun t ->
      List.iter
        (fun sql ->
          ignore
            (Pg.Pipeline.query t sql ~params:[] ~init:() ~row:(fun () _ -> ())))
        [ "begin"; "insert into pgeio_unread values (1)" ]);
  borrow p (fun t ->
      Alcotest.(check bool)
        "given out idle" true
        (match Pg.status t with P.Idle -> true | _ -> false);
      Alcotest.(check string)
        "and the transaction rolled back" "0"
        (one t "select count(*) from pgeio_unread" []);
      script t "drop table pgeio_unread");
  Pg.Pool.close p

let leave_everything t =
  List.iter (script t)
    [
      "set timezone = 'Asia/Tokyo'";
      "create temp table pgeio_left (n int)";
      "select pg_advisory_lock(4242)";
      "listen pgeio_left";
      "begin";
      "declare pgeio_cursor cursor with hold for select 1";
      "commit";
      "create temp sequence pgeio_seq";
      "select nextval('pgeio_seq')";
    ]

let what_is_left t =
  List.map
    (fun sql -> one t sql [])
    [
      "show timezone";
      "select count(*)::text from pg_tables where tablename = 'pgeio_left'";
      "select count(*)::text from pg_locks where locktype = 'advisory' and pid \
       = pg_backend_pid()";
      "select count(*)::text from pg_listening_channels()";
      "select count(*)::text from pg_cursors";
      "show client_min_messages";
    ]

(* Settings, temporary tables, advisory locks, LISTENs and cursors don't
   leak to the next borrower; startup parameters remain. *)
let a_borrowers_session_is_not_the_next_ones () =
  with_eio @@ fun env sw ->
  let p = pool ~parameters:[ ("client_min_messages", "warning") ] env sw in
  let fresh = borrow p what_is_left in
  let pid =
    borrow p (fun t ->
        leave_everything t;
        one t "select pg_backend_pid()::text" [])
  in
  borrow p (fun t ->
      Alcotest.(check string)
        "the same connection" pid
        (one t "select pg_backend_pid()::text" []);
      Alcotest.(check (list string))
        "and nothing of the last borrower's" fresh (what_is_left t);
      match
        Pg.query t "select currval('pgeio_seq')" ~params:[] ~init:()
          ~row:(fun () _ -> ())
      with
      | Error (Pg.Server _) -> ()
      | _ -> Alcotest.fail "the last borrower's sequence was seen");
  Pg.Pool.close p

let reset_false_keeps_the_session () =
  with_eio @@ fun env sw ->
  let p = pool ~reset:false env sw in
  borrow p (fun t ->
      script t "set timezone = 'Asia/Tokyo'";
      script t "begin");
  borrow p (fun t ->
      Alcotest.(check string)
        "the setting kept" "Asia/Tokyo" (one t "show timezone" []);
      Alcotest.(check bool)
        "and the transaction rolled back" true
        (match Pg.status t with P.Idle -> true | _ -> false));
  Pg.Pool.close p

(* Even with [~reset:false]: an idle pooled connection reads nothing, so
   one left listening would fill the server's notification queue. *)
let a_pooled_connection_never_listens () =
  with_eio @@ fun env sw ->
  let p = pool ~reset:false env sw in
  borrow p (fun t ->
      script t "set timezone = 'Asia/Tokyo'";
      script t "listen pgeio_pooled");
  borrow p (fun t ->
      Alcotest.(check string)
        "not listening" "0"
        (one t "select count(*)::text from pg_listening_channels()" []);
      Alcotest.(check string)
        "though the setting is kept" "Asia/Tokyo" (one t "show timezone" []));
  Pg.Pool.close p

let the_timeout_it_was_made_with () =
  with_eio @@ fun env sw ->
  let p = pool env sw in
  borrow p (fun t -> Pg.set_timeout t ~timeout_s:None);
  borrow p (fun t ->
      Alcotest.(check (option (float 0.)))
        "put back" (Some 30.) (Pg.timeout_s t));
  Pg.Pool.close p

let backend t = one t "select pg_backend_pid()::text" []

(* Idle connections past their lifetime are replaced; borrowed ones wait
   until returned. *)
let a_connection_past_its_lifetime () =
  with_eio @@ fun env sw ->
  let clock = Eio.Stdenv.mono_clock env in
  let p = pool ~max_lifetime_s:0.3 env sw in
  let first = borrow p backend in
  let held =
    borrow p (fun t ->
        Eio.Time.Mono.sleep clock 0.8;
        backend t)
  in
  Alcotest.(check string) "left alone while borrowed" first held;
  Eio.Time.Mono.sleep clock 0.6;
  Alcotest.(check bool)
    "made anew once back" true
    (not (String.equal first (borrow p backend)));
  Alcotest.(check bool) "and counted" true ((Pg.Pool.stats p).replaced >= 1);
  Pg.Pool.close p

(* A dead idle connection is found by the check and replaced unnoticed. *)
let a_dead_idle_connection_is_checked () =
  with_eio @@ fun env sw ->
  let clock = Eio.Stdenv.mono_clock env in
  let p = pool ~idle_check_s:0.2 ~size:2 env sw in
  terminate env sw (borrow p backend);
  Eio.Time.Mono.sleep clock 0.8;
  Alcotest.(check bool)
    "made anew by the check" true
    ((Pg.Pool.stats p).replaced >= 1);
  for _ = 1 to 4 do
    ignore (borrow p backend)
  done;
  Pg.Pool.close p

let the_pools_figures () =
  with_eio @@ fun env sw ->
  let clock = Eio.Stdenv.mono_clock env in
  let p = pool ~size:2 ~wait_s:1. env sw in
  let figures () =
    let s = Pg.Pool.stats p in
    (s.size, s.idle, s.waiting)
  in
  Alcotest.(check (triple int int int)) "made" (2, 2, 0) (figures ());
  let seen = ref (0, 0, 0) in
  Eio.Fiber.all
    [
      (fun () -> borrow p (fun _ -> Eio.Time.Mono.sleep clock 0.3));
      (fun () -> borrow p (fun _ -> Eio.Time.Mono.sleep clock 0.3));
      (fun () ->
        Eio.Time.Mono.sleep clock 0.05;
        borrow p (fun _ -> ()));
      (fun () ->
        Eio.Time.Mono.sleep clock 0.15;
        seen := figures ());
    ];
  Alcotest.(check (triple int int int))
    "both borrowed, one waiting" (2, 0, 1) !seen;
  Alcotest.(check (triple int int int)) "all back" (2, 2, 0) (figures ());
  Pg.Pool.close p;
  let none = pool ~size:0 env sw in
  Alcotest.(check int) "at least one" 1 (Pg.Pool.stats none).size;
  Pg.Pool.close none

let closing_a_pool_waits_for_its_borrows () =
  with_eio @@ fun env sw ->
  let p = pool env sw in
  let clock = Eio.Stdenv.mono_clock env in
  let during = ref true in
  Eio.Fiber.both
    (fun () ->
      borrow p (fun t ->
          Eio.Time.Mono.sleep clock 0.3;
          during := Pg.closed t;
          ignore (one t "select 1" [])))
    (fun () ->
      Eio.Time.Mono.sleep clock 0.1;
      Pg.Pool.close p);
  Alcotest.(check bool) "not closed while borrowed" false !during;
  Alcotest.(check bool)
    "and none lent after" true
    (match Pg.Pool.use ~wait_s:0.1 p ignore with
    | Error `Busy -> true
    | Ok () -> false)

(* After the backend is terminated, the next borrow gets a reconnected
   connection with its startup parameters. *)
let a_dropped_connection_comes_back_as_it_was () =
  with_eio @@ fun env sw ->
  let p = pool ~parameters:[ ("client_min_messages", "warning") ] env sw in
  let pid = borrow p (fun t -> one t "select pg_backend_pid()::text" []) in
  terminate env sw pid;
  (* Let the termination cross Docker's proxy first. *)
  Eio.Time.Mono.sleep (Eio.Stdenv.mono_clock env) 0.1;
  borrow p (fun t ->
      Alcotest.(check bool)
        "a new backend, found gone as it was lent, so the first statement runs"
        false
        (String.equal pid (one t "select pg_backend_pid()::text" []));
      Alcotest.(check string)
        "with its parameters" "warning"
        (one t "show client_min_messages" []));
  Pg.Pool.close p

(* One connection borrowed from three domains: none is lost, each borrow
   runs on its own domain, and the pool closes cleanly. *)
let a_pool_is_borrowed_from_every_domain () =
  with_eio @@ fun env sw ->
  let p = pool env sw in
  let served = Atomic.make 0 in
  Eio.Fiber.all
    (List.init 3 (fun _ () ->
         Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env) (fun () ->
             for _ = 1 to 5 do
               match Pg.Pool.use p (fun t -> one t "select 1" []) with
               | Ok "1" -> Atomic.incr served
               | Ok _ -> Alcotest.fail "a wrong answer"
               | Error `Busy -> Alcotest.fail "a borrow found no connection"
             done)));
  Alcotest.(check int) "every borrow was served" 15 (Atomic.get served);
  Pg.Pool.close p

(* Both warnings: a long hold and a long wait. *)
let the_pool_says_when_it_is_in_trouble () =
  let lines =
    captured (fun () ->
        with_eio @@ fun env sw ->
        let p = pool env sw in
        let clock = Eio.Stdenv.mono_clock env in
        Eio.Fiber.both
          (fun () -> borrow p (fun _ -> Eio.Time.Mono.sleep clock 0.3))
          (fun () -> borrow p ignore);
        Pg.Pool.close p)
  in
  let said sub =
    List.exists
      (fun l -> contains l "postgres-eio.pool" && contains l sub)
      lines
  in
  Alcotest.(check bool)
    "a wait past its threshold" true
    (said "a wait for a connection took");
  Alcotest.(check bool)
    "and a borrow held past its own" true
    (said "a borrowed connection took")

(* A borrower cancelled during reconnection still returns the connection.
   The fake server drops each connection at its first statement and stays
   silent while [answering] is false. *)
let a_cancelled_reset_gives_the_connection_back () =
  with_eio @@ fun env sw ->
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.mono_clock env in
  let answering = ref true in
  let released, release = Eio.Promise.create () in
  let listener =
    Eio.Net.listen ~sw ~backlog:4 net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr listener with `Tcp (_, p) -> p | `Unix _ -> 0
  in

  let rec serve () =
    Eio.Net.accept_fork ~sw listener ~on_error:ignore (fun flow _ ->
        if !answering then (
          let buf = Cstruct.create 1024 in
          ignore (Eio.Flow.single_read flow buf : int);
          Eio.Flow.copy_string (msg 'R' (int32 0) ^ msg 'Z' "I") flow;
          ignore (Eio.Flow.single_read flow buf : int))
        else Eio.Promise.await released);
    serve ()
  in
  Eio.Fiber.fork_daemon ~sw serve;
  let c =
    match
      Conninfo.of_string
        (Printf.sprintf "host=127.0.0.1 port=%d user=anybody sslmode=disable"
           port)
    with
    | Ok c -> c
    | Error e -> Alcotest.fail e
  in
  let p = ok_pg (Pg.Pool.create ~sw ~net ~clock ~size:1 ~wait_s:1. c) in
  borrow p (fun t ->
      Alcotest.(check bool)
        "dropped at its first statement" true
        (Result.is_error (Pg.script t "select 1")));
  answering := false;
  Eio.Fiber.first
    (fun () ->
      match Pg.Pool.use p (fun _ -> Alcotest.fail "lent unanswered") with
      | Ok () | Error `Busy -> ())
    (fun () -> Eio.Time.Mono.sleep clock 0.2);
  answering := true;
  Alcotest.(check bool) "lent again, and open" false (borrow p Pg.closed);
  Eio.Promise.resolve release ();
  Pg.Pool.close p

(* A failed reconnect (password changed) is logged on the pool's source,
   and the statement returns [Closed]. *)
let a_reset_that_fails_says_why () =
  let lines =
    captured (fun () ->
        with_eio @@ fun env sw ->
        make_role env sw "pgeio_reset" (Some "before");
        let p =
          ok_pg
            (Pg.Pool.create ~sw ~net:(Eio.Stdenv.net env)
               ~clock:(Eio.Stdenv.mono_clock env)
               ~size:1
               (as_role (plain ()) "pgeio_reset" (Some "before")))
        in
        let pid =
          borrow p (fun t -> one t "select pg_backend_pid()::text" [])
        in
        let admin = connect env sw (plain ()) in
        script admin "alter role pgeio_reset password 'after'";
        Pg.close admin;
        terminate env sw pid;
        borrow p (fun t -> ignore (Pg.script t "select 1"));
        borrow p (fun t ->
            Alcotest.(check bool)
              "its statement answers Closed" true
              (match Pg.script t "select 1" with
              | Error Pg.Closed -> true
              | Ok () | Error _ -> false));
        Pg.Pool.close p)
  in
  Alcotest.(check bool)
    "the reason, on the pool's source" true
    (List.exists
       (fun l -> contains l "postgres-eio.pool" && contains l "28P01")
       lines)

let pool_cases =
  [
    Alcotest.test_case "a pool is borrowed from every domain" `Quick
      a_pool_is_borrowed_from_every_domain;
    Alcotest.test_case "the pool says when it is in trouble" `Quick
      the_pool_says_when_it_is_in_trouble;
    Alcotest.test_case "a held pool is busy, then serves" `Quick
      a_held_pool_is_busy_then_serves;
    Alcotest.test_case "an abandoned statement is stopped at the server" `Quick
      an_abandoned_statement_is_stopped_at_the_server;
    Alcotest.test_case "a statement not yet sent is never sent" `Quick
      a_statement_not_yet_sent_is_never_sent;
    Alcotest.test_case "a transaction left open is rolled back" `Quick
      a_transaction_left_open_is_rolled_back;
    Alcotest.test_case "a pipeline left unread" `Quick a_pipeline_left_unread;
    Alcotest.test_case "a borrower's session is not the next one's" `Quick
      a_borrowers_session_is_not_the_next_ones;
    Alcotest.test_case "reset false keeps the session" `Quick
      reset_false_keeps_the_session;
    Alcotest.test_case "a pooled connection never listens" `Quick
      a_pooled_connection_never_listens;
    Alcotest.test_case "the timeout it was made with" `Quick
      the_timeout_it_was_made_with;
    Alcotest.test_case "a connection past its lifetime" `Quick
      a_connection_past_its_lifetime;
    Alcotest.test_case "a dead idle connection is checked" `Quick
      a_dead_idle_connection_is_checked;
    Alcotest.test_case "the pool's figures" `Quick the_pools_figures;
    Alcotest.test_case "closing a pool waits for its borrows" `Quick
      closing_a_pool_waits_for_its_borrows;
    Alcotest.test_case "a dropped connection comes back as it was" `Quick
      a_dropped_connection_comes_back_as_it_was;
    Alcotest.test_case "a cancelled reset gives the connection back" `Quick
      a_cancelled_reset_gives_the_connection_back;
    Alcotest.test_case "a reset that fails says why" `Quick
      a_reset_that_fails_says_why;
  ]

let () =
  Alcotest.run "postgres_eio"
    [
      ("messages", row_cases @ [ QCheck_alcotest.to_alcotest at_any_split ]);
      ( "refusals",
        refusals
        @ [
            Alcotest.test_case "54.7 a message past the limit" `Quick
              a_message_past_the_limit;
          ] );
      ( "frontend",
        encodings
        @ [
            Alcotest.test_case "54.7 a String cannot carry a NUL" `Quick
              a_nul_cannot_be_sent;
            Alcotest.test_case "54.7 a Bind counts at most 65535 parameters"
              `Quick too_many_parameters;
          ] );
      ( "sign-in",
        [
          Alcotest.test_case "SCRAM-SHA-256, RFC 7677's exchange" `Quick
            scram_rfc_7677;
          Alcotest.test_case "54.3.1 SCRAM names nobody" `Quick
            scram_names_nobody_by_default;
          Alcotest.test_case "SCRAM refuses a server it cannot trust" `Quick
            scram_refuses_a_server_it_cannot_trust;
          Alcotest.test_case "54.3 MD5" `Quick md5;
        ] );
      ( "connection strings",
        conninfo_cases @ [ QCheck_alcotest.to_alcotest a_url_reads_back ] );
      ( "text forms",
        List.map reads_an_instant instants
        @ List.map reads_a_date dates
        @ List.map reads_an_interval intervals
        @ [
            QCheck_alcotest.to_alcotest a_float_reads_back;
            QCheck_alcotest.to_alcotest an_int64_reads_back;
            QCheck_alcotest.to_alcotest an_int_reads_back;
            QCheck_alcotest.to_alcotest bytes_read_back;
            QCheck_alcotest.to_alcotest a_date_reads_back;
            QCheck_alcotest.to_alcotest a_binary_instant_reads_as_itself;
            QCheck_alcotest.to_alcotest an_instant_reads_back;
          ] );
      ( "types",
        [
          Alcotest.test_case "a number is decimal" `Quick a_number_is_decimal;
          Alcotest.test_case "a decoder answers alike both ways" `Quick
            a_decoder_answers_alike_both_ways;
          Alcotest.test_case "an OID is four unsigned bytes" `Quick
            an_oid_is_four_unsigned_bytes;
          Alcotest.test_case "54.8 a severity, by its unlocalised name" `Quick
            a_severity_by_its_unlocalised_name;
          Alcotest.test_case "54.8 a server error's fields" `Quick
            a_server_errors_fields;
          Alcotest.test_case "54.7 a command tag" `Quick a_command_tag;
        ] );
      ( "the connection",
        match target with
        | Some _ -> connection_cases
        | None ->
            print_endline
              "  [the connection skipped: no POSTGRES_EIO_TEST_PG -- `make \
               test` brings Postgres up]";
            [] );
      ("the pool", match target with Some _ -> pool_cases | None -> []);
    ]
