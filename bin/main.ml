(*
 * Copyright 2022 Vincent Chan
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *)
open Lichenscript_lex
open Lichenscript_parsing
open Lichenscript_typing
open Lichenscript_resolver
open Lichenscript_common.Cli_utils
open Core

let help_message = {|
|} ^ TermColor.bold ^ "Usage:" ^ TermColor.reset ^ {|
lsc <command> [<args>]

|} ^ TermColor.bold ^ "Subcommands" ^ TermColor.reset ^ {|
  build
  run

|}

let build_help_message = {|
|} ^ TermColor.bold ^ "Usage:" ^ TermColor.reset ^ {|
lsc build <entry> [<args>]

|} ^ TermColor.bold ^ "Options:" ^ TermColor.reset ^ {|
  --lib                  Build a library
  --base <dir>           Base directory to resolve modules,
                         default: current directory
  --build-dir, -D <dir>  Specify a directory to build,
                         a temp directory will be used if this is not specified.
  --platform <platform>  native/wasm/js, default: native
  --mode <debug|release> Choose the mode of debug/release
  --verbose, -V          Print verbose log
  -h, --help             Show help message

|} ^ TermColor.bold ^ "Environment:" ^ TermColor.reset ^ {|
LSC_RUNTIME              The directory of runtime.
LSC_STD                  Specify the directorey of std library.

|}

let rec main () = 
  let index = ref 1 in
  let args = Sys.get_argv () in
  if Array.length args < 2 then (
    Format.print_string help_message;
    ignore (exit 2)
  );
  let command = Array.get args !index in
  index := !index + 1;
  match command with
  | "build" -> ignore (build_command args index)
  | "run" -> build_and_run args index
  | _ -> (
    Format.printf "unkown command %s\n" command;
    ignore (exit 2)
  )

and build_and_run args index =
  let build_result = build_command args index in
  match build_result with
  | Some path ->
    ignore (run_bin_path path)

  | None -> ()

and build_command args index : string option =
  if !index >= (Array.length args) then (
    Format.printf "%s" build_help_message;
    ignore (exit 2);
    None
  ) else 
    let entry = ref None in
    let std = Sys.getenv_exn "LSC_STD" in
    let runtimeDir = Sys.getenv_exn "LSC_RUNTIME" in
    let buildDir = ref None in
    let mode = ref "debug" in
    let verbose = ref false in
    let platform = ref "native" in
    let baseDir = ref Filename.current_dir_name in
    while !index < (Array.length args) do
      let item = Array.get args !index in
      index := !index + 1;
      match item with
      | "-h" | "--help" ->
        Format.printf "%s" build_help_message;
        ignore (exit 0)

      | "--mode" -> (
        if !index >= (Array.length args) then (
          Format.printf "not enough args for --mode\n";
          ignore (exit 2)
        );
        mode := Array.get args !index;
        index := !index + 1;
        if (not (String.equal !mode  "debug")) && (not (String.equal !mode "release")) then (
          Format.printf "mode should be debug or release\n";
          ignore (exit 2)
        )
      )

      | "-v" | "--verbose" ->
        verbose := true

      | "--build-dir" | "-D" -> (
        if !index >= (Array.length args) then (
          Format.printf "not enough args for %s\n" item;
          ignore (exit 2)
        );
        buildDir := Some (Array.get args !index);
        index := !index + 1;
      )

      | "--platform" -> (
        if !index >= (Array.length args) then (
          Format.printf "not enough args for --platform\n";
          ignore (exit 2)
        );
        platform := (Array.get args !index);
        index := !index + 1;
      )

      | "--base" -> (
        if !index >= (Array.length args) then (
          Format.printf "not enough args for --base\n";
          ignore (exit 2)
        );
        baseDir := (Array.get args !index) |> Filename.realpath;
        index := !index + 1;
      )

      | _ ->
        entry := Some item

    done;
    if Option.is_none !entry then (
      Format.printf "Error: no input files\n";
      ignore (exit 2);
      None
    ) else 
      build_entry (Option.value_exn !entry) std !buildDir runtimeDir !mode !verbose

