open Types
let ( let* ) = Result.bind
let integer label s =
  match int_of_string_opt s with
  | Some n -> Ok n | None -> Error ("invalid " ^ label ^ ": " ^ s)
let price s = let* n = integer "price" s in Price.of_int n
let quantity s = let* n = integer "quantity" s in Quantity.of_int n
let side = function
  | "BUY" -> Ok Buy | "SELL" -> Ok Sell
  | _ -> Error "side must be BUY or SELL"
let tif = function
  | "GTC" -> Ok Gtc | "IOC" -> Ok Ioc | "FOK" -> Ok Fok
  | "POST_ONLY" -> Ok Post_only
  | _ -> Error "time in force must be GTC, IOC, FOK, or POST_ONLY"
let words s =
  String.map (function '\t' | '\r' -> ' ' | c -> c) s
  |> String.split_on_char ' ' |> List.filter (fun x -> x <> "")
let parse line =
  let line = match String.index_opt line '#' with
    | Some i -> String.sub line 0 i | None -> line in
  match words line with
  | [] -> Ok None
  | ["LIMIT"; id; s; p; q; t] ->
      let* id = Id.of_string id in let* side = side s in
      let* p = price p in let* quantity = quantity q in let* t = tif t in
      Ok (Some (Submit { id; side; quantity; kind = Limit (p, t) }))
  | ["MARKET"; id; s; q] ->
      let* id = Id.of_string id in let* side = side s in
      let* quantity = quantity q in
      Ok (Some (Submit { id; side; quantity; kind = Market }))
  | ["CANCEL"; id] -> let* id = Id.of_string id in Ok (Some (Cancel id))
  | ["REDUCE"; id; q] ->
      let* id = Id.of_string id in let* q = quantity q in
      Ok (Some (Reduce (id, q)))
  | _ -> Error "expected LIMIT id side price quantity tif, MARKET id side quantity, CANCEL id, or REDUCE id quantity"

let command_to_string = function
  | Submit o -> (match o.kind with
      | Limit (p, t) -> Printf.sprintf "LIMIT %s %s %d %d %s"
          (Id.to_string o.id) (side_to_string o.side) (Price.to_int p)
          (Quantity.to_int o.quantity) (tif_to_string t)
      | Market -> Printf.sprintf "MARKET %s %s %d"
          (Id.to_string o.id) (side_to_string o.side) (Quantity.to_int o.quantity))
  | Cancel id -> "CANCEL " ^ Id.to_string id
  | Reduce (id, q) -> Printf.sprintf "REDUCE %s %d" (Id.to_string id) (Quantity.to_int q)
let event_to_string = function
  | Accepted (seq, o) -> Printf.sprintf "[%d] ACCEPT %s" seq (command_to_string (Submit o))
  | Trade t -> Printf.sprintf "[%d] TRADE maker=%s taker=%s price=%d quantity=%d notional=%Ld"
      t.sequence (Id.to_string t.maker) (Id.to_string t.taker)
      (Price.to_int t.price) (Quantity.to_int t.quantity) (notional t)
  | Rested o -> Printf.sprintf "[%d] REST %s %s price=%d quantity=%d"
      o.sequence (Id.to_string o.id) (side_to_string o.side)
      (Price.to_int o.price) (Quantity.to_int o.quantity)
  | Cancelled (seq, o) -> Printf.sprintf "[%d] CANCEL %s quantity=%d"
      seq (Id.to_string o.id) (Quantity.to_int o.quantity)
  | Reduced (seq, o, q) -> Printf.sprintf "[%d] REDUCE %s from=%d to=%d"
      seq (Id.to_string o.id) (Quantity.to_int o.quantity) (Quantity.to_int q)
  | Expired (seq, id, q, reason) -> Printf.sprintf "[%d] EXPIRE %s quantity=%d reason=%s"
      seq (Id.to_string id) (Quantity.to_int q)
      (match reason with Ioc_remainder -> "IOC" | Market_remainder -> "MARKET")
