(** A column of a result, as the server describes it before the first row. *)

type format = Protocol.format =
  | Text  (** the type's text form, as [psql] prints it *)
  | Binary  (** the type's binary form, as the server stores it *)

type t = {
  name : string;  (** as the select names it, [?column?] when it does not *)
  type_oid : Oid.t;  (** the type, by its row in [pg_type]: [23] is [int4] *)
  format : format;
}