and build_entry (entry: string) std_dir build_dir runtime_dir mode verbose: string option =
  let open Resolver in
  try
    let entry_full_path = Filename.realpath entry in
    let profiles = Resolver.compile_file_path ~std_dir ~build_dir ~runtime_dir ~mode ~verbose entry_full_path in
    let _, build_dir, result = List.find_exn ~f:(fun (profile_name, _, _) -> String.equal profile_name mode) profiles in
    run_make_in_dir build_dir;
    result
  with
    | Unix.Unix_error (_, err, err_s) -> (
      Format.printf "Failed: %s: %s %s\n" entry err err_s;
      ignore (exit 2);
      None
    )

    | TypeCheckError errors ->
      List.iter
        ~f:(fun err ->
          let { Type_error. spec; loc; ctx } = err in
          print_loc_title ~prefix:"type error" loc;
          let start = loc.start in
          Format.printf "%d:%d %a\n" start.line start.column (Type_error.PP.error_spec ~ctx) spec
        )
        errors;
      ignore (exit 2);
      None

    | ParseError errors ->
      List.iter
        ~f:(fun err ->
          let { Parse_error. perr_loc; _ } = err in
          print_loc_title ~prefix:"parse error" perr_loc;
          let start = perr_loc.start in
          Format.printf "%d:%d %a\n" start.line start.column Parse_error.PP.error err
        )
        errors;
      ignore (exit 2);
      None

and run_make_in_dir build_dir =
  (* Out_channel.printf "Spawn to build in %s\n" (TermColor.bold ^ build_dir ^ TermColor.reset); *)
  Out_channel.flush Out_channel.stdout;
  Out_channel.flush Out_channel.stderr;

  let pipe_read, pipe_write = Unix.pipe () in
  match Unix.fork () with
  | `In_the_child -> 
    Unix.dup2 ~src:pipe_write ~dst:Unix.stdout ();

    Unix.close pipe_read;
    Unix.close pipe_write;

    Unix.chdir build_dir;
    Unix.exec ~prog:"make" ~argv:["make";] () |> ignore

  | `In_the_parent pid -> (
    Unix.close pipe_write;

    let std_out_content = read_all_into_buffer pipe_read in

    let result = Unix.waitpid pid in

    match result with
    | Ok _ -> ()
    | Error _ -> Out_channel.print_string std_out_content
  )

and read_all_into_buffer pipe =
  let buffer = Buffer.create 1024 in

  let rec handle_message fd =
    try
      let content_bytes = Bytes.make 1024 (Char.of_int_exn 0) in
      let read_bytes = Unix.read ~len:1024 ~buf:content_bytes fd in

      if read_bytes = 0 then (
        ()
      ) else (
        Buffer.add_subbytes buffer content_bytes ~pos:0 ~len:read_bytes;
        handle_message fd
      )
    with exn -> 
      match exn with
      | Stdlib.End_of_file ->
        ()

      | _->
        ()

  in

  handle_message pipe;

  Buffer.contents buffer

and print_loc_title ~prefix loc_opt =
  Loc. (
    match loc_opt.source with
    | Some source -> (
      print_error_prefix ();
      let source_str = Format.asprintf "%a" Lichenscript_lex.File_key.pp source in
      Out_channel.printf "%s in %s\n" prefix (TermColor.bold ^ source_str ^ TermColor.reset)
    )
    | None -> ()
  )

(* replace current process *)
and run_bin_path path =
  Unix.exec ~prog:path ~argv:[path] ()
  (* match Unix.fork () with
  | `In_the_child -> (
    ignore (Unix.exec ~prog:path ~argv:[path] ())
  )
  | `In_the_parent pid -> (
    Unix.waitpid_exn pid
  ) *)

;;

main()
