open Types

(** Persistent, single-instrument order book. No clock or I/O in the core. *)
type t
val empty : t
val apply : t -> command -> (t * event list, error) result
val open_orders : t -> resting list
val best_bid : t -> Price.t option
val best_ask : t -> Price.t option
val sequence : t -> int
val active_count : t -> int

(** Canonical state includes active orders, sequence and previously used IDs. *)
val canonical : t -> string

(** A compact MD5 label for demos, NOT an authentication mechanism. *)
val fingerprint : t -> string
val check_invariants : t -> (unit, string) result
