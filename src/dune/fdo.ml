open! Stdune
module CC = Compilation_context

type phase =
  | Compile
  | Emit

let linear_ext = ".cmir-linear"

let linear_fdo_ext = linear_ext ^ "-fdo"

let phase_flags = function
  | None -> []
  | Some Compile ->
    [ "-g"; "-stop-after"; "scheduling"; "-save-ir-after"; "scheduling" ]
  | Some Emit -> [ "-g"; "-start-from"; "emit"; "-function-sections" ]

(* CR gyorsh: this should also be cached *)
let fdo_use_profile (ctx : Context.t) m profile_exists fdo_profile =
  match Env.get ctx.env "OCAMLFDO_USE_PROFILE" with
  | None
  | Some "if_exists" ->
    profile_exists
  | Some "always" ->
    if profile_exists then
      true
    else
      User_error.raise
        [ Pp.textf
            "Cannot build %s\n\
             OCAMLFDO_USE_PROFILE=always but profile file %s does not exist."
            (Module_name.to_string (Module.name m))
            fdo_profile
        ]
  | Some "never" -> false
  | Some other ->
    User_error.raise
      [ Pp.textf
          "Failed to parse environment variable\n\
           OCAMLFDO_USE_PROFILE=%s\n\
           Permitted values: if-exists always never\n\
           Default: if-exists"
          other
      ]

