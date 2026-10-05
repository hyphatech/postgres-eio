(** A statement's command tag, parsed. *)

type t

val empty : t
(** An empty query's: no command and no rows. *)

val of_string : string -> t
(** A CommandComplete's tag, ["INSERT 0 1"]; one this module does not know is
    kept whole as its command, with no rows. *)

val command : t -> string
(** [UPDATE], [INSERT], [COMMIT], [ROLLBACK], ... Check this after [COMMIT]: in
    an aborted transaction the server answers [ROLLBACK]. *)

val rows : t -> int option
(** Rows changed or returned, for [INSERT], [SELECT], [UPDATE], [DELETE],
    [MERGE], [FETCH], [MOVE] and [COPY]. *)
