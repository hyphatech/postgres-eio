(** Protocol 3.0 and 3.2 messages, without IO.

    {!encode} turns a frontend message into bytes. A {!type-reader} takes
    backend bytes split anywhere and yields messages. Errors name the section of
    chapter 54 of the Postgres 18 docs that was violated. *)

type transaction_status =
  | Idle  (** not in a transaction block *)
  | In_transaction
  | Failed  (** in a transaction block that a failed statement aborted *)

(** {1 Frontend} *)

type target =
  | Statement  (** a prepared statement, made by Parse *)
  | Portal  (** a portal, made by Bind *)

type format = Text | Binary

type frontend =
  | Startup of { minor : int; parameters : (string * string) list }
      (** StartupMessage for protocol 3.[minor]: [user], [database] and every
          other parameter, in order *)
  | Ssl_request
  | Cancel_request of { pid : int; key : string }
  | Password of string  (** PasswordMessage: cleartext, or MD5's answer *)
  | Sasl_initial_response of { mechanism : string; data : string }
  | Sasl_response of string
  | Query of string  (** a simple query *)
  | Parse of { name : string; query : string }
      (** with no parameter types, so the server infers each; [""] is the
          unnamed statement *)
  | Bind of {
      portal : string;
      statement : string;
      params : string option list;
      results : format list;
    }
      (** every parameter in text, [None] for NULL; the result columns in the
          formats given, one each, or every one in text when none is *)
  | Execute of { portal : string; max_rows : int }  (** [0] is every row *)
  | Describe of { target : target; name : string }
      (** answered by a statement's ParameterDescription and its RowDescription
          or NoData, or a portal's RowDescription or NoData *)
  | Close of { target : target; name : string }
      (** answered by CloseComplete, even for a name that does not exist *)
  | Sync
  | Terminate
  | Copy_data of string
      (** bytes of a COPY FROM STDIN, split wherever the sender likes *)
  | Copy_done
  | Copy_fail of string  (** ends a COPY FROM STDIN as failed, saying why *)

val encode : frontend -> (string, string) result
(** Errors on a NUL inside a String, too many Bind parameters, or a message too
    long for its length field. *)

(** {1 Backend} *)

type authentication =
  | Accepted  (** AuthenticationOk *)
  | Kerberos_v5
  | Cleartext_password
  | Md5_password of string  (** the four-byte salt *)
  | Gss
  | Gss_continue of string
  | Sspi
  | Sasl of string list  (** the mechanisms the server offers *)
  | Sasl_continue of string
  | Sasl_final of string

type field = {
  name : string;
  table : Oid.t;  (** the table's, or [0] for an expression *)
  column : int;  (** the column's number in its table, or [0] *)
  type_oid : Oid.t;
  type_size : int;
  type_modifier : int;
  format : format;
}
(** One column of a RowDescription. *)

type copy = { format : format; columns : format list }
(** A Copy*Response: the overall format and each column's. *)

type backend =
  | Authentication of authentication
  | Backend_key_data of { pid : int; key : string }
      (** [key] is 3.0's four bytes, or under 3.2 up to 256 *)
  | Parameter_status of { name : string; value : string }
  | Ready_for_query of transaction_status
  | Row_description of field list
  | Data_row of string option array  (** [None] is NULL *)
  | Command_complete of string  (** the command tag *)
  | Empty_query_response
  | Error_response of (char * string) list
      (** each field by its code byte, in the order sent *)
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

type reader

val reader : ?limit:int -> unit -> reader
(** An empty reader. Messages over [limit] bytes (1 GiB) are refused. *)

val feed : reader -> Cstruct.t -> unit
(** Copies the bytes in, so the caller may reuse the buffer at once. *)

val next : reader -> (backend option, string) result
(** The next whole message, or [None] if more bytes are needed. After an error
    the reader must not be used again: message boundaries are lost. *)

val buffered : reader -> int
(** Bytes held but not yet returned as a message. *)
