type t = int

(* The protocol carries an OID as four unsigned bytes. *)
let largest = 0xFFFF_FFFF
let of_int n = if n >= 0 && n <= largest then Some n else None
let to_int t = t
let equal = Int.equal
