(* Unknown keys are refused rather than ignored: a setting nobody read
   means a connection other than the one asked for. *)

type ssl_mode = Disable | Allow | Prefer | Require | Verify_ca | Verify_full
type ssl_negotiation = Postgres | Direct
type channel_binding = Binding_disabled | Binding_preferred | Binding_required

type auth_methods = {
  password : bool;
  md5 : bool;
  scram_sha_256 : bool;
  none : bool;
}

type session_attrs =
  | Any
  | Read_write
  | Read_only
  | Primary
  | Standby
  | Prefer_standby

type load_balance = In_order | Random
type protocol_version = V3_0 | V3_2
type host = Tcp of string | Unix_socket of string

type endpoint = {
  host : host;
  address : Ipaddr.t option;
  port : int;
  password : string option;
}

type t = {
  hosts : endpoint list;
  user : string;
  password : string option;
  database : string;
  ssl_mode : ssl_mode;
  ssl_root_cert : string option;
  ssl_cert : string option;
  ssl_key : string option;
  ssl_negotiation : ssl_negotiation;
  channel_binding : channel_binding;
  require_auth : auth_methods;
  connect_timeout_s : float option;
  application_name : string option;
  keepalives : bool;
  target_session_attrs : session_attrs;
  load_balance_hosts : load_balance;
  min_protocol_version : protocol_version;
  max_protocol_version : protocol_version;
  options : (string * string) list;
}

let ( let* ) = Result.bind

let keys =
  [
    "host";
    "hostaddr";
    "port";
    "user";
    "password";
    "dbname";
    "sslmode";
    "sslrootcert";
    "sslcert";
    "sslkey";
    "sslnegotiation";
    "channel_binding";
    "require_auth";
    "connect_timeout";
    "application_name";
    "keepalives";
    "target_session_attrs";
    "load_balance_hosts";
    "min_protocol_version";
    "max_protocol_version";
    "options";
  ]

let one_of key choices s =
  match List.assoc_opt s choices with
  | Some v -> Ok v
  | None ->
      Error
        (Printf.sprintf "%s %S is none of %s" key s
           (String.concat ", " (List.map fst choices)))

let ssl_modes =
  [
    ("disable", Disable);
    ("allow", Allow);
    ("prefer", Prefer);
    ("require", Require);
    ("verify-ca", Verify_ca);
    ("verify-full", Verify_full);
  ]

let ssl_mode_to_string = function
  | Disable -> "disable"
  | Allow -> "allow"
  | Prefer -> "prefer"
  | Require -> "require"
  | Verify_ca -> "verify-ca"
  | Verify_full -> "verify-full"

let channel_bindings =
  [
    ("disable", Binding_disabled);
    ("prefer", Binding_preferred);
    ("require", Binding_required);
  ]

let session_attrs =
  [
    ("any", Any);
    ("read-write", Read_write);
    ("read-only", Read_only);
    ("primary", Primary);
    ("standby", Standby);
    ("prefer-standby", Prefer_standby);
  ]

let protocol_versions = [ ("3.0", V3_0); ("3.2", V3_2); ("latest", V3_2) ]
let protocol_minor = function V3_0 -> 0 | V3_2 -> 2

let every_method =
  { password = true; md5 = true; scram_sha_256 = true; none = true }

(* As libpq 16: a list of allowed methods, or all negated with [!].
   [gss] and [sspi] are accepted but unsupported, so they allow nothing. *)
let require_auth s =
  let names = List.map String.trim (String.split_on_char ',' s) in
  let negated n = String.length n > 0 && Char.equal n.[0] '!' in
  let* allowing =
    match (List.for_all negated names, List.exists negated names) with
    | true, _ -> Ok false
    | false, false -> Ok true
    | false, true ->
        Error
          "require_auth mixes methods with methods negated by !, which libpq \
           does not read either"
  in
  List.fold_left
    (fun acc name ->
      let* (m : auth_methods) = acc in
      let bare =
        if negated name then String.sub name 1 (String.length name - 1)
        else name
      in
      match bare with
      | "password" -> Ok { m with password = allowing }
      | "md5" -> Ok { m with md5 = allowing }
      | "scram-sha-256" -> Ok { m with scram_sha_256 = allowing }
      | "none" -> Ok { m with none = allowing }
      | "gss" | "sspi" -> Ok m
      | other ->
          Error
            (Printf.sprintf
               "require_auth names %S, which is none of password, md5, \
                scram-sha-256, gss, sspi and none"
               other))
    (Ok
       (if allowing then
          { password = false; md5 = false; scram_sha_256 = false; none = false }
        else every_method))
    names

