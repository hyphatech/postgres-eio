(* libpq refuses a .pgpass that others can read; checking that is the
   program's, as is finding the file. *)
let contents () =
  match Sys.getenv_opt "HOME" with
  | None -> ""
  | Some home -> (
      match
        In_channel.with_open_bin
          (Filename.concat home ".pgpass")
          In_channel.input_all
      with
      | contents -> contents
      | exception Sys_error _ -> "")
