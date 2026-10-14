(** Connection strings, in both libpq forms: a [postgres://] or [postgresql://]
    URL, or keyword/value ([host=db user=app password='a b']).

    Supported keys: [host], [hostaddr], [port], [user], [password], [dbname],
    [sslmode], [sslrootcert], [sslcert], [sslkey], [sslnegotiation],
    [channel_binding], [require_auth], [connect_timeout], [application_name],
    [keepalives], [target_session_attrs], [load_balance_hosts],
    [min_protocol_version], [max_protocol_version] and [options]. Any other key,
    [sslpassword] included, is an error. An empty value unsets a key. URLs are
    percent-decoded; keyword values may be single-quoted, with backslash
    escapes.

    No IO: {!environment} and {!passfile} take what they read from the caller.
*)

(** How a host is reached over TLS, as libpq means each.

    With no [sslmode], a host on this machine -- [localhost], an address in
    127.0.0.0/8, [::1], or a Unix socket -- is [Prefer], since its traffic never
    leaves the machine, and any other host is [Require], so a connection that
    crosses a network is encrypted unless the string says otherwise. With
    [sslnegotiation=direct], every host is [Require]. The mode is decided per
    host, by where the connection goes: [hostaddr] when given, else [host]. *)
type ssl_mode =
  | Disable  (** never TLS *)
  | Allow  (** plain, and TLS only if the server refuses plain *)
  | Prefer
      (** TLS if the server offers it and the handshake succeeds, else plain *)
  | Require
      (** encrypted, and the server's certificate not checked: safe from a
          listener, not from a server that pretends *)
  | Verify_ca
      (** encrypted, and the certificate checked against [sslrootcert], or the
          system's authorities when absent *)
  | Verify_full
      (** as [Verify_ca], and the certificate checked to name the host: the one
          that proves the server is the one named, and the mode for production
      *)

type ssl_negotiation =
  | Postgres  (** SSLRequest first *)
  | Direct
      (** TLS from the first byte with ALPN [postgresql], saving a round trip;
          an [sslmode] given is [require] or stronger, and none is [require] *)

type channel_binding =
  | Binding_disabled
  | Binding_preferred  (** bind when offered -- the default *)
  | Binding_required  (** refuse, before sending secrets, if not bound *)

type auth_methods = private {
  password : bool;  (** a cleartext password, inside TLS *)
  md5 : bool;
  scram_sha_256 : bool;
  none : bool;  (** no authentication (trust) *)
}
(** Methods [require_auth] allows; all by default. *)

type session_attrs =
  | Any
  | Read_write  (** not a standby, not [default_transaction_read_only] *)
  | Read_only
  | Primary  (** not a standby *)
  | Standby
  | Prefer_standby  (** a standby if any, else any host *)

type load_balance =
  | In_order  (** hosts and their addresses in the order given *)
  | Random  (** hosts and addresses shuffled *)

type protocol_version = V3_0 | V3_2

type host =
  | Tcp of string  (** a name or an address *)
  | Unix_socket of string
      (** the directory of [.s.PGSQL.<port>]; a host starting with [/] *)

type endpoint = private {
  host : host;
      (** the name TLS verifies; [localhost] by default, or the address when
          only [hostaddr] is given *)
  address : Ipaddr.t option;
      (** [hostaddr]: connect here without looking up [host]. Never with a Unix
          socket. *)
  port : int;  (** default 5432 *)
  password : string option;
      (** from {!passfile}, used when [password] is absent *)
  ssl_mode : ssl_mode;
      (** how this host is reached: the connection string's [sslmode], or the
          default for where it is (see {!type-ssl_mode}) *)
}

type t = private {
  hosts : endpoint list;
      (** at least one: [host=a,b port=1,2], or [postgres://a:1,b:2/] *)
  user : string;  (** required *)
  password : string option;
  database : string;  (** defaults to [user] *)
  ssl_mode : ssl_mode option;
      (** [sslmode] as the string gives it; [None] where it gives none, and each
          host's {!endpoint.ssl_mode} is the default for where it is *)
  ssl_root_cert : string option;
      (** PEM CA file for verification; the system's when absent. Only
          [sslmode=verify-full] and [verify-ca] read it, so with any other mode,
          or none, it is refused rather than ignored. *)
  ssl_cert : string option;  (** PEM client certificate chain *)
  ssl_key : string option;  (** PEM client key, unencrypted *)
  ssl_negotiation : ssl_negotiation;
  channel_binding : channel_binding;
  require_auth : auth_methods;
  connect_timeout : Mtime.Span.t option;
      (** per address attempt, from [connect_timeout] in whole seconds as libpq
          reads it, where [0] or less is absent; when absent or zero, the
          connection's [timeout] bounds each attempt instead *)
  application_name : string option;
  keepalives : bool;  (** TCP keepalive, unless [keepalives=0] *)
  target_session_attrs : session_attrs;
  load_balance_hosts : load_balance;
  min_protocol_version : protocol_version;  (** default 3.0 *)
  max_protocol_version : protocol_version;
      (** default 3.0, since many poolers speak only 3.0; [latest] is 3.2 *)
  options : (string * string) list;
      (** [-c name=value], [-cname=value] and [--name=value] from [options],
          sent as startup parameters *)
}
(** Read by its fields, and made by {!of_string}: a key is set in the connection
    string, or by {!with_database} and {!with_connect_timeout}. *)

val of_string : ?defaults:(string * string) list -> string -> (t, string) result
(** Parses either form. [defaults] (e.g. from {!environment}) fill keys the
    string omits. *)

val environment : (string -> string option) -> (string * string) list
(** The libpq [PG*] variables for supported keys ([PGHOST], [PGPORT], [PGUSER],
    [PGPASSWORD], ...) as {!of_string} defaults: [environment Sys.getenv_opt].
    Empty variables are ignored. *)

val passfile : string -> t -> t
(** Fills each host's password from [.pgpass] contents when the string gave
    none, as libpq: [host:port:database:user:password], [*] wildcards, backslash
    escapes, first match wins. Hosts match as written (a socket by its
    directory). Locating the file and checking its permissions (libpq refuses
    one others can read) is the caller's job. *)

val with_database : t -> string -> t
(** [t] connecting to another database, as [dbname] names it: the empty string
    is the user's name. *)

val with_connect_timeout : t -> Mtime.Span.t -> t
(** [t] bounding each address attempt by the span, as [connect_timeout] does. *)

val to_url : t -> string
(** A URL that parses back to [t], minus {!passfile} passwords.
    [connect_timeout] is written in whole seconds, rounded up, so a span between
    them parses back one second longer at most. *)

val ssl_mode_to_string : ssl_mode -> string
(** E.g. [verify-full]. *)
