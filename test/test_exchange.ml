open Axiom
open Types

let unwrap = function Ok x -> x | Error e -> failwith e
let id s = unwrap (Id.of_string s)
let q n = unwrap (Quantity.of_int n)
let p n = unwrap (Price.of_int n)
let limit ?(tif=Gtc) name side price quantity =
  Submit { id = id name; side; quantity = q quantity; kind = Limit (p price, tif) }
let market name side quantity = Submit { id = id name; side; quantity = q quantity; kind = Market }
let ensure condition message = if not condition then failwith message
let invariant book = match Book.check_invariants book with
  | Ok () -> () | Error e -> failwith e
let step book command = match Book.apply book command with
  | Ok (book, events) -> invariant book; book, events
  | Error e -> failwith (error_to_string e)
let run commands =
  List.fold_left (fun (book, events) command ->
    let book, next = step book command in book, events @ next) (Book.empty, []) commands
let trades events = List.filter_map (function
  | Trade t -> Some (Id.to_string t.maker, Id.to_string t.taker,
      Price.to_int t.price, Quantity.to_int t.quantity)
  | _ -> None) events
let orders book = Book.open_orders book |> List.map (fun (o : resting) ->
  Id.to_string o.id, side_to_string o.side, Price.to_int o.price,
  Quantity.to_int o.quantity, o.sequence)
let rejects book command expected =
  let before = Book.canonical book in
  (match Book.apply book command with
   | Error e -> ensure (e = expected) "unexpected rejection"
   | Ok _ -> failwith "expected rejection");
  ensure (Book.canonical book = before) "rejection mutated snapshot"
let has_expiry name amount events = List.exists (function
  | Expired (_, who, quantity, _) -> Id.to_string who = name && Quantity.to_int quantity = amount
  | _ -> false) events
let fixture name f = name, f