(* Location of ocamlfdo binary tool is independent of the module, but may
   depend on the context. If it isn't cached elsewhere, we should do it here. *)
let ocamlfdo_binary sctx dir =
  Super_context.resolve_program sctx ~dir ~loc:None "ocamlfdo"
    ~hint:"opam pin add --dev ocamlfdo"

let opt_rule cctx m fdo_target_exe =
  let sctx = CC.super_context cctx in
  let ctx = CC.context cctx in
  let dir = CC.dir cctx in
  let obj_dir = CC.obj_dir cctx in
  let linear = Obj_dir.Module.obj_file obj_dir m ~kind:Cmx ~ext:linear_ext in
  let linear_fdo =
    Obj_dir.Module.obj_file obj_dir m ~kind:Cmx ~ext:linear_fdo_ext
  in
  let fdo_profile = fdo_target_exe ^ ".fdo-profile" in
  let fdo_profile_path = Path.relative Path.root fdo_profile in
  let profile_exists = Build.file_exists fdo_profile_path in
  let flags =
    let open Build.O in
    let+ profile_exists = profile_exists in
    let use_profile = fdo_use_profile ctx m profile_exists fdo_profile in
    let open Command.Args in
    if use_profile then
      S
        [ A "-fdo-profile"
        ; Dep fdo_profile_path
        ; As [ "-md5-unit"; "-reorder-blocks"; "opt"; "-q" ]
        ]
    else
      S [ As [ "-md5-unit"; "-extra-debug"; "-q" ] ]
  in
  let ocamlfdo_flags =
    Env.get ctx.env "OCAMLFDO_FLAGS"
    |> Option.value ~default:"" |> String.extract_blank_separated_words
  in
  Super_context.add_rule sctx ~dir
    (Command.run ~dir:(Path.build dir) (ocamlfdo_binary sctx dir)
       [ A "opt"
       ; Hidden_targets [ linear_fdo ]
       ; Dep (Path.build linear)
       ; As ocamlfdo_flags
       ; Dyn flags
       ])

(*
 *
 * module Linker_script = struct
 *   type env =
 *     { name : string
 *     ; exe_dir : Path.t
 *     }
 *
 *   type t = env option
 *
 *   let use_linker_script exe_dir name =
 *     match fdo_target_exe with
 *     | None -> false
 *     | Some fdo_target_exe ->
 *       Path.( = )
 *         (Path.root_relative fdo_target_exe)
 *         (Path.relative ~dir:exe_dir name)
 *
 *   let create name ~exe_dir =
 *     if use_linker_script exe_dir name then
 *       Some { exe_dir; name }
 *     else
 *       None
 *
 *   let linker_script e = Path.relative ~dir:e.exe_dir (e.name ^ ".linker-script")
 *
 *   let linker_script_flags e ~linker_cwd =
 *     ccopts
 *       [ "-Xlinker"
 *       ; sprintf "--script=%s"
 *           (Path.reach_from ~dir:linker_cwd (linker_script e))
 *       ]
 *
 *   let linker_script_rule e ~ocaml_bin =
 *     (* CR-soon gyorsh: after import ocamlfdo remove ocamlfdo_path*)
 *     let ocamlfdo_path = ocaml_bin ^/ "ocamlfdo" in
 *     let linker_script = linker_script e in
 *     let linker_script_hot =
 *       Path.relative ~dir:e.exe_dir (e.name ^ ".linker-script-hot")
 *     in
 *     let linker_script_template =
 *       ocaml_bin ^ "/../etc/ocamlfdo/linker-script"
 *     in
 *     Rule.create ~extra_deps:[] ~targets:[ linker_script ]
 *       ( Dep.file_exists linker_script_hot
 *       >>= fun linker_script_hot_exists ->
 *       let deps =
 *         if linker_script_hot_exists then
 *           [ Dep.path linker_script_hot ]
 *         else
 *           []
 *       in
 *       let hot_flags =
 *         if linker_script_hot_exists then
 *           [ "-linker-script-hot"
 *           ; Path.reach_from ~dir:e.exe_dir linker_script_hot
 *           ]
 *         else
 *           []
 *       in
 *       Dep.all_unit deps
 *       >>= fun () ->
 *       Dep.path (Path.absolute linker_script_template)
 *       >>| fun () ->
 *       Action.process ~can_go_in_shared_cache:true ~sandbox:Sandbox.hardlink
 *         ~dir:e.exe_dir ocamlfdo_path
 *         ( [ "linker-script"
 *           ; "-linker-script-template"
 *           ; linker_script_template
 *           ; "-o"
 *           ; Path.reach_from ~dir:e.exe_dir linker_script
 *           ]
 *         @ hot_flags ) )
 *
 *   let deps = function
 *     | None -> []
 *     | Some e -> [ Dep.path (linker_script e) ]
 *
 *   let flags t ~linker_cwd =
 *     match t with
 *     | None -> []
 *     | Some e -> linker_script_flags e ~linker_cwd
 *
 *   let rules t ~ocaml_bin =
 *     match t with
 *     | None -> []
 *     | Some e -> [ linker_script_rule e ~ocaml_bin ]
 * end *)

(* (* for env *)
 *
 *
 * let ocamlfdoflags =
 *   let default = [] in
 *   peek_register_ordered_set_lang "OCAMLFDOFLAGS" ~default
 *
 * (* for the main compilation rule *)
 *
 *   let standard_compile_rule = compile_rule ~impl:ml ~phase_flags:[] standard_targets in
 *   let fdo_compile_rule =
 *     compile_rule
 *       ~impl:ml
 *       ~phase_flags:[ "-g"; "-stop-after"; "scheduling"; "-save-ir-after"; "scheduling" ]
 *       (linear :: compile_targets)
 *   in
 *   let fdo_emit_rule =
 *     compile_rule
 *       ~impl:fdo_linear
 *       ~phase_flags:[ "-g"; "-start-from"; "emit"; "-function-sections" ]
 *       emit_targets
 *   in
 *   let fdo_linear_rule =
 *     Fdo.opt_rule ~dir ~ocamlfdoflags ~source:linear ~target:fdo_linear ~ocaml_bin
 *   in
 *   List.concat
 *     [ (if Fdo.enabled
 *        then [ fdo_compile_rule; fdo_linear_rule; fdo_emit_rule ]
 *        else [ standard_compile_rule ])
 *     ; (match spec_to_param with
 *        | Some conf -> [ Spec_to_param.rule ~dir ~ml ~cmt conf ]
 *        | None -> [])
 *     ] *)

(* let fdo_linker_script = Fdo.Linker_script.create name ~exe_dir in
 *
 * @ Fdo.Linker_script.deps fdo_linker_script
 * ; Fdo.Linker_script.flags fdo_linker_script ~linker_cwd
 *           ; Fdo.Linker_script.rules fdo_linker_script ~ocaml_bin *)

(* decode_rule Sc.mode promote exe_crules.ml gen_rules.ml exe.ml *)
