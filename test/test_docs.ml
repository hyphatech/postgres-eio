(* An example is built so a page cannot show code that does not compile, and
   one no page shows is code nobody reads: every .ml file examples/dune
   builds is imported whole by some page of the site, as
   [@examples/<file>.ml?raw]. *)

let read path = In_channel.with_open_bin path In_channel.input_all

let contains s sub =
  let n = String.length sub in
  let rec at i =
    i + n <= String.length s
    && (String.equal (String.sub s i n) sub || at (i + 1))
  in
  at 0

let every_example_is_on_a_page () =
  let built =
    Sys.readdir "../examples" |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".ml")
    |> List.sort String.compare
  in
  let rec pages dir =
    Sys.readdir dir |> Array.to_list
    |> List.concat_map (fun f ->
        let path = Filename.concat dir f in
        if Sys.is_directory path then pages path
        else if Filename.check_suffix f ".md" || Filename.check_suffix f ".mdx"
        then [ read path ]
        else [])
  in
  let docs = String.concat "\n" (pages "../docs/src/content") in
  Alcotest.(check bool) "examples/ holds programs" true (List.length built > 1);
  Alcotest.(check (list string))
    "built, and on no page" []
    (List.filter
       (fun file ->
         not (contains docs (Printf.sprintf {|"@examples/%s?raw"|} file)))
       built)

let () =
  Alcotest.run "docs"
    [
      ( "documents",
        [
          Alcotest.test_case "every example is on a page" `Quick
            every_example_is_on_a_page;
        ] );
    ]
