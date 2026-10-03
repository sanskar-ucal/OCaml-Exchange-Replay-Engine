open Axiom
open Types

type stats = { commands : int; accepted : int; rejected : int; trades : int; units : int64 }
let no_stats = { commands = 0; accepted = 0; rejected = 0; trades = 0; units = 0L }
let account stats events =
  List.fold_left (fun stats -> function
    | Trade t -> { stats with trades = stats.trades + 1;
        units = Int64.add stats.units (Int64.of_int (Quantity.to_int t.quantity)) }
    | _ -> stats) { stats with commands = stats.commands + 1; accepted = stats.accepted + 1 } events

let replay path ~quiet =
  let input = open_in path in
  Fun.protect ~finally:(fun () -> close_in input) (fun () ->
    let rec loop line_number book stats =
      match input_line input with
      | line ->
          let parsed = match Protocol.parse line with
            | Ok parsed -> parsed
            | Error error -> failwith (Printf.sprintf "%s:%d: %s" path line_number error) in
          let book, stats = match parsed with
            | None -> book, stats
            | Some command -> (match Book.apply book command with
                | Ok (book, events) ->
                    if not quiet then List.iter (fun e -> print_endline (Protocol.event_to_string e)) events;
                    book, account stats events
                | Error error ->
                    if not quiet then Printf.printf "[line %d] REJECT %s\n" line_number (error_to_string error);
                    book, { stats with commands = stats.commands + 1; rejected = stats.rejected + 1 }) in
          loop (line_number + 1) book stats
      | exception End_of_file -> book, stats in
    loop 1 Book.empty no_stats)

let check book = match Book.check_invariants book with
  | Ok () -> () | Error e -> failwith ("invariant violation: " ^ e)
let summary book stats =
  check book;
  Printf.printf "commands=%d accepted=%d rejected=%d trades=%d traded_units=%Ld open_orders=%d sequence=%d\n"
    stats.commands stats.accepted stats.rejected stats.trades stats.units
    (Book.active_count book) (Book.sequence book);
  let quote = function None -> "none" | Some p -> string_of_int (Price.to_int p) in
  Printf.printf "best_bid=%s best_ask=%s state=%s\n"
    (quote (Book.best_bid book)) (quote (Book.best_ask book)) (Book.fingerprint book)
let write path text =
  let output = open_out path in
  Fun.protect ~finally:(fun () -> close_out output) (fun () -> output_string output text)
let positive_count text = match int_of_string_opt text with
  | Some n when n > 0 && n <= 5_000_000 -> n
  | _ -> invalid_arg "count must be between 1 and 5000000"
let seed text = match int_of_string_opt text with
  | Some n -> n | None -> invalid_arg "seed must be an integer"

let generate count seed path =
  let commands = Workload.generate ~seed count in
  let output = open_out path in
  Fun.protect ~finally:(fun () -> close_out output) (fun () ->
    Array.iter (fun command ->
      output_string output (Protocol.command_to_string command);
      output_char output '\n') commands);
  Printf.printf "wrote %d commands (seed=%d) to %s\n" count seed path

let bench count seed json_path =
  (* Generation, canonicalization, invariant scans, and all I/O are outside timing. *)
  let commands = Workload.generate ~seed count in
  Gc.full_major ();
  let before_gc = Gc.quick_stat () in
  let book = ref Book.empty and stats = ref no_stats in
  let wall_start = Unix.gettimeofday () and cpu_start = Sys.time () in
  Array.iter (fun command ->
    match Book.apply !book command with
    | Ok (next, events) -> book := next; stats := account !stats events
    | Error _ -> stats := { !stats with commands = !stats.commands + 1;
        rejected = !stats.rejected + 1 }) commands;
  let cpu_seconds = Sys.time () -. cpu_start in
  let wall_seconds = Unix.gettimeofday () -. wall_start in
  let after_gc = Gc.quick_stat () in
  check !book;
  let allocated stat = stat.Gc.minor_words +. stat.Gc.major_words -. stat.Gc.promoted_words in
  let allocated_bytes = (allocated after_gc -. allocated before_gc) *. float_of_int (Sys.word_size / 8) in
  let throughput = if wall_seconds > 0. then float_of_int count /. wall_seconds else 0. in
  let s = !stats in
  let json = Printf.sprintf
    "{\n  \"ocaml_version\": \"%s\",\n  \"word_size\": %d,\n  \"seed\": %d,\n  \"commands\": %d,\n  \"accepted\": %d,\n  \"rejected\": %d,\n  \"trade_events\": %d,\n  \"traded_units\": %Ld,\n  \"active_orders\": %d,\n  \"wall_seconds\": %.6f,\n  \"cpu_seconds\": %.6f,\n  \"commands_per_second\": %.2f,\n  \"allocated_bytes\": %.0f,\n  \"minor_collections\": %d,\n  \"major_collections\": %d,\n  \"state_fingerprint\": \"%s\",\n  \"timing_scope\": \"Book.apply plus event statistics; pre-generated single-process synthetic commands, no I/O or invariant scans\"\n}\n"
    Sys.ocaml_version Sys.word_size seed count s.accepted s.rejected s.trades s.units
    (Book.active_count !book) wall_seconds cpu_seconds throughput allocated_bytes
    (after_gc.Gc.minor_collections - before_gc.Gc.minor_collections)
    (after_gc.Gc.major_collections - before_gc.Gc.major_collections)
    (Book.fingerprint !book) in
  print_string json;
  Option.iter (fun path -> write path json) json_path

let usage () =
  prerr_endline "Axiom: deterministic single-instrument exchange simulator";
  prerr_endline "  axiom replay FILE [--quiet] [--state OUTPUT]";
  prerr_endline "  axiom verify FILE";
  prerr_endline "  axiom compare FILE_A FILE_B";
  prerr_endline "  axiom generate COUNT SEED OUTPUT";
  prerr_endline "  axiom bench COUNT SEED [--json OUTPUT]";
  exit 2
let replay_options args =
  let rec loop quiet state = function
    | [] -> quiet, state
    | "--quiet" :: tail -> loop true state tail
    | "--state" :: path :: tail -> loop quiet (Some path) tail
    | _ -> usage () in
  loop false None args
let main () = match Array.to_list Sys.argv with
  | _ :: "replay" :: path :: options ->
      let quiet, state_path = replay_options options in
      if state_path = Some path then invalid_arg "state output must differ from the command input";
      let book, stats = replay path ~quiet in
      summary book stats;
      Option.iter (fun output -> write output (Book.canonical book)) state_path
  | [_; "verify"; path] ->
      let a, stats_a = replay path ~quiet:true in
      let b, stats_b = replay path ~quiet:true in
      check a; check b;
      if Book.canonical a <> Book.canonical b || stats_a <> stats_b then
        failwith "replay verification failed";
      print_endline "replay verified: identical complete final state and aggregate statistics";
      summary a stats_a
  | [_; "compare"; left; right] ->
      let a, _ = replay left ~quiet:true and b, _ = replay right ~quiet:true in
      check a; check b;
      if Book.canonical a <> Book.canonical b then failwith "final states differ";
      print_endline ("same complete final state: " ^ Book.fingerprint a)
  | [_; "generate"; count; s; output] -> generate (positive_count count) (seed s) output
  | [_; "bench"; count; s] -> bench (positive_count count) (seed s) None
  | [_; "bench"; count; s; "--json"; output] -> bench (positive_count count) (seed s) (Some output)
  | _ -> usage ()
let () =
  try main () with
  | Failure e | Invalid_argument e | Sys_error e -> prerr_endline ("error: " ^ e); exit 2
