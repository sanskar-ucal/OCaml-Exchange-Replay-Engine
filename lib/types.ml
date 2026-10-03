module Price = struct
  type t = int
  let of_int n =
    if n > 0 && n <= 1_000_000_000 then Ok n
    else Error "price must be between 1 and 1000000000 integer ticks"
  let to_int n = n
  let compare = Int.compare
end

module Quantity = struct
  type t = int
  let of_int n =
    if n > 0 && n <= 1_000_000 then Ok n
    else Error "quantity must be between 1 and 1000000 integer units"
  let to_int n = n
end

module Id = struct
  type t = string
  let valid_char = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
    | _ -> false
  let of_string s =
    if String.length s > 0 && String.length s <= 64
       && String.for_all valid_char s then Ok s
    else Error "id must contain 1-64 letters, digits, underscores, or hyphens"
  let to_string s = s
  let compare = String.compare
end

type side = Buy | Sell
type time_in_force = Gtc | Ioc | Fok | Post_only
type kind = Limit of Price.t * time_in_force | Market
type order = { id : Id.t; side : side; quantity : Quantity.t; kind : kind }
type command = Submit of order | Cancel of Id.t | Reduce of Id.t * Quantity.t
type resting = {
  id : Id.t; side : side; price : Price.t; quantity : Quantity.t; sequence : int;
}
type trade = {
  maker : Id.t; taker : Id.t; maker_side : side;
  price : Price.t; quantity : Quantity.t; sequence : int;
}
type expiry_reason = Ioc_remainder | Market_remainder
type event =
  | Accepted of int * order
  | Trade of trade
  | Rested of resting
  | Cancelled of int * resting
  | Reduced of int * resting * Quantity.t
  | Expired of int * Id.t * Quantity.t * expiry_reason
type error =
  | Duplicate_id of Id.t
  | Unknown_order of Id.t
  | Not_a_reduction of Id.t
  | Insufficient_liquidity of Id.t
  | Would_cross of Id.t
  | Sequence_exhausted

let side_to_string = function Buy -> "BUY" | Sell -> "SELL"
let tif_to_string = function
  | Gtc -> "GTC" | Ioc -> "IOC" | Fok -> "FOK" | Post_only -> "POST_ONLY"
let error_to_string = function
  | Duplicate_id id -> "duplicate order id: " ^ Id.to_string id
  | Unknown_order id -> "unknown active order: " ^ Id.to_string id
  | Not_a_reduction id -> "new quantity must be lower: " ^ Id.to_string id
  | Insufficient_liquidity id -> "FOK cannot fully fill: " ^ Id.to_string id
  | Would_cross id -> "post-only order would cross: " ^ Id.to_string id
  | Sequence_exhausted -> "command sequence exhausted"
let notional (t : trade) =
  Int64.mul (Int64.of_int (Price.to_int t.price))
    (Int64.of_int (Quantity.to_int t.quantity))
