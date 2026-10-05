(* SCRAM-SHA-256 (RFC 5802, RFC 7677, protocol 54.3.1) and MD5, without IO.
   The nonce is passed in, so an exchange can be tested. *)

let ( let* ) = Result.bind
let md5_hex s = Digest.MD5.to_hex (Digest.MD5.string s)

(* 54.3: concat('md5', md5(concat(md5(concat(password, username)),
   random-salt))), the inner digest in hex. *)
let md5 ~user ~password ~salt =
  "md5" ^ md5_hex (md5_hex (password ^ user) ^ salt)

module H = Digestif.SHA256

let hmac key s = H.to_raw_string (H.hmac_string ~key s)
let sha256 s = H.to_raw_string (H.digest_string s)

let xor a b =
  String.init (String.length a) (fun i ->
      Char.chr (Char.code a.[i] lxor Char.code b.[i]))

(* RFC 5802 §2.2 Hi: PBKDF2-HMAC-SHA-256, one block. *)
let hi password salt iterations =
  let u1 = hmac password (salt ^ "\000\000\000\001") in
  let rec go i u acc =
    if i > iterations then acc
    else
      let u = hmac password u in
      go (i + 1) u (xor acc u)
  in
  go 2 u1 u1

let b64 s = Base64.encode_string s

let unb64 what s =
  match Base64.decode s with
  | Ok v -> Ok v
  | Error (`Msg _) -> Error (Printf.sprintf "%s is not base64" what)

(* RFC 5802 §5.1: '=' and ',' are escaped as =3D and =2C. *)
let saslname s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | '=' -> Buffer.add_string b "=3D"
      | ',' -> Buffer.add_string b "=2C"
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

let mechanism = "SCRAM-SHA-256"
let mechanism_plus = "SCRAM-SHA-256-PLUS"

type binding = Unsupported | Not_offered | Bound of string

(* RFC 5929 §4.1: hash with the signature's hash, upgrading MD5 and SHA-1
   to SHA-256. Ed25519 has no hash, and Postgres cannot bind to it. *)
let tls_server_end_point certificate =
  match X509.Certificate.signature_algorithm certificate with
  | None | Some (`ED25519, _) -> None
  | Some ((`RSA_PSS | `RSA_PKCS1 | `ECDSA), hash) ->
      let hash = match hash with `MD5 | `SHA1 -> `SHA256 | h -> h in
      Some (X509.Certificate.fingerprint hash certificate)

(* RFC 5802 §7: "p" binds; "y" means the client could but the server did
   not offer it, which exposes a downgrade; "n" means the client cannot. *)
let gs2_header = function
  | Unsupported -> "n,,"
  | Not_offered -> "y,,"
  | Bound _ -> "p=tls-server-end-point,,"

let channel_binding binding =
  gs2_header binding
  ^ match binding with Bound data -> data | Unsupported | Not_offered -> ""

type scram = {
  password : string;
  client_first_bare : string;
  nonce : string;
  binding : binding;
}

type proven = { server_signature : string }

let client_first ?(user = "") ?(binding = Unsupported) ~password ~nonce () =
  (* 54.3.1: the server uses the startup message's user, so this may be
     empty. *)
  let client_first_bare = "n=" ^ saslname user ^ ",r=" ^ nonce in
  ( { password = Saslprep.password password; client_first_bare; nonce; binding },
    gs2_header binding ^ client_first_bare )

(* RFC 5802 §5.1 attributes, in order: r=, s=, i=. A leading m= is a
   mandatory extension; later ones may be ignored. *)
let attributes s =
  List.map
    (fun part ->
      match String.index_opt part '=' with
      | Some 1 -> (part.[0], String.sub part 2 (String.length part - 2))
      | Some _ | None -> ('\000', part))
    (String.split_on_char ',' s)

let client_final t server_first =
  match attributes server_first with
  | ('m', _) :: _ ->
      Error "the server asked for a SCRAM extension no client here knows"
  | ('r', nonce) :: ('s', salt) :: ('i', iterations) :: _ -> (
      if
        not
          (String.length nonce > String.length t.nonce
          && String.starts_with ~prefix:t.nonce nonce)
      then Error "the server's nonce does not continue the client's"
      else
        let* salt = unb64 "the server's salt" salt in
        match int_of_string_opt iterations with
        | Some i when i >= 1 ->
            let salted = hi t.password salt i in
            let client_key = hmac salted "Client Key" in
            let stored_key = sha256 client_key in
            let without_proof =
              "c=" ^ b64 (channel_binding t.binding) ^ ",r=" ^ nonce
            in
            let auth_message =
              t.client_first_bare ^ "," ^ server_first ^ "," ^ without_proof
            in
            let proof = xor client_key (hmac stored_key auth_message) in
            let server_signature =
              hmac (hmac salted "Server Key") auth_message
            in
            Ok ({ server_signature }, without_proof ^ ",p=" ^ b64 proof)
        | Some _ | None ->
            Error "the server's iteration count is not a positive number")
  | _ -> Error "the server's first SCRAM message is not r=, s=, i="

(* The server must prove it knows the password too. *)
let verify t server_final =
  match attributes server_final with
  | ('e', reason) :: _ -> Error ("the server refused the proof: " ^ reason)
  | ('v', signature) :: _ ->
      let* signature = unb64 "the server's signature" signature in
      if String.equal signature t.server_signature then Ok ()
      else Error "the server's signature is not the password's"
  | _ -> Error "the server's final SCRAM message is neither v= nor e="
