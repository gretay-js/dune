(* open Core
 * open Import
 *
 * let fdo_target_exe =
 *   let f = function
 *     | "" -> None
 *     | s -> (
 *       match String.is_suffix ~suffix:".exe" s && Filename.is_relative s with
 *       | true -> Some s
 *       | false ->
 *         failwithf
 *           "Bad WITH_FDO: %s\n\
 *            Please specify the name of the executable to optimize, \n\
 *            including path from jenga root. For example, \n\
 *           \  WITH_FDO='app/pal/bin/pal.exe'"
 *           s () )
 *   in
 *   Var.peek (Var.register_with_default "WITH_FDO" ~default:"" |> Var.map ~f)
 *
 * let enabled = Option.is_some fdo_target_exe
 *
 * let fdo_use_profile =
 *   match
 *     Var.peek
 *       (Var.register_enumeration "OCAMLFDO_USE_PROFILE"
 *          ~choices:
 *            (String.Map.of_alist_exn
 *               [ ("always", `Always)
 *               ; ("never", `Never)
 *               ; ("if-exists", `If_exists)
 *               ])
 *          ~default:"if-exists"
 *          ~fallback:(fun _ -> None))
 *   with
 *   | Ok a -> a
 *   | Error (`Bad s) -> failwithf "invalid OCAMLFDO_USE_PROFILE %s" s ()
 *
 * let _ocamlfdo_path = Named_artifact.binary "ocamlfdo"
 *
 * let opt_rule cctx ~dir ~src ~taget  =
 *   let linear_fdo = linear ^ "-fdo" in
 *   Super_context.add_rule sctx ~dir
 *     (Command.run ~dir:(Path.build dir)
 *        (Super_context.resolve_program sctx ~dir ~loc:(Some loc) "ocamlfdo"
 *           ~hint:"opam pin add --dev ocamlfdo")
 *        [ A "opt"
 *        ; As flags
 *        ; Target linear_fdo
 *        ; Deps (Path.build linear)
 *        ]);
 *
 *
 * let opt_rule_from_jenga ~dir ~source ~target ~ocamlfdoflags ~ocaml_bin =
 *   (* CR-soon gyorsh: after import ocamlfdo remove ocamlfdo_path*)
 *   let ocamlfdo_path = ocaml_bin ^/ "ocamlfdo" in
 *   Rule.create ~extra_deps:[] ~targets:[ target ]
 *     ( Dep.path source
 *     >>= fun () ->
 *     let fdo_profile =
 *       Path.root_relative (Option.value_exn fdo_target_exe ^ ".fdo-profile")
 *     in
 *     Dep.file_exists fdo_profile
 *     >>= fun profile_exists ->
 *     let use_profile =
 *       match fdo_use_profile with
 *       | `If_exists -> profile_exists
 *       | `Always ->
 *         if profile_exists then
 *           true
 *         else
 *           Located_error.raisef
 *             ~loc:{ source = File source; line = 1; start_col = 0; end_col = 0 }
 *             !"%{Path} cannot be built: OCAMLFDO_USE_PROFILE=always but \
 *               profile file %{Path} does not exist."
 *             source fdo_profile ()
 *       | `Never -> false
 *     in
 *     let deps =
 *       if use_profile then
 *         [ Dep.path fdo_profile ]
 *       else
 *         []
 *     in
 *     let flags =
 *       if use_profile then
 *         [ "-fdo-profile"
 *         ; Path.reach_from ~dir fdo_profile
 *         ; "-md5-unit"
 *         ; "-reorder-blocks"
 *         ; "opt"
 *         ; "-q"
 *         ]
 *       else
 *         [ "-md5-unit"; "-extra-debug"; "-q" ]
 *     in
 *     Dep.all_unit deps
 *     >>| fun () ->
 *     Action.process ~can_go_in_shared_cache:true ~sandbox:Sandbox.hardlink ~dir
 *       ocamlfdo_path
 *       ([ "opt" ] @ flags @ ocamlfdoflags @ [ basename source ]) )
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

let flags = function
  | None -> flags
  | Some Compile ->
    [ "-g"; "-stop-after"; "scheduling"; "-save-ir-after"; "scheduling" ]
  | Some Emit -> [ "-g"; "-start-from"; "emit"; "-function-sections" ]

let linear_ext = ".cmir-linear"

let make_filename s = s ^ "-fdo"
