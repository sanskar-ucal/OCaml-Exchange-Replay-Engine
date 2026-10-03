(* Deliberately slow independent model: flat lists and sorting, no book maps/index. *)
open Axiom.Types
type t = { orders : resting list; seen : Id.t list; sequence : int }
let empty = { orders = []; seen = []; sequence = 0 }
let q n = match Quantity.of_int n with Ok q -> q | Error e -> failwith e
let order_priority side (a : resting) (b : resting) =
  let price = match side with
    | Buy -> Price.compare a.price b.price | Sell -> Price.compare b.price a.price in
  if price = 0 then Int.compare a.sequence b.sequence else price
let eligible (incoming : order) (resting : resting) =
  incoming.side <> resting.side && match incoming.kind, incoming.side with
  | Market, _ -> true
  | Limit (p, _), Buy -> Price.compare resting.price p <= 0
  | Limit (p, _), Sell -> Price.compare resting.price p >= 0
let open_orders t = List.sort (fun (a : resting) (b : resting) -> Id.compare a.id b.id) t.orders
let apply t = function
  | Cancel id -> (match List.find_opt (fun (o : resting) -> o.id = id) t.orders with
      | None -> Error (Unknown_order id)
      | Some o -> Ok ({ t with sequence = t.sequence + 1;
          orders = List.filter (fun (x : resting) -> x.id <> id) t.orders },
          [Cancelled (t.sequence, o)]))
  | Reduce (id, quantity) -> (match List.find_opt (fun (o : resting) -> o.id = id) t.orders with
      | None -> Error (Unknown_order id)
      | Some o when Quantity.to_int quantity >= Quantity.to_int o.quantity -> Error (Not_a_reduction id)
      | Some o -> Ok ({ t with sequence = t.sequence + 1;
          orders = List.map (fun (x : resting) -> if x.id = id then { x with quantity } else x) t.orders },
          [Reduced (t.sequence, o, quantity)]))
  | Submit incoming ->
      if List.mem incoming.id t.seen then Error (Duplicate_id incoming.id) else
      let eligible_orders = List.filter (eligible incoming) t.orders
        |> List.sort (order_priority incoming.side) in
      let available = List.fold_left (fun n (o : resting) -> n + Quantity.to_int o.quantity) 0 eligible_orders in
      match incoming.kind with
      | Limit (_, Fok) when available < Quantity.to_int incoming.quantity -> Error (Insufficient_liquidity incoming.id)
      | Limit (_, Post_only) when eligible_orders <> [] -> Error (Would_cross incoming.id)
      | _ ->
          let rec fill orders needed candidates reversed =
            if needed = 0 then orders, needed, List.rev reversed else match candidates with
            | [] -> orders, needed, List.rev reversed
            | (maker : resting) :: tail ->
                let filled = min needed (Quantity.to_int maker.quantity) in
                let orders = List.filter (fun (o : resting) -> o.id <> maker.id) orders in
                let orders = if filled < Quantity.to_int maker.quantity then
                  { maker with quantity = q (Quantity.to_int maker.quantity - filled) } :: orders else orders in
                let trade = Trade { maker = maker.id; taker = incoming.id;
                  maker_side = maker.side; price = maker.price; quantity = q filled; sequence = t.sequence } in
                fill orders (needed - filled) tail (trade :: reversed) in
          let orders, remaining, trades = fill t.orders (Quantity.to_int incoming.quantity) eligible_orders [] in
          let orders, tail = if remaining = 0 then orders, [] else match incoming.kind with
            | Limit (price, (Gtc | Post_only)) ->
                let o = { id = incoming.id; side = incoming.side; price;
                  quantity = q remaining; sequence = t.sequence } in
                o :: orders, [Rested o]
            | Market -> orders, [Expired (t.sequence, incoming.id, q remaining, Market_remainder)]
            | Limit (_, Ioc) -> orders, [Expired (t.sequence, incoming.id, q remaining, Ioc_remainder)]
            | Limit (_, Fok) -> failwith "reference FOK remainder" in
          Ok ({ orders; seen = incoming.id :: t.seen; sequence = t.sequence + 1 },
            Accepted (t.sequence, incoming) :: (trades @ tail))