let fixtures = [
  fixture "checked scalar constructors" (fun () ->
    List.iter (fun n -> ensure (Result.is_error (Price.of_int n)) "invalid price accepted") [0; -1; 1_000_000_001];
    List.iter (fun n -> ensure (Result.is_error (Quantity.of_int n)) "invalid quantity accepted") [0; -1; 1_000_001];
    List.iter (fun s -> ensure (Result.is_error (Id.of_string s)) "invalid ID accepted")
      [""; "white space"; "has,comma"; String.make 65 'x'];
    ensure (Result.is_ok (Price.of_int 1_000_000_000)) "maximum price rejected");
  fixture "exact fill removes both orders" (fun () ->
    let b, es = run [limit "s" Sell 100 5; limit "b" Buy 100 5] in
    ensure (orders b = [] && trades es = ["s", "b", 100, 5]) "exact fill failed");
  fixture "partial maker retains original sequence" (fun () ->
    let b, _ = run [limit "s" Sell 100 8; market "b" Buy 3] in
    ensure (orders b = ["s", "SELL", 100, 5, 0]) "partial maker incorrect");
  fixture "partial taker rests at its limit" (fun () ->
    let b, es = run [limit "s" Sell 100 3; limit "b" Buy 105 8] in
    ensure (orders b = ["b", "BUY", 105, 5, 1]) "taker remainder incorrect";
    ensure (trades es = ["s", "b", 100, 3]) "wrong execution price");
  fixture "buy chooses lowest ask before older higher ask" (fun () ->
    let _, es = run [limit "high" Sell 110 2; limit "low" Sell 100 2; market "b" Buy 3] in
    ensure (trades es = ["low", "b", 100, 2; "high", "b", 110, 1]) "ask priority failed");
  fixture "sell chooses highest bid before older lower bid" (fun () ->
    let _, es = run [limit "low" Buy 90 2; limit "high" Buy 100 2; market "s" Sell 3] in
    ensure (trades es = ["high", "s", 100, 2; "low", "s", 90, 1]) "bid priority failed");
  fixture "FIFO asks" (fun () ->
    let _, es = run [limit "first" Sell 100 2; limit "second" Sell 100 2; market "b" Buy 3] in
    ensure (trades es = ["first", "b", 100, 2; "second", "b", 100, 1]) "ask FIFO failed");
  fixture "FIFO bids" (fun () ->
    let _, es = run [limit "first" Buy 100 2; limit "second" Buy 100 2; market "s" Sell 3] in
    ensure (trades es = ["first", "s", 100, 2; "second", "s", 100, 1]) "bid FIFO failed");
  fixture "sell executes at resting bid price" (fun () ->
    let _, es = run [limit "b" Buy 110 3; limit "s" Sell 100 2] in
    ensure (trades es = ["b", "s", 110, 2]) "maker price failed");
  fixture "empty market order expires completely" (fun () ->
    let b, es = run [market "b" Buy 8] in
    ensure (orders b = [] && has_expiry "b" 8 es) "empty market failed");
  fixture "market remainder never rests" (fun () ->
    let b, es = run [limit "s" Sell 100 2; market "b" Buy 5] in
    ensure (orders b = [] && has_expiry "b" 3 es) "market remainder failed");
  fixture "empty IOC expires completely" (fun () ->
    let b, es = run [limit ~tif:Ioc "b" Buy 100 4] in
    ensure (orders b = [] && has_expiry "b" 4 es) "IOC rested");
  fixture "IOC partially fills and expires" (fun () ->
    let b, es = run [limit "s" Sell 100 3; limit ~tif:Ioc "b" Buy 100 8] in
    ensure (orders b = [] && trades es = ["s", "b", 100, 3] && has_expiry "b" 5 es) "IOC fill failed");
  fixture "FOK rejection is atomic" (fun () ->
    let b, _ = run [limit "s" Sell 100 3] in
    rejects b (limit ~tif:Fok "b" Buy 100 4) (Insufficient_liquidity (id "b")));
  fixture "FOK excludes prices outside the limit" (fun () ->
    let b, _ = run [limit "s" Sell 101 8] in
    rejects b (limit ~tif:Fok "b" Buy 100 2) (Insufficient_liquidity (id "b")));
  fixture "FOK fills across multiple levels" (fun () ->
    let b, es = run [limit "a" Sell 100 2; limit "c" Sell 101 3;
      limit ~tif:Fok "b" Buy 101 5] in
    ensure (orders b = [] && trades es = ["a", "b", 100, 2; "c", "b", 101, 3]) "FOK sweep failed");
  fixture "post-only buy rejects crossing" (fun () ->
    let b, _ = run [limit "s" Sell 100 3] in
    rejects b (limit ~tif:Post_only "b" Buy 100 1) (Would_cross (id "b")));
  fixture "post-only sell rejects crossing" (fun () ->
    let b, _ = run [limit "b" Buy 100 3] in
    rejects b (limit ~tif:Post_only "s" Sell 99 1) (Would_cross (id "s")));
  fixture "post-only order rests then behaves as a maker" (fun () ->
    let b, es = run [limit ~tif:Post_only "s" Sell 100 3; market "b" Buy 2] in
    ensure (orders b = ["s", "SELL", 100, 1, 0] && trades es = ["s", "b", 100, 2]) "post-only maker failed");
  fixture "cancel removes an empty price level" (fun () ->
    let b, _ = run [limit "b" Buy 100 3; Cancel (id "b")] in
    ensure (Book.best_bid b = None && orders b = []) "cancel left empty level");
  fixture "cancel middle FIFO member" (fun () ->
    let _, es = run [limit "a" Sell 100 2; limit "b" Sell 100 2; limit "c" Sell 100 2;
      Cancel (id "b"); market "t" Buy 4] in
    ensure (trades es = ["a", "t", 100, 2; "c", "t", 100, 2]) "FIFO after cancel failed");
  fixture "strict reduction preserves FIFO priority" (fun () ->
    let _, es = run [limit "a" Sell 100 8; limit "b" Sell 100 5;
      Reduce (id "a", q 2); market "t" Buy 3] in
    ensure (trades es = ["a", "t", 100, 2; "b", "t", 100, 1]) "reduce lost priority");
  fixture "increases and equal reductions are rejected" (fun () ->
    let b, _ = run [limit "b" Buy 100 3] in
    rejects b (Reduce (id "b", q 4)) (Not_a_reduction (id "b"));
    rejects b (Reduce (id "b", q 3)) (Not_a_reduction (id "b")));
  fixture "filled IDs cannot be reused" (fun () ->
    let b, _ = run [limit "s" Sell 100 2; market "b" Buy 2] in
    rejects b (limit "s" Buy 90 1) (Duplicate_id (id "s")));
  fixture "cancelled IDs cannot be reused" (fun () ->
    let b, _ = run [limit "b" Buy 100 3; Cancel (id "b")] in
    rejects b (limit "b" Buy 100 1) (Duplicate_id (id "b")));
  fixture "unknown cancellation and reduction are rejected" (fun () ->
    rejects Book.empty (Cancel (id "missing")) (Unknown_order (id "missing"));
    rejects Book.empty (Reduce (id "missing", q 1)) (Unknown_order (id "missing")));
  fixture "old snapshots remain unchanged" (fun () ->
    let old, _ = run [limit "s" Sell 100 5] in
    let before = Book.canonical old in
    let next, _ = step old (market "b" Buy 2) in
    ensure (Book.canonical old = before && orders old <> orders next) "persistent state failed");
  fixture "protocol round trips all command forms" (fun () ->
    let commands = [limit "a" Buy 100 3; limit ~tif:Ioc "b" Sell 101 5;
      limit ~tif:Fok "c" Buy 100 2; limit ~tif:Post_only "d" Sell 120 8;
      market "m" Sell 1; Cancel (id "a"); Reduce (id "a", q 1)] in
    List.iter (fun c -> ensure (Protocol.parse (Protocol.command_to_string c) = Ok (Some c)) "roundtrip failed") commands);
  fixture "protocol rejects malformed and overflowing inputs" (fun () ->
    List.iter (fun line -> ensure (Result.is_error (Protocol.parse line)) "malformed line accepted")
      ["LIMIT a BUY 0 2 GTC"; "MARKET a SELL -1"; "CANCEL"; "LIMIT a DOWN 100 1 GTC";
       "LIMIT a BUY 100 1 DAY"; "MARKET a BUY 9999999999999999999999999"; "UNKNOWN a"];
    ensure (Protocol.parse " \t # comment" = Ok None) "comment parse failed");
  fixture "maximum trade notional is exact" (fun () ->
    let _, es = run [limit "s" Sell 1_000_000_000 1_000_000; market "b" Buy 1_000_000] in
    let ns = List.filter_map (function Trade t -> Some (notional t) | _ -> None) es in
    ensure (ns = [1_000_000_000_000_000L]) "notional overflow or float rounding");
  fixture "noncrossing limits rest on both sides" (fun () ->
    let b, es = run [limit "s" Sell 101 2; limit "b" Buy 100 2] in
    ensure (trades es = [] && Book.active_count b = 2) "noncrossing order matched");
  fixture "FOK uses reduced rather than original quantities" (fun () ->
    let b, _ = run [limit "s" Sell 100 10; Reduce (id "s", q 2)] in
    rejects b (limit ~tif:Fok "b" Buy 100 3) (Insufficient_liquidity (id "b")));
  fixture "rejected FOK does not consume ID or sequence" (fun () ->
    rejects Book.empty (limit ~tif:Fok "b" Buy 100 1) (Insufficient_liquidity (id "b"));
    let b, _ = step Book.empty (limit "b" Buy 100 1) in
    ensure (orders b = ["b", "BUY", 100, 1, 0]) "rejected FOK consumed identity");
  fixture "rejected post-only ID may be resubmitted" (fun () ->
    let b, _ = run [limit "s" Sell 100 2] in
    rejects b (limit ~tif:Post_only "b" Buy 100 2) (Would_cross (id "b"));
    let b, _ = step b (limit ~tif:Post_only "b" Buy 99 2) in
    ensure (Book.sequence b = 2 && Book.active_count b = 2) "post-only rejection advanced state");
  fixture "snapshots support independent branches" (fun () ->
    let base, _ = run [limit "s" Sell 100 5] in
    let a, _ = step base (market "a" Buy 1) in
    let b, _ = step base (market "b" Buy 4) in
    ensure (orders base = ["s", "SELL", 100, 5, 0]) "base mutated";
    ensure (orders a = ["s", "SELL", 100, 4, 0] && orders b = ["s", "SELL", 100, 1, 0]) "branches shared mutation");
  fixture "expiry IDs cannot be reused" (fun () ->
    let b, _ = run [market "m" Buy 1] in
    rejects b (market "m" Sell 1) (Duplicate_id (id "m")));
  fixture "100000-maker FIFO sweep is stack safe" (fun () ->
    let book = ref Book.empty in
    for i = 0 to 99_999 do
      match Book.apply !book (limit ("large" ^ string_of_int i) Sell 100 1) with
      | Ok (next, _) -> book := next
      | Error e -> failwith (error_to_string e)
    done;
    invariant !book;
    let next, events = step !book (market "large_taker" Buy 100_000) in
    let count, first, last = List.fold_left (fun (count, first, last) -> function
      | Trade t ->
          let maker = Id.to_string t.maker in
          ensure (maker = "large" ^ string_of_int count) "large-sweep FIFO failed";
          count + 1, (if count = 0 then maker else first), maker
      | _ -> count, first, last) (0, "", "") events in
    ensure (count = 100_000 && first = "large0" && last = "large99999"
      && Book.active_count next = 0) "large sweep dropped trades");
]

