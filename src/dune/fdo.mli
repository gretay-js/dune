(** Integration with feedback-directed optimizations using ocamlfdo. *)

type phase =
  | Compile
  | Emit

val linear_ext : unit -> string

val linear_fdo_ext : unit -> string

val phase_flags : phase option -> string list

val opt_rule : Compilation_context.t -> Module.t -> string -> unit

module Linker_script : sig
  type t

  val create : Compilation_context.t -> string -> t

  val flags : t -> Command.Args.dynamic Command.Args.t
end

val decode_rule : Compilation_context.t -> string -> unit
