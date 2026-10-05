(** A Postgres driver for Eio.

    Protocol 3.0 and 3.2 over TCP, a Unix socket or TLS, with multi-host
    failover. Sign-in by SCRAM-SHA-256 (with channel binding when offered), MD5,
    client certificate, trust, or cleartext inside TLS only.

    Connections cache and pipeline statements, run batches in one round trip,
    COPY in and out, and read results as text or binary. {!Listener} receives
    notifications; {!Pool} lends connections in a clean state.

    The lower layers do no IO and can be used alone: {!module-Protocol}
    (messages and bytes), {!Auth} (sign-in exchanges), {!Conninfo} (connection
    strings), {!Text}, {!Value} and {!Interval} (cell values). *)

module Protocol = Protocol
module Auth = Auth
module Conninfo = Conninfo
module Server_error = Server_error
module Tag = Tag
module Interval = Interval
module Text = Text
module Column = Column
module Value = Value

include module type of struct
  include Connection
end

module Pool = Pool