let randomized ~seed ~count =
  let raw = Workload.generate ~seed count in
  let rng = Random.State.make [| seed; 314159 |] in
  let book = ref Book.empty and model = ref Reference.empty in
  let submitted = ref 0L and traded = ref 0L and discarded = ref 0L in
  let add total n = total := Int64.add !total (Int64.of_int n) in
  let journal = ref [] in
  Array.iteri (fun i raw_command ->
    let active = Reference.open_orders !model in
    let command = match active with
      | [] -> raw_command
      | _ when i mod 13 = 0 ->
          let chosen = List.nth active (Random.State.int rng (List.length active)) in
          Cancel chosen.id
      | _ when i mod 17 = 0 ->
          let chosen = List.nth active (Random.State.int rng (List.length active)) in
          let old = Quantity.to_int chosen.quantity in
          if old = 1 then Cancel chosen.id else Reduce (chosen.id, q (old - 1))
      | _ -> raw_command in
    let fail_context message = failwith (Printf.sprintf "seed=%d step=%d command=%s: %s"
      seed i (Protocol.command_to_string command) message) in
    let old_text = Book.canonical !book in
    (match Book.apply !book command, Reference.apply !model command with
     | Error actual, Error expected ->
         if actual <> expected then fail_context "rejection differs from independent model";
         if Book.canonical !book <> old_text then fail_context "rejection altered state"
     | Ok (next, events), Ok (reference, expected_events) ->
         if events <> expected_events then fail_context "event trace differs from independent model";
         if Book.open_orders next <> Reference.open_orders reference then fail_context "resting state differs";
         if Book.sequence next <> reference.Reference.sequence then fail_context "sequence differs";
         List.iter (function
           | Accepted (_, o) -> add submitted (Quantity.to_int o.quantity)
           | Trade t -> add traded (Quantity.to_int t.quantity)
           | Cancelled (_, o) -> add discarded (Quantity.to_int o.quantity)
           | Reduced (_, o, new_q) -> add discarded (Quantity.to_int o.quantity - Quantity.to_int new_q)
           | Expired (_, _, quantity, _) -> add discarded (Quantity.to_int quantity)
           | Rested _ -> ()) events;
         book := next; model := reference
     | _ -> fail_context "acceptance differs from independent model");
    invariant !book;
    let remaining = List.fold_left (fun n (o : resting) ->
      Int64.add n (Int64.of_int (Quantity.to_int o.quantity))) 0L (Book.open_orders !book) in
    if !submitted <> Int64.add (Int64.mul 2L !traded) (Int64.add !discarded remaining) then
      fail_context "global quantity conservation failed";
    journal := command :: !journal) raw;
  let replayed = List.fold_left (fun state command ->
    let command = match Protocol.parse (Protocol.command_to_string command) with
      | Ok (Some c) -> c | _ -> failwith "journal parse failed" in
    match Book.apply state command with Ok (next, _) -> next | Error _ -> state)
    Book.empty (List.rev !journal) in
  ensure (Book.canonical replayed = Book.canonical !book) "serialized replay changed complete final state"

let () =
  let failed = ref 0 in
  let test name f =
    try f (); Printf.printf "PASS %s\n%!" name
    with e -> incr failed; Printf.eprintf "FAIL %s: %s\n%!" name (Printexc.to_string e) in
  List.iter (fun (name, f) -> test name f) fixtures;
  for seed = 1 to 10 do
    test (Printf.sprintf "independent model + invariants + conservation + replay: seed %d, 10000 commands" seed)
      (fun () -> randomized ~seed ~count:10_000)
  done;
  if !failed > 0 then (Printf.eprintf "%d tests failed\n" !failed; exit 1)
  else Printf.printf "PASS %d fixtures and 100000 randomized commands across 10 seeds\n" (List.length fixtures)
