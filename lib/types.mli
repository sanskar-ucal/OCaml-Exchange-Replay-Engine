(** Integer ticks and units are separate abstract types; construction is checked. *)
module Price : sig
  type t
  val of_int : int -> (t, string) result
  val to_int : t -> int
  val compare : t -> t -> int
end

module Quantity : sig
  type t
  val of_int : int -> (t, string) result
  val to_int : t -> int
end

module Id : sig
  type t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val compare : t -> t -> int
end

type side = Buy | Sell
type time_in_force = Gtc | Ioc | Fok | Post_only
type kind = Limit of Price.t * time_in_force | Market
type order = { id : Id.t; side : side; quantity : Quantity.t; kind : kind }
type command = Submit of order | Cancel of Id.t | Reduce of Id.t * Quantity.t

type resting = {
  id : Id.t;
  side : side;
  price : Price.t;
  quantity : Quantity.t;
  sequence : int;
}

type trade = {
  maker : Id.t;
  taker : Id.t;
  maker_side : side;
  price : Price.t;
  quantity : Quantity.t;
  sequence : int;
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

val side_to_string : side -> string
val tif_to_string : time_in_force -> string
val error_to_string : error -> string
val notional : trade -> int64