let require_auth_to_string (m : auth_methods) =
  String.concat ","
    (List.filter_map
       (fun (allowed, name) -> if allowed then Some name else None)
       [
         (m.password, "password");
         (m.md5, "md5");
         (m.scram_sha_256, "scram-sha-256");
         (m.none, "none");
       ])

(* [options] split as libpq does (spaces, backslash escapes). Only
   settings are kept, sent as startup parameters: [-c name=value],
   [-cname=value] and [--name=value], with dashes in [--] names read as
   underscores, as the server does. *)
let options s =
  let n = String.length s in
  let rec words i current acc =
    if i >= n then
      List.rev
        (if Buffer.length current > 0 then Buffer.contents current :: acc
         else acc)
    else
      match s.[i] with
      | '\\' when i + 1 < n ->
          Buffer.add_char current s.[i + 1];
          words (i + 2) current acc
      | ' ' | '\t' | '\n' | '\r' ->
          if Buffer.length current > 0 then
            words (i + 1) (Buffer.create 16) (Buffer.contents current :: acc)
          else words (i + 1) current acc
      | c ->
          Buffer.add_char current c;
          words (i + 1) current acc
  in
  let setting what s =
    match String.index_opt s '=' with
    | Some j when j > 0 ->
        Ok (String.sub s 0 j, String.sub s (j + 1) (String.length s - j - 1))
    | Some _ | None ->
        Error (Printf.sprintf "options' %S is not name=value" what)
  in
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | "-c" :: s :: rest ->
        let* pair = setting s s in
        go (pair :: acc) rest
    | w :: rest when String.starts_with ~prefix:"-c" w ->
        let* pair = setting w (String.sub w 2 (String.length w - 2)) in
        go (pair :: acc) rest
    | w :: rest when String.starts_with ~prefix:"--" w ->
        let* name, value = setting w (String.sub w 2 (String.length w - 2)) in
        go
          ((String.map (function '-' -> '_' | c -> c) name, value) :: acc)
          rest
    | w :: _ ->
        Error
          (Printf.sprintf
             "options' %S is not a setting: only -c name=value and \
              --name=value are read"
             w)
  in
  go [] (words 0 (Buffer.create 16) [])

let escape_option s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | (' ' | '\\' | '\t' | '\n' | '\r') as c ->
          Buffer.add_char b '\\';
          Buffer.add_char b c
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

let options_to_string settings =
  String.concat " "
    (List.map
       (fun (k, v) -> "-c " ^ escape_option k ^ "=" ^ escape_option v)
       settings)

(* A leading slash means a Unix socket directory, as in libpq. *)
let host_of_string s =
  if String.equal s "" then Tcp "localhost"
  else if Char.equal s.[0] '/' then Unix_socket s
  else Tcp s

let port_of_string p =
  if String.equal p "" then Ok 5432
  else
    match Text.to_int p with
    | Some n when n >= 1 && n <= 65535 -> Ok n
    | Some _ | None -> Error (Printf.sprintf "port %S is not a port" p)

(* [hostaddr] is a literal address, never looked up. *)
let address_of_string a =
  if String.equal a "" then Ok None
  else
    match Ipaddr.of_string a with
    | Ok ip -> Ok (Some ip)
    | Error _ -> Error (Printf.sprintf "hostaddr %S is not an address" a)

let each f s =
  List.fold_right
    (fun x acc ->
      let* acc = acc in
      let* x = f x in
      Ok (x :: acc))
    (String.split_on_char ',' s)
    (Ok [])

