(** Integration with feedback-directed optimizations using ocamlfdo. *)

type phase =
  | Compile
  | Emit

val linear_ext : string

val linear_fdo_ext : string

val phase_flags : phase option -> string list

val opt_rule : Compilation_context.t -> Module.t -> string -> unit

module Linker_script : sig
  type t

  val create : Compilation_context.t -> string -> t

  val flags : t -> Command.Args.dynamic Command.Args.t

  val deps : t -> Stdune.Path.t list
end
