open Types
module Prices = Map.Make (Price)
module Sequences = Map.Make (Int)
module Ids = Map.Make (Id)
module Seen = Set.Make (Id)

type levels = resting Sequences.t Prices.t
type t = {
  bids : levels;
  asks : levels;
  index : resting Ids.t;
  seen : Seen.t;
  next_sequence : int;
}

let empty = {
  bids = Prices.empty; asks = Prices.empty; index = Ids.empty;
  seen = Seen.empty; next_sequence = 0;
}
let sequence t = t.next_sequence
let active_count t = Ids.cardinal t.index
let open_orders t = List.map snd (Ids.bindings t.index)
let best_bid t = Option.map fst (Prices.max_binding_opt t.bids)
let best_ask t = Option.map fst (Prices.min_binding_opt t.asks)
let levels_for t = function Buy -> t.bids | Sell -> t.asks
let set_levels t side levels =
  match side with Buy -> { t with bids = levels } | Sell -> { t with asks = levels }
let opposite = function Buy -> Sell | Sell -> Buy
let quantity n = match Quantity.of_int n with Ok q -> q | Error e -> invalid_arg e

let insert t (o : resting) =
  let levels = levels_for t o.side in
  let level = match Prices.find_opt o.price levels with
    | Some level -> level | None -> Sequences.empty in
  let levels = Prices.add o.price (Sequences.add o.sequence o level) levels in
  let t = set_levels t o.side levels in
  { t with index = Ids.add o.id o t.index }

let remove t (o : resting) =
  let levels = levels_for t o.side in
  let level = Sequences.remove o.sequence (Prices.find o.price levels) in
  let levels = if Sequences.is_empty level then Prices.remove o.price levels
    else Prices.add o.price level levels in
  let t = set_levels t o.side levels in
  { t with index = Ids.remove o.id t.index }

let best_opponent t side =
  let binding = match side with
    | Buy -> Prices.min_binding_opt t.asks
    | Sell -> Prices.max_binding_opt t.bids in
  match binding with
  | None -> None
  | Some (_, level) -> Some (snd (Sequences.min_binding level))

let crosses (o : order) price =
  match o.kind, o.side with
  | Market, _ -> true
  | Limit (limit, _), Buy -> Price.compare price limit <= 0
  | Limit (limit, _), Sell -> Price.compare price limit >= 0

(* Preflight is read-only: a failed FOK leaves the complete input state intact. *)
let has_liquidity t (o : order) =
  let prices = levels_for t (opposite o.side) in
  let prices = match o.side with
    | Buy -> Prices.to_seq prices | Sell -> Prices.to_rev_seq prices in
  let rec at_orders needed orders =
    if needed <= 0 then 0 else match orders () with
    | Seq.Nil -> needed
    | Seq.Cons ((_, (resting : resting)), tail) ->
        at_orders (needed - Quantity.to_int resting.quantity) tail in
  let rec at_prices needed prices =
    if needed <= 0 then true else match prices () with
    | Seq.Nil -> false
    | Seq.Cons ((price, orders), tail) ->
        crosses o price && at_prices (at_orders needed (Sequences.to_seq orders)) tail in
  at_prices (Quantity.to_int o.quantity) prices

let match_order t seq (o : order) =
  let rec loop t remaining reversed_events =
    if remaining = 0 then t, remaining, reversed_events
    else match best_opponent t o.side with
    | Some maker when crosses o maker.price ->
        let maker_qty = Quantity.to_int maker.quantity in
        let filled = min remaining maker_qty in
        let t = remove t maker in
        let t = if filled < maker_qty then
          insert t { maker with quantity = quantity (maker_qty - filled) } else t in
        let event = Trade {
          maker = maker.id; taker = o.id; maker_side = maker.side;
          price = maker.price; quantity = quantity filled; sequence = seq;
        } in
        loop t (remaining - filled) (event :: reversed_events)
    | _ -> t, remaining, reversed_events in
  loop t (Quantity.to_int o.quantity) []