(* Ports are one for all hosts or one each; addresses one each. As in
   libpq, [host] is the name TLS verifies and [hostaddr] only where to
   connect; with no host, the address is the host. *)
let endpoints ~hosts ~addresses ports =
  let* addresses =
    match addresses with
    | None -> Ok None
    | Some a ->
        let* a = each address_of_string a in
        Ok (Some a)
  in
  let hosts =
    match (hosts, addresses) with
    | Some h, _ -> String.split_on_char ',' h
    | None, Some a ->
        List.map (function Some ip -> Ipaddr.to_string ip | None -> "") a
    | None, None -> [ "" ]
  in
  let* addresses =
    match addresses with
    | None -> Ok (List.map (fun _ -> None) hosts)
    | Some a when List.compare_lengths a hosts = 0 -> Ok a
    | Some a ->
        Error
          (Printf.sprintf "%d addresses for %d hosts: one each" (List.length a)
             (List.length hosts))
  in
  let* ports =
    match each port_of_string ports with
    | Ok [ port ] -> Ok (List.map (fun _ -> port) hosts)
    | Ok ports when List.compare_lengths ports hosts = 0 -> Ok ports
    | Ok ports ->
        Error
          (Printf.sprintf "%d ports for %d hosts: one for all, or one each"
             (List.length ports) (List.length hosts))
    | Error _ as e -> e
  in
  let endpoint (host, address) port =
    let host =
      match address with
      | Some ip when String.equal host "" -> Tcp (Ipaddr.to_string ip)
      | _ -> host_of_string host
    in
    match (host, address) with
    | Unix_socket d, Some _ ->
        Error
          (Printf.sprintf
             "hostaddr is a TCP address, and %S is a socket's directory" d)
    | _ -> Ok { host; address; port; password = None }
  in
  List.fold_right2
    (fun h p acc ->
      let* acc = acc in
      let* e = endpoint h p in
      Ok (e :: acc))
    (List.combine hosts addresses)
    ports (Ok [])

