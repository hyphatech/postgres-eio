(* The house rules a reader of the source can check: run by [dune test], so
   CI and an agent find a broken rule as a failing test naming the line. *)

let src = "../src"
let read path = In_channel.with_open_bin path In_channel.input_all

(* OCAML.md's fenced [refused] block, one name a line: the shared list every
   Hypha OCaml library refuses, read here so this repository keeps no copy. *)
let refused () =
  let rec skip_to_block = function
    | [] -> []
    | line :: rest when String.equal (String.trim line) "```refused" -> rest
    | _ :: rest -> skip_to_block rest
  in
  let rec names acc = function
    | [] -> Alcotest.fail "OCAML.md: no ```refused block, or one never closed"
    | line :: _ when String.equal (String.trim line) "```" -> List.rev acc
    | line :: rest -> (
        match String.trim line with
        | "" -> names acc rest
        | name -> names (name :: acc) rest)
  in
  match
    read "../OCAML.md" |> String.split_on_char '\n' |> skip_to_block |> names []
  with
  | [] -> Alcotest.fail "OCAML.md: no names in a ```refused block"
  | names -> names

(* An identifier, dotted path included and [Stdlib.] taken off, and the
   reason it is refused: OCAML.md's list, and the [open] its checklist
   refuses, since nothing in this library is made to be opened. *)
let banned () =
  ("open", "use a module alias, not open")
  :: List.map
       (fun name -> (name, "refused by OCAML.md, Shared shapes"))
       (refused ())

(* The source with comments, string literals and character literals blanked
   to spaces, newlines kept, so what is left is code and lines still count. *)
