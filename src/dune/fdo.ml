open! Stdune
module CC = Compilation_context

type phase =
  | All
  | Compile
  | Emit

let linear_ext = ".cmir-linear"

let linear_fdo_ext = linear_ext ^ "-fdo"

let fdo_profile_filename s = Path.extend_basename s ~suffix:".fdo-profile"

let linker_script_filename s = Path.extend_basename s ~suffix:".linker-script"

let linker_script_hot_filename s =
  Path.extend_basename s ~suffix:".linker-script-hot"

let phase_flags = function
  | None -> []
  | Some All -> [ "-g"; "-function-sections" ]
  | Some Compile ->
    [ "-g"; "-stop-after"; "scheduling"; "-save-ir-after"; "scheduling" ]
  | Some Emit -> [ "-g"; "-start-from"; "emit"; "-function-sections" ]

(* CR-soon gyorsh: add a rule to use profile with c/cxx profile if available,
   similarly to opt_rule for ocaml modules. The profile will have to be
   generated externally from perf data for example using google's autofdo
   toolset: create_gcov for gcc or create_llvm_prof for llvm. *)
let c_flags (ctx : Context.t) =
  match ctx.fdo_target_exe with
  | None -> []
  | Some _ -> [ "-ffunction-sections" ]

let cxx_flags = c_flags

(* Location of ocamlfdo binary tool is independent of the module, but may
   depend on the context. If it isn't cached elsewhere, we should do it here.
   CR gyorsh: is it cached? *)
let ocamlfdo_binary sctx dir =
  Super_context.resolve_program sctx ~dir ~loc:None "ocamlfdo"
    ~hint:"try: opam install ocamlfdo"

let ocamlfdo_flags (ctx : Context.t) =
  Env.get ctx.env "OCAMLFDO_FLAGS"
  |> Option.value ~default:"" |> String.extract_blank_separated_words

module Use_profile = struct
  type t =
    | If_exists
    | Always
    | Never

  let to_string = function
    | If_exists -> "if-exists"
    | Always -> "always"
    | Never -> "never"

  let default = If_exists

  let all = [ If_exists; Never; Always ]

  let var = "OCAMLFDO_USE_PROFILE"

  let of_context (ctx : Context.t) =
    match Env.get ctx.env var with
    | None -> default
    | Some v -> (
      match List.find_opt (fun s -> String.equal v (to_string s)) all with
      | Some v -> v
      | None ->
        User_error.raise
          [ Pp.textf
              "Failed to parse environment variable: %s=%s\n\
               Permitted values: if-exists always never\n\
               Default: %s"
              var v (to_string default)
          ] )
end

let use_profile ctx fdo_profile =
  let profile_exists =
    lazy (Path.as_in_source_tree_exn fdo_profile |> File_tree.file_exists)
  in
  let open Use_profile in
  match of_context ctx with
  | If_exists -> Lazy.force profile_exists
  | Always ->
    if Lazy.force profile_exists then
      true
    else
      User_error.raise
        [ Pp.textf "%s=%s but profile file %s does not exist." var
            (to_string Always)
            (Path.to_string fdo_profile)
        ]
  | Never -> false

let opt_rule cctx m fdo_target_exe =
  let sctx = CC.super_context cctx in
  let ctx = CC.context cctx in
  let dir = CC.dir cctx in
  let obj_dir = CC.obj_dir cctx in
  let linear = Obj_dir.Module.obj_file obj_dir m ~kind:Cmx ~ext:linear_ext in
  let linear_fdo =
    Obj_dir.Module.obj_file obj_dir m ~kind:Cmx ~ext:linear_fdo_ext
  in
  let fdo_profile = fdo_profile_filename fdo_target_exe in
  let open Build.O in
  let+ flags =
    if use_profile ctx fdo_profile then
      S
        [ A "-fdo-profile"
        ; Dep (Path.build fdo_profile)
        ; As [ "-md5-unit"; "-reorder-blocks"; "opt"; "-q" ]
        ]
    else
      As [ "-md5-unit"; "-extra-debug"; "-q" ]
  in
  Super_context.add_rule sctx ~dir
    (Command.run ~dir:(Path.build dir) (ocamlfdo_binary sctx dir)
       [ A "opt"
       ; Hidden_targets [ linear_fdo ]
       ; Dep (Path.build linear)
       ; As (ocamlfdo_flags ctx)
       ; Dyn flags
       ])

module Linker_script = struct
  type t = Path.t option

  let linker_script_rule cctx fdo_target_exe =
    let sctx = CC.super_context cctx in
    let ctx = CC.context cctx in
    let dir = CC.dir cctx in
    let linker_script_hot = linker_script_hot_filename fdo_target_exe in
    let fdo_profile = fdo_profile_filename fdo_target_exe in
    let linker_script = linker_script_filename fdo_target_exe in
    let linker_script_path =
      Path.Build.(relative ctx.build_dir linker_script)
    in
    let extra_flags =
      Env.get ctx.env "OCAMLFDO_LINKER_SCRIPT_FLAGS"
      |> Option.value ~default:"" |> String.extract_blank_separated_words
    in
    let use_profile = fdo_use_profile ctx fdo_profile in
    let flags =
      let open Command.Args in
      if use_profile then
        let fdo_profile_path =
          Path.build (Path.Build.relative ctx.build_dir fdo_profile)
        in
        S [ A "-fdo-profile"; Dep fdo_profile_path ]
      else if
        File_tree.file_exists Path.Source.(relative root linker_script_hot)
      then (
        let linker_script_hot_path =
          Path.build (Path.Build.relative ctx.build_dir linker_script_hot)
        in
        User_warning.emit
          ~hints:[ Pp.textf "To ignore %s, rename it." linker_script_hot ]
          [ Pp.textf
              "Linker script generation with ocamlfdo cannot get hot function \
               layout from profile, because either OCAMLFDO_USE_PROFILE=never \
               or %s not found. Hot functions layout from file %s will be \
               used."
              fdo_profile linker_script_hot
          ];
        S [ A "-linker-script-hot"; Dep linker_script_hot_path ]
      ) else
        As []
    in
    Super_context.add_rule sctx ~dir
      (Command.run ~dir:(Path.build ctx.build_dir) (ocamlfdo_binary sctx dir)
         [ A "linker-script"
         ; A "-o"
         ; Target linker_script_path
         ; flags
         ; A "-q"
         ; As extra_flags
         ]);
    Path.build linker_script_path

  let create cctx name =
    let ctx = CC.context cctx in
    match ctx.fdo_target_exe with
    | None -> None
    | Some fdo_target_exe ->
      if
        Path.equal name fdo_target_exe
        && ( Ocaml_version.supports_function_sections ctx.version
           || Ocaml_config.is_dev_version ctx.ocaml_config )
      then
        Some (linker_script_rule cctx fdo_target_exe)
      else
        None

  let flags t =
    let open Command.Args in
    match t with
    | None -> As []
    | Some linker_script ->
      S
        [ A "-ccopt"
        ; Concat ("", [ A "-Xlinker --script="; Dep linker_script ])
        ]
end
