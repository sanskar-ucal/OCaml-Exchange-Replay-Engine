open Types

(** Whitespace line protocol, # comments; prices are integer ticks. *)
val parse : string -> (command option, string) result
val command_to_string : command -> string
val event_to_string : event -> string