let code_of s =
  let n = String.length s in
  let out = Bytes.of_string s in
  let blank i = if not (Char.equal s.[i] '\n') then Bytes.set out i ' ' in
  let rec string i =
    if i >= n then i
    else (
      blank i;
      match s.[i] with
      | '\\' when i + 1 < n ->
          blank (i + 1);
          string (i + 2)
      | '"' -> i + 1
      | _ -> string (i + 1))
  in
  (* {id|...|id}, with [id] lowercase letters or underscores. *)
  let quoted i =
    let j = ref (i + 1) in
    while !j < n && match s.[!j] with 'a' .. 'z' | '_' -> true | _ -> false do
      incr j
    done;
    if !j < n && Char.equal s.[!j] '|' then (
      let close = "|" ^ String.sub s (i + 1) (!j - i - 1) ^ "}" in
      let k = ref (!j + 1) in
      while
        !k + String.length close <= n
        && not (String.equal (String.sub s !k (String.length close)) close)
      do
        incr k
      done;
      let stop = Int.min n (!k + String.length close) in
      for x = i to stop - 1 do
        blank x
      done;
      Some stop)
    else None
  in
  (* 'x', '\n', '\'' and '\123'; a type variable's quote is left alone. *)
  let char i =
    if i + 2 < n && Char.equal s.[i + 1] '\\' then (
      let j = ref (i + 2) in
      while !j < n && not (Char.equal s.[!j] '\'') do
        incr j
      done;
      if !j - i <= 5 then (
        for x = i to !j do
          blank x
        done;
        Some (!j + 1))
      else None)
    else if i + 2 < n && Char.equal s.[i + 2] '\'' then (
      for x = i to i + 2 do
        blank x
      done;
      Some (i + 3))
    else None
  in
  let rec comment depth i =
    if i >= n then i
    else if i + 1 < n && Char.equal s.[i] '(' && Char.equal s.[i + 1] '*' then (
      blank i;
      blank (i + 1);
      comment (depth + 1) (i + 2))
    else if i + 1 < n && Char.equal s.[i] '*' && Char.equal s.[i + 1] ')' then (
      blank i;
      blank (i + 1);
      if depth = 1 then i + 2 else comment (depth - 1) (i + 2))
    else if Char.equal s.[i] '"' then (
      blank i;
      comment depth (string (i + 1)))
    else (
      blank i;
      comment depth (i + 1))
  in
  let rec go i =
    if i >= n then ()
    else
      match s.[i] with
      | '(' when i + 1 < n && Char.equal s.[i + 1] '*' -> go (comment 0 i)
      | '"' ->
          blank i;
          go (string (i + 1))
      | '{' -> ( match quoted i with Some j -> go j | None -> go (i + 1))
      | '\'' -> ( match char i with Some j -> go j | None -> go (i + 1))
      | _ -> go (i + 1)
  in
  go 0;
  Bytes.to_string out

let is_ident_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '\'' | '.' -> true
  | _ -> false

(* Every identifier, dotted path included, with its line. A field access
   ([t.open]) begins with a lowercase name and so never matches a banned
   path, and a path never ends in a dot. *)
let identifiers code =
  let n = String.length code in
  let rec go i line acc =
    if i >= n then List.rev acc
    else if Char.equal code.[i] '\n' then go (i + 1) (line + 1) acc
    else if is_ident_char code.[i] && not (Char.equal code.[i] '.') then (
      let j = ref i in
      while !j < n && is_ident_char code.[!j] do
        incr j
      done;
      let word = String.sub code i (!j - i) in
      let word =
        if String.ends_with ~suffix:"." word then
          String.sub word 0 (String.length word - 1)
        else word
      in
      go !j line ((line, word) :: acc))
    else go (i + 1) line acc
  in
  go 0 1 []

let sources suffix =
  Sys.readdir src |> Array.to_list
  |> List.filter (String.ends_with ~suffix)
  |> List.sort String.compare

(* A name is read with a leading [Stdlib.] taken off, so [Stdlib.exit] is
   [exit]. *)
let unqualified word =
  match String.starts_with ~prefix:"Stdlib." word with
  | true -> String.sub word 7 (String.length word - 7)
  | false -> word

(* Each banned identifier in [source], a file's text, as a line naming it. *)
let banned_in file source =
  let banned =
    List.map (fun (name, why) -> (unqualified name, why)) (banned ())
  in
  identifiers (code_of source)
  |> List.map (fun (line, word) -> (line, unqualified word))
  |> List.filter_map (fun (line, word) ->
      List.assoc_opt word banned
      |> Option.map (fun why ->
          Printf.sprintf "src/%s:%d: %s -- %s" file line word why))

let no_banned_identifier () =
  let found =
    List.concat_map
      (fun file -> banned_in file (read (Filename.concat src file)))
      (sources ".ml" @ sources ".mli")
  in
  Alcotest.(check (list string)) "banned identifiers" [] found

let the_refusals_are_read_from_ocaml_md () =
  let names = refused () in
  List.iter
    (fun name ->
      Alcotest.(check bool) name true (List.exists (String.equal name) names))
    [ "failwith"; "Stdlib.compare"; "Unix.sleepf"; "Eio.Time.sleep_until" ];
  List.iter
    (fun source ->
      Alcotest.(check int) source 1 (List.length (banned_in "row.ml" source)))
    [ "let _ = failwith"; "let _ = Stdlib.exit"; "let _ = Unix.sleepf 1." ]

(* A clock becomes an instant in one place, written one way:
   [Ptime.of_float_s (Eio.Time.now clock)]. Any other [Eio.Time.now] is a
   time in a bare number. *)
let bare_clock_reads file source =
  let code = code_of source in
  let n = String.length code in
  let now = "Eio.Time.now" and of_float = "Ptime.of_float_s" in
  let is_space c = Char.equal c ' ' || Char.equal c '\n' in
  let at i w =
    i >= 0
    && i + String.length w <= n
    && String.equal (String.sub code i (String.length w)) w
  in
  let rec back i = if i >= 0 && is_space code.[i] then back (i - 1) else i in
  let rec forward i =
    if i < n && is_space code.[i] then forward (i + 1) else i
  in
  let wrapped i =
    let paren = back (i - 1) in
    let before = back (paren - 1) - String.length of_float + 1 in
    let clock = forward (i + String.length now) in
    let j = ref clock in
    while !j < n && is_ident_char code.[!j] do
      incr j
    done;
    let close = forward !j in
    at paren "(" && at before of_float
    && (before = 0 || not (is_ident_char code.[before - 1]))
    && !j > clock && at close ")"
  in
  let line_of i =
    let l = ref 1 in
    for x = 0 to i - 1 do
      if Char.equal code.[x] '\n' then incr l
    done;
    !l
  in
  let rec go i acc =
    if i >= n then List.rev acc
    else if
      at i now
      && (i = 0 || not (is_ident_char code.[i - 1]))
      && (i + String.length now = n
         || not (is_ident_char code.[i + String.length now]))
    then
      go (i + 1)
        (if wrapped i then acc
         else
           Printf.sprintf
             "src/%s:%d: Eio.Time.now -- write Ptime.of_float_s (Eio.Time.now \
              clock)"
             file (line_of i)
           :: acc)
    else go (i + 1) acc
  in
  go 0 []

let no_bare_clock_read () =
  let found =
    List.concat_map
      (fun file -> bare_clock_reads file (read (Filename.concat src file)))
      (sources ".ml" @ sources ".mli")
  in
  Alcotest.(check (list string)) "clock reads not made an instant" [] found

let a_bare_clock_read_is_found () =
  let found source = List.length (bare_clock_reads "row.ml" source) in
  List.iter
    (fun source -> Alcotest.(check int) source 1 (found source))
    [
      "let t = Eio.Time.now clock";
      "let t = Ptime.of_float_s (Eio.Time.now clock +. 1.)";
      "let t = Ptime.of_float_s (1. +. Eio.Time.now clock)";
    ];
  List.iter
    (fun source -> Alcotest.(check int) source 0 (found source))
    [
      "let t = Ptime.of_float_s (Eio.Time.now clock)";
      "let t = Ptime.of_float_s\n  (Eio.Time.now t.clock)";
      "let t = Eio.Time.Mono.now clock";
      "(* Eio.Time.now clock *)";
    ]

(* A [float] labelled with a unit, [timeout_s : float] or [?wait_ms:float]:
   a duration is an Mtime.Span.t named for what it bounds. Read off the
   code, so a comment or a string may say it. *)
let unit_suffixes = [ "_s"; "_ms"; "_us"; "_ns" ]

let floats_with_a_unit file source =
  let code = code_of source in
  let n = String.length code in
  let is_space c = Char.equal c ' ' || Char.equal c '\n' in
  let word_at i w =
    i + String.length w <= n
    && String.equal (String.sub code i (String.length w)) w
    && (i = 0 || not (is_ident_char code.[i - 1]))
    && (i + String.length w = n
       || not (is_ident_char code.[i + String.length w]))
  in
  let rec back_over_space i =
    if i >= 0 && is_space code.[i] then back_over_space (i - 1) else i
  in
  let label_before i =
    let colon = back_over_space (i - 1) in
    if colon >= 0 && Char.equal code.[colon] ':' then (
      let last = back_over_space (colon - 1) in
      let first = ref last in
      while !first >= 0 && is_ident_char code.[!first] do
        decr first
      done;
      if last > !first then Some (String.sub code (!first + 1) (last - !first))
      else None)
    else None
  in
  let line_of i =
    let l = ref 1 in
    for x = 0 to i - 1 do
      if Char.equal code.[x] '\n' then incr l
    done;
    !l
  in
  let rec go i acc =
    if i >= n then List.rev acc
    else if word_at i "float" then
      match label_before i with
      | Some label
        when List.exists
               (fun suffix -> String.ends_with ~suffix label)
               unit_suffixes ->
          go (i + 5)
            (Printf.sprintf
               "src/%s:%d: %s : float -- a duration is an Mtime.Span.t named \
                for what it bounds"
               file (line_of i) label
            :: acc)
      | Some _ | None -> go (i + 5) acc
    else go (i + 1) acc
  in
  go 0 []

let no_float_with_a_unit () =
  let found =
    List.concat_map
      (fun file -> floats_with_a_unit file (read (Filename.concat src file)))
      (sources ".ml" @ sources ".mli")
  in
  Alcotest.(check (list string)) "floats labelled with a unit" [] found

let a_float_with_a_unit_is_found () =
  let found source = List.length (floats_with_a_unit "row.ml" source) in
  List.iter
    (fun source -> Alcotest.(check int) source 1 (found source))
    [
      "val connect : ?timeout_s:float -> unit";
      "type t = { wait_ms : float option }";
      "let f (heartbeat_s : float) = heartbeat_s";
      "val v : timeout_s:\n  float -> t";
    ];
  List.iter
    (fun source -> Alcotest.(check int) source 0 (found source))
    [
      "val connect : ?timeout:Mtime.Span.t -> unit";
      "val ratio : float";
      "(* timeout_s : float *)";
      "let x_s : int = 1";
    ]

let no_silenced_warning () =
  let found =
    List.concat_map
      (fun file ->
        let code = code_of (read (Filename.concat src file)) in
        String.split_on_char '\n' code
        |> List.mapi (fun i l -> (i + 1, l))
        |> List.filter_map (fun (line, l) ->
            let rec has i =
              i + 8 <= String.length l
              && (String.equal (String.sub l i 8) "@warning" || has (i + 1))
            in
            if has 0 then
              Some
                (Printf.sprintf
                   "src/%s:%d: a silenced warning is a code shape to fix" file
                   line)
            else None))
      (sources ".ml" @ sources ".mli")
  in
  Alcotest.(check (list string)) "silenced warnings" [] found

let every_module_has_an_interface () =
  let missing =
    sources ".ml"
    |> List.filter (fun ml ->
        not (Sys.file_exists (Filename.concat src (ml ^ "i"))))
    |> List.map (fun ml -> "src/" ^ ml ^ " has no .mli")
  in
  Alcotest.(check (list string)) "modules without an interface" [] missing

let () =
  Alcotest.run "style"
    [
      ( "src",
        [
          Alcotest.test_case "no banned identifier" `Quick no_banned_identifier;
          Alcotest.test_case "the refusals are read from OCAML.md" `Quick
            the_refusals_are_read_from_ocaml_md;
          Alcotest.test_case "no bare clock read" `Quick no_bare_clock_read;
          Alcotest.test_case "a bare clock read is found" `Quick
            a_bare_clock_read_is_found;
          Alcotest.test_case "no float labelled with a unit" `Quick
            no_float_with_a_unit;
          Alcotest.test_case "a float labelled with a unit is found" `Quick
            a_float_with_a_unit_is_found;
          Alcotest.test_case "no silenced warning" `Quick no_silenced_warning;
          Alcotest.test_case "every module has an interface" `Quick
            every_module_has_an_interface;
        ] );
    ]