(* Later pairs win. An empty value unsets the key, as in libpq. *)
let of_pairs pairs =
  let* () =
    List.fold_left
      (fun acc (k, _) ->
        let* () = acc in
        if List.mem k keys then Ok ()
        else if String.equal k "sslpassword" then
          Error
            "the connection string's sslpassword is not read: this driver \
             opens no encrypted client key"
        else
          Error
            (Printf.sprintf
               "the connection string's %S is not a key this driver reads" k))
      (Ok ()) pairs
  in
  let find k =
    List.fold_left
      (fun found (k', v) ->
        if String.equal k k' then if String.equal v "" then None else Some v
        else found)
      None pairs
  in
  let chosen key choices ~default =
    match find key with None -> Ok default | Some s -> one_of key choices s
  in
  let* user =
    match find "user" with
    | Some u -> Ok u
    | None -> Error "the connection string names no user"
  in
  let* hosts =
    endpoints ~hosts:(find "host") ~addresses:(find "hostaddr")
      (Option.value (find "port") ~default:"5432")
  in
  let* ssl_mode = chosen "sslmode" ssl_modes ~default:Prefer in
  let* ssl_negotiation =
    chosen "sslnegotiation"
      [ ("postgres", Postgres); ("direct", Direct) ]
      ~default:Postgres
  in
  let* () =
    match (ssl_negotiation, ssl_mode) with
    | Direct, (Disable | Allow | Prefer) ->
        Error
          (Printf.sprintf
             "sslnegotiation=direct needs sslmode=require or stronger, not %s: \
              anything weaker could fall back to signing in without TLS"
             (ssl_mode_to_string ssl_mode))
    | Direct, (Require | Verify_ca | Verify_full) | Postgres, _ -> Ok ()
  in
  let* channel_binding =
    chosen "channel_binding" channel_bindings ~default:Binding_preferred
  in
  let* () =
    match (channel_binding, ssl_mode) with
    | Binding_required, Disable ->
        Error
          "channel_binding=require needs TLS, which sslmode=disable never uses"
    | _ -> Ok ()
  in
  let* require_auth =
    match find "require_auth" with
    | None -> Ok every_method
    | Some s -> require_auth s
  in
  let* connect_timeout_s =
    match find "connect_timeout" with
    | None -> Ok None
    | Some s -> (
        match Text.to_int s with
        | Some n when n > 0 -> Ok (Some (float_of_int n))
        | Some _ -> Ok None
        | None ->
            Error
              (Printf.sprintf "connect_timeout %S is not a number of seconds" s)
        )
  in
  let* keepalives =
    chosen "keepalives" [ ("1", true); ("0", false) ] ~default:true
  in
  let* target_session_attrs =
    chosen "target_session_attrs" session_attrs ~default:Any
  in
  let* load_balance_hosts =
    chosen "load_balance_hosts"
      [ ("disable", In_order); ("random", Random) ]
      ~default:In_order
  in
  (* 3.0 by default, as libpq 18: many poolers speak only 3.0. *)
  let* min_protocol_version =
    chosen "min_protocol_version" protocol_versions ~default:V3_0
  in
  let* max_protocol_version =
    chosen "max_protocol_version" protocol_versions ~default:V3_0
  in
  let* () =
    if protocol_minor min_protocol_version > protocol_minor max_protocol_version
    then Error "min_protocol_version is above max_protocol_version"
    else Ok ()
  in
  let* options =
    match find "options" with None -> Ok [] | Some s -> options s
  in
  Ok
    {
      hosts;
      user;
      password = find "password";
      database = Option.value (find "dbname") ~default:user;
      ssl_mode;
      ssl_root_cert = find "sslrootcert";
      ssl_cert = find "sslcert";
      ssl_key = find "sslkey";
      ssl_negotiation;
      channel_binding;
      require_auth;
      connect_timeout_s;
      application_name = find "application_name";
      keepalives;
      target_session_attrs;
      load_balance_hosts;
      min_protocol_version;
      max_protocol_version;
      options;
    }

(* URLs *)

let hex c =
  match c with
  | '0' .. '9' -> Some (Char.code c - 48)
  | 'a' .. 'f' -> Some (Char.code c - 87)
  | 'A' .. 'F' -> Some (Char.code c - 55)
  | _ -> None

(* The error names the part, never quotes it: it may be the password. *)
let percent_decode what s =
  let b = Buffer.create (String.length s) in
  let rec go i =
    if i >= String.length s then Ok (Buffer.contents b)
    else
      match s.[i] with
      | '%' -> (
          if i + 2 >= String.length s then
            Error (Printf.sprintf "%s ends inside a percent escape" what)
          else
            match (hex s.[i + 1], hex s.[i + 2]) with
            | Some h, Some l ->
                Buffer.add_char b (Char.chr ((h * 16) + l));
                go (i + 3)
            | _ ->
                Error
                  (Printf.sprintf "%s has a percent escape that is not hex" what)
          )
      | c ->
          Buffer.add_char b c;
          go (i + 1)
  in
  go 0

let split_once c s =
  match String.index_opt s c with
  | Some i ->
      (String.sub s 0 i, Some (String.sub s (i + 1) (String.length s - i - 1)))
  | None -> (s, None)

let rsplit_once c s =
  match String.rindex_opt s c with
  | Some i ->
      (String.sub s 0 i, Some (String.sub s (i + 1) (String.length s - i - 1)))
  | None -> (s, None)

(* Checked here, not quoted: a password holding an unescaped / ends the
   authority inside the password, whose piece lands where the port is. *)
let url_port p =
  if String.for_all (function '0' .. '9' -> true | _ -> false) p then Ok p
  else
    Error
      "the URL's port is not a number, or a password holds an unescaped /, \
       which is written %2F"

(* host[:port]; IPv6 in brackets, a socket directory percent-encoded. *)
let one_authority hostspec =
  if String.length hostspec > 0 && Char.equal hostspec.[0] '[' then
    match String.index_opt hostspec ']' with
    | None -> Error "an IPv6 host with no closing bracket"
    | Some j -> (
        let host = String.sub hostspec 1 (j - 1) in
        match String.sub hostspec (j + 1) (String.length hostspec - j - 1) with
        | "" -> Ok (host, "")
        | rest when Char.equal rest.[0] ':' ->
            let* port = url_port (String.sub rest 1 (String.length rest - 1)) in
            Ok (host, port)
        | _ -> Error "an IPv6 host followed by something other than a port")
  else
    let host, port = rsplit_once ':' hostspec in
    let* host = percent_decode "the URL's host" host in
    let* port = url_port (Option.value port ~default:"") in
    Ok (host, port)

(* Hosts without a port get the default. *)
let authority hostspec =
  if String.equal hostspec "" then Ok []
  else
    let* parts =
      List.fold_right
        (fun h acc ->
          let* acc = acc in
          let* part = one_authority h in
          Ok (part :: acc))
        (String.split_on_char ',' hostspec)
        (Ok [])
    in
    let hosts = String.concat "," (List.map fst parts) in
    let ports = List.map snd parts in
    Ok
      ((if String.equal hosts "" then [] else [ ("host", hosts) ])
      @
      if List.for_all (String.equal "") ports then []
      else [ ("port", String.concat "," ports) ])

let pairs_of_url s =
  let* rest =
    match split_once ':' s with
    | ("postgres" | "postgresql"), Some rest
      when String.starts_with ~prefix:"//" rest ->
        Ok (String.sub rest 2 (String.length rest - 2))
    | _ -> Error "a URL that is not postgres:// or postgresql://"
  in
  let rest, query = split_once '?' rest in
  let rest, path = split_once '/' rest in
  let userinfo, hostspec =
    match rsplit_once '@' rest with
    | u, Some h -> (Some u, h)
    | h, None -> (None, h)
  in
  let* user =
    match userinfo with
    | None -> Ok []
    | Some u -> (
        let user, password = split_once ':' u in
        let* user = percent_decode "the URL's user" user in
        match password with
        | None -> Ok [ ("user", user) ]
        | Some p ->
            let* p = percent_decode "the URL's password" p in
            Ok [ ("user", user); ("password", p) ])
  in
  let* host = authority hostspec in
  let* db =
    match path with
    | None | Some "" -> Ok []
    | Some d ->
        let* d = percent_decode "the URL's database" d in
        Ok [ ("dbname", d) ]
  in
  let* params =
    match query with
    | None | Some "" -> Ok []
    | Some q ->
        List.fold_left
          (fun acc pair ->
            let* acc = acc in
            match split_once '=' pair with
            | k, Some v ->
                let* k = percent_decode "a URL parameter's name" k in
                let* v = percent_decode (Printf.sprintf "the URL's %s" k) v in
                Ok ((k, v) :: acc)
            | k, None ->
                (* Only a key is quoted: a password holding an unescaped ?
                   puts its rest here. *)
                Error
                  (if List.mem k keys then
                     Printf.sprintf "the URL's %s has no value" k
                   else
                     "a URL parameter has no value, or a password holds an \
                      unescaped ?, which is written %3F"))
          (Ok [])
          (List.filter
             (fun p -> not (String.equal p ""))
             (String.split_on_char '&' q))
        |> Result.map List.rev
  in
  Ok (user @ host @ db @ params)

(* Keyword/value strings *)

let is_space c =
  Char.equal c ' ' || Char.equal c '\t' || Char.equal c '\n'
  || Char.equal c '\r'

(* Spaces around [=] are allowed; values are bare or single-quoted, with
   backslash escapes in both. *)
let pairs_of_keywords s =
  let n = String.length s in
  let rec skip i = if i < n && is_space s.[i] then skip (i + 1) else i in
  let value i =
    let b = Buffer.create 16 in
    if i < n && Char.equal s.[i] '\'' then
      let rec go j =
        if j >= n then Error "a quoted value with no closing quote"
        else
          match s.[j] with
          | '\\' when j + 1 < n ->
              Buffer.add_char b s.[j + 1];
              go (j + 2)
          | '\'' -> Ok (Buffer.contents b, j + 1)
          | c ->
              Buffer.add_char b c;
              go (j + 1)
      in
      go (i + 1)
    else
      let rec go j =
        if j >= n || is_space s.[j] then Ok (Buffer.contents b, j)
        else
          match s.[j] with
          | '\\' when j + 1 < n ->
              Buffer.add_char b s.[j + 1];
              go (j + 2)
          | c ->
              Buffer.add_char b c;
              go (j + 1)
      in
      go i
  in
  let rec pairs i acc =
    let i = skip i in
    if i >= n then Ok (List.rev acc)
    else
      let rec key_end j =
        if j < n && (not (is_space s.[j])) && not (Char.equal s.[j] '=') then
          key_end (j + 1)
        else j
      in
      let k = key_end i in
      let key = String.sub s i (k - i) in
      let e = skip k in
      if e >= n || not (Char.equal s.[e] '=') then
        Error (Printf.sprintf "the connection string's %S has no =" key)
      else
        let* v, next = value (skip (e + 1)) in
        pairs next ((key, v) :: acc)
  in
  pairs 0 []

(* [://] before any [=] means a URL, so a wrong scheme is refused as a URL
   rather than misread as keywords. *)
let of_string ?(defaults = []) s =
  let rec scheme i =
    i + 3 <= String.length s
    && (not (Char.equal s.[i] '='))
    && (String.equal (String.sub s i 3) "://" || scheme (i + 1))
  in
  let* pairs = if scheme 0 then pairs_of_url s else pairs_of_keywords s in
  of_pairs (defaults @ pairs)

(* Environment and .pgpass *)

let variables =
  [
    ("PGHOST", "host");
    ("PGHOSTADDR", "hostaddr");
    ("PGPORT", "port");
    ("PGUSER", "user");
    ("PGPASSWORD", "password");
    ("PGDATABASE", "dbname");
    ("PGSSLMODE", "sslmode");
    ("PGSSLROOTCERT", "sslrootcert");
    ("PGSSLCERT", "sslcert");
    ("PGSSLKEY", "sslkey");
    ("PGSSLNEGOTIATION", "sslnegotiation");
    ("PGCHANNELBINDING", "channel_binding");
    ("PGREQUIREAUTH", "require_auth");
    ("PGCONNECT_TIMEOUT", "connect_timeout");
    ("PGAPPNAME", "application_name");
    ("PGTARGETSESSIONATTRS", "target_session_attrs");
    ("PGLOADBALANCEHOSTS", "load_balance_hosts");
    ("PGMINPROTOCOLVERSION", "min_protocol_version");
    ("PGMAXPROTOCOLVERSION", "max_protocol_version");
    ("PGOPTIONS", "options");
  ]

let environment getenv =
  List.filter_map
    (fun (variable, key) ->
      match getenv variable with
      | Some v when not (String.equal v "") -> Some (key, v)
      | Some _ | None -> None)
    variables

(* Four fields ended by unescaped colons, then the password: the rest of
   the line, where colons need no escape. *)
let passfile_line line =
  let n = String.length line in

  let unescaped i ~at_colon =
    let b = Buffer.create 16 in
    let rec go j =
      if j >= n then (Buffer.contents b, n)
      else
        match line.[j] with
        | '\\' when j + 1 < n ->
            Buffer.add_char b line.[j + 1];
            go (j + 2)
        | ':' when at_colon -> (Buffer.contents b, j + 1)
        | c ->
            Buffer.add_char b c;
            go (j + 1)
    in
    go i
  in
  let rec fields i acc =
    if List.compare_length_with acc 4 = 0 then
      Some (List.rev acc, fst (unescaped i ~at_colon:false))
    else if i >= n then None
    else
      let field, next = unescaped i ~at_colon:true in
      fields next (field :: acc)
  in
  fields 0 []

let passfile contents t =
  match t.password with
  | Some _ -> t
  | None ->
      let entries =
        List.filter_map
          (fun line ->
            let line =
              if String.ends_with ~suffix:"\r" line then
                String.sub line 0 (String.length line - 1)
              else line
            in
            if
              String.equal (String.trim line) ""
              || String.starts_with ~prefix:"#" line
            then None
            else passfile_line line)
          (String.split_on_char '\n' contents)
      in
      let matches pattern value =
        String.equal pattern "*" || String.equal pattern value
      in
      let lookup (e : endpoint) =
        let host = match e.host with Tcp h -> h | Unix_socket d -> d in
        List.find_map
          (fun (fields, password) ->
            match fields with
            | [ h; p; d; u ] ->
                if
                  matches h host
                  && matches p (string_of_int e.port)
                  && matches d t.database && matches u t.user
                then Some password
                else None
            | _ -> None)
          entries
      in
      {
        t with
        hosts =
          List.map
            (fun (e : endpoint) -> { e with password = lookup e })
            t.hosts;
      }

(* Printing *)

let unreserved c =
  match c with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
  | _ -> false

let percent_encode s =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      if unreserved c then Buffer.add_char b c
      else Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents b

(* Only non-default fields are printed, so a URL reads back as the same
   record (minus .pgpass passwords). *)
let to_url t =
  let host (e : endpoint) =
    (match e.host with
      | Tcp h when String.contains h ':' -> "[" ^ h ^ "]"
      | Tcp h -> percent_encode h
      | Unix_socket d -> percent_encode d)
    ^ ":" ^ string_of_int e.port
  in
  let userinfo =
    percent_encode t.user
    ^ match t.password with Some p -> ":" ^ percent_encode p | None -> ""
  in
  let query =
    List.filter_map
      (fun (k, v) -> Option.map (fun v -> k ^ "=" ^ percent_encode v) v)
      [
        ( "hostaddr",
          if
            List.exists (fun (e : endpoint) -> Option.is_some e.address) t.hosts
          then
            Some
              (String.concat ","
                 (List.map
                    (fun (e : endpoint) ->
                      Option.fold ~none:"" ~some:Ipaddr.to_string e.address)
                    t.hosts))
          else None );
        ("sslmode", Some (ssl_mode_to_string t.ssl_mode));
        ("sslrootcert", t.ssl_root_cert);
        ("sslcert", t.ssl_cert);
        ("sslkey", t.ssl_key);
        ( "sslnegotiation",
          match t.ssl_negotiation with
          | Postgres -> None
          | Direct -> Some "direct" );
        ( "channel_binding",
          match t.channel_binding with
          | Binding_preferred -> None
          | Binding_disabled -> Some "disable"
          | Binding_required -> Some "require" );
        ( "require_auth",
          if
            t.require_auth.password && t.require_auth.md5
            && t.require_auth.scram_sha_256 && t.require_auth.none
          then None
          else Some (require_auth_to_string t.require_auth) );
        ( "connect_timeout",
          Option.map
            (fun s -> string_of_int (int_of_float (Float.ceil s)))
            t.connect_timeout_s );
        ("application_name", t.application_name);
        ("keepalives", if t.keepalives then None else Some "0");
        ( "target_session_attrs",
          match t.target_session_attrs with
          | Any -> None
          | Read_write -> Some "read-write"
          | Read_only -> Some "read-only"
          | Primary -> Some "primary"
          | Standby -> Some "standby"
          | Prefer_standby -> Some "prefer-standby" );
        ( "load_balance_hosts",
          match t.load_balance_hosts with
          | In_order -> None
          | Random -> Some "random" );
        ( "min_protocol_version",
          match t.min_protocol_version with V3_0 -> None | V3_2 -> Some "3.2" );
        ( "max_protocol_version",
          match t.max_protocol_version with V3_0 -> None | V3_2 -> Some "3.2" );
        ( "options",
          match t.options with
          | [] -> None
          | settings -> Some (options_to_string settings) );
      ]
  in
  Printf.sprintf "postgres://%s@%s/%s?%s" userinfo
    (String.concat "," (List.map host t.hosts))
    (percent_encode t.database)
    (String.concat "&" query)
