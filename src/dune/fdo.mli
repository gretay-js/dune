(** Integration with feedback-directed optimizations using ocamlfdo. *)

type phase = Compile | Emit

val linear_ext : string

val linear_fdo_ext : string

val flags : phase option -> string list


(* open Import
 *
 * val enabled : bool
 *
 * val opt_rule :
 *      dir:Path.t
 *   -> source:Path.t
 *   -> target:Path.t
 *   -> ocamlfdoflags:string list
 *   -> ocaml_bin:string
 *   -> Rule.t
 *
 * module Linker_script : sig
 *   type t
 *
 *   val create : string -> exe_dir:Path.t -> t
 *
 *   val deps : t -> unit Dep.t list
 *
 *   val flags : t -> linker_cwd:Path.t -> string list
 *
 *   val rules : t -> ocaml_bin:string -> Rule.t list
 * end *)
