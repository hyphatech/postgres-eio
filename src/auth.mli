(** SCRAM-SHA-256 and MD5 sign-in, without IO or randomness: the caller supplies
    the nonce. Nothing is logged, and no error contains a password, proof or
    message bytes. *)

val md5 : user:string -> password:string -> salt:string -> string
(** The AuthenticationMD5Password response:
    ["md5" ^ hex (md5 (hex (md5 (password ^ user)) ^ salt))] (protocol 54.3). *)

(** {1 SCRAM-SHA-256}

    RFC 5802 and RFC 7677 as Postgres uses them (protocol 54.3.1). Channel
    binding is [tls-server-end-point], the only type Postgres offers, under
    {!mechanism_plus}. Passwords go through SASLprep exactly as Postgres applies
    it. *)

val mechanism : string
(** ["SCRAM-SHA-256"] *)

val mechanism_plus : string
(** ["SCRAM-SHA-256-PLUS"], with channel binding. *)

type binding =
  | Unsupported  (** the client cannot bind: no TLS -- ["n,,"] *)
  | Not_offered
      (** the client could bind but the server did not offer it -- ["y,,"],
          which exposes a stripped offer *)
  | Bound of string
      (** bound to {!tls_server_end_point}'s data --
          ["p=tls-server-end-point,,"] *)

val tls_server_end_point : X509.Certificate.t -> string option
(** RFC 5929 §4.1 binding data: the certificate's DER hashed with its
    signature's hash (SHA-256 for MD5 or SHA-1). [None] for Ed25519, which has
    no hash and which Postgres cannot bind to. *)

type scram
(** After the client-first-message. *)

type proven
(** After the client's proof, awaiting the server's. *)

val client_first :
  ?user:string ->
  ?binding:binding ->
  password:string ->
  nonce:string ->
  unit ->
  scram * string
(** The client-first-message for SASLInitialResponse. [user] defaults to empty,
    as the server uses the startup message's; [binding] defaults to
    [Unsupported]; [nonce] must be printable with no comma. *)

val client_final : scram -> string -> (proven * string, string) result
(** The client-final-message for the server-first-message. Errors on a nonce
    that does not extend the client's, a non-base64 salt, a non-positive
    iteration count, or a mandatory extension. *)

val verify : proven -> string -> (unit, string) result
(** Checks the server-final-message proves the server knows the password. An
    [e=] message is an error. *)