let apply t command =
  if t.next_sequence = max_int then Error Sequence_exhausted
  else
    let seq = t.next_sequence in
    let advance t = { t with next_sequence = seq + 1 } in
    match command with
    | Cancel id -> (match Ids.find_opt id t.index with
        | None -> Error (Unknown_order id)
        | Some o -> Ok (advance (remove t o), [Cancelled (seq, o)]))
    | Reduce (id, new_quantity) -> (match Ids.find_opt id t.index with
        | None -> Error (Unknown_order id)
        | Some o when Quantity.to_int new_quantity >= Quantity.to_int o.quantity ->
            Error (Not_a_reduction id)
        | Some o ->
            let t = insert (remove t o) { o with quantity = new_quantity } in
            Ok (advance t, [Reduced (seq, o, new_quantity)]))
    | Submit o ->
        if Seen.mem o.id t.seen then Error (Duplicate_id o.id)
        else match o.kind with
        | Limit (_, Fok) when not (has_liquidity t o) ->
            Error (Insufficient_liquidity o.id)
        | Limit (_, Post_only) when
            (match best_opponent t o.side with
             | Some maker -> crosses o maker.price | None -> false) ->
            Error (Would_cross o.id)
        | _ ->
            let t = { t with seen = Seen.add o.id t.seen } in
            let t, remaining, reversed_trades = match_order t seq o in
            let t, tail = if remaining = 0 then t, [] else
              match o.kind with
              | Limit (price, (Gtc | Post_only)) ->
                  let resting = { id = o.id; side = o.side; price;
                    quantity = quantity remaining; sequence = seq } in
                  insert t resting, [Rested resting]
              | Market -> t, [Expired (seq, o.id, quantity remaining, Market_remainder)]
              | Limit (_, Ioc) -> t, [Expired (seq, o.id, quantity remaining, Ioc_remainder)]
              | Limit (_, Fok) -> failwith "internal error: successful FOK left a remainder" in
            Ok (advance t, Accepted (seq, o) :: List.rev_append reversed_trades tail)

let canonical t =
  let b = Buffer.create 256 in
  Buffer.add_string b (Printf.sprintf "sequence=%d\n" t.next_sequence);
  Seen.iter (fun id -> Buffer.add_string b ("seen=" ^ Id.to_string id ^ "\n")) t.seen;
  Ids.iter (fun _ (o : resting) ->
    Buffer.add_string b (Printf.sprintf "order=%s,%s,%d,%d,%d\n"
      (Id.to_string o.id) (side_to_string o.side) (Price.to_int o.price)
      (Quantity.to_int o.quantity) o.sequence)) t.index;
  Buffer.contents b
let fingerprint t = Digest.to_hex (Digest.string (canonical t))

let check_invariants t =
  let exception Broken of string in
  let ensure condition message = if not condition then raise (Broken message) in
  try
    let reconstructed = ref Ids.empty in
    let sequences = Hashtbl.create (active_count t) in
    let inspect side levels =
      Prices.iter (fun price orders ->
        ensure (not (Sequences.is_empty orders)) "empty price level";
        Sequences.iter (fun seq (o : resting) ->
          ensure (o.side = side) "order on wrong side";
          ensure (Price.compare o.price price = 0) "price-key mismatch";
          ensure (o.sequence = seq && seq >= 0 && seq < t.next_sequence)
            "invalid priority sequence";
          ensure (Quantity.to_int o.quantity > 0) "nonpositive resting quantity";
          ensure (Seen.mem o.id t.seen) "active ID missing from seen set";
          ensure (not (Ids.mem o.id !reconstructed)) "duplicate active ID";
          ensure (not (Hashtbl.mem sequences seq)) "duplicate priority sequence";
          reconstructed := Ids.add o.id o !reconstructed;
          Hashtbl.add sequences seq ()) orders) levels in
    inspect Buy t.bids;
    inspect Sell t.asks;
    ensure (Ids.equal (=) !reconstructed t.index) "book/index mismatch";
    (match best_bid t, best_ask t with
     | Some bid, Some ask -> ensure (Price.compare bid ask < 0) "crossed book"
     | _ -> ());
    Ok ()
  with Broken message -> Error message
