type format = Protocol.format = Text | Binary
type t = { name : string; type_oid : Oid.t; format : format }
