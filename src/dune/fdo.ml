open! Stdune
module CC = Compilation_context

type phase =
  | All
  | Compile
  | Emit

let linear_ext () = ".cmir-linear"

let linear_fdo_ext () = linear_ext () ^ "-fdo"

let fdo_profile_filename s = s ^ ".fdo-profile"

let linker_script_filename s = s ^ ".linker-script"

let linker_script_hot_filename s = s ^ ".linker-script-hot"

let perf_data_filename s = s ^ ".perf.data"

let phase_flags = function
  | None -> []
  | Some All -> [ "-g"; "-function-sections" ]
  | Some Compile ->
    [ "-g"; "-stop-after"; "scheduling"; "-save-ir-after"; "scheduling" ]
  | Some Emit -> [ "-g"; "-start-from"; "emit"; "-function-sections" ]

(* Location of ocamlfdo binary tool is independent of the module, but may
   depend on the context. If it isn't cached elsewhere, we should do it here.
   CR gyorsh: is it cached? *)
let ocamlfdo_binary sctx dir =
  let ocamlfdo =
    Super_context.resolve_program sctx ~dir ~loc:None "ocamlfdo"
      ~hint:"try: opam install ocamlfdo"
  in
  match ocamlfdo with
  | Error e -> Action.Prog.Not_found.raise e
  | Ok _ -> ocamlfdo

(* CR gyorsh: this should also be cached *)
let fdo_use_profile (ctx : Context.t) name fdo_profile =
  let fdo_profile_src = Path.Source.(relative root fdo_profile) in
  let profile_exists = File_tree.file_exists fdo_profile_src in
  match Env.get ctx.env "OCAMLFDO_USE_PROFILE" with
  | None
  | Some "if-exists" ->
    profile_exists
  | Some "always" ->
    if profile_exists then
      true
    else
      User_error.raise
        [ Pp.textf
            "Cannot build %s: OCAMLFDO_USE_PROFILE=always but profile file %s \
             does not exist."
            name fdo_profile
        ]
  | Some "never" -> false
  | Some other ->
    User_error.raise
      [ Pp.textf
          "Failed to parse environment variable: OCAMLFDO_USE_PROFILE=%s\n\
           Permitted values: if-exists always never\n\
           Default: if-exists"
          other
      ]

let opt_rule cctx m fdo_target_exe =
  let sctx = CC.super_context cctx in
  let ctx = CC.context cctx in
  let dir = CC.dir cctx in
  let obj_dir = CC.obj_dir cctx in
  let linear =
    Obj_dir.Module.obj_file obj_dir m ~kind:Cmx ~ext:(linear_ext ())
  in
  let linear_fdo =
    Obj_dir.Module.obj_file obj_dir m ~kind:Cmx ~ext:(linear_fdo_ext ())
  in
  let fdo_profile = fdo_profile_filename fdo_target_exe in
  let name = Module_name.to_string (Module.name m) in
  let use_profile = fdo_use_profile ctx name fdo_profile in
  let flags =
    let open Command.Args in
    if use_profile then
      S
        [ A "-fdo-profile"
        ; Dep (Path.build (Path.Build.relative ctx.build_dir fdo_profile))
        ; As [ "-md5-unit"; "-reorder-blocks"; "opt"; "-q" ]
        ]
    else
      As [ "-md5-unit"; "-extra-debug"; "-q" ]
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
       ; flags
       ])

module Linker_script = struct
  type t = Path.t option

  let linker_script_rule cctx fdo_target_exe =
    let sctx = CC.super_context cctx in
    let ctx = CC.context cctx in
    let dir = CC.dir cctx in
    let ocamlfdo = ocamlfdo_binary sctx dir in
    let linker_script = linker_script_filename fdo_target_exe in
    let linker_script_path =
      Path.Build.(relative ctx.build_dir linker_script)
    in
    let linker_script_hot =
      Path.(relative root (linker_script_hot_filename fdo_target_exe))
    in
    let linker_script_template =
      match ocamlfdo with
      | Error _ -> assert false
      | Ok ocamlfdo_path ->
        let ocamlfdo_dir =
          ocamlfdo_path |> Path.to_absolute_filename |> Filename.dirname
        in
        ocamlfdo_dir ^ "/../etc/ocamlfdo/linker-script"
        |> Path.of_filename_relative_to_initial_cwd
    in
    let hot_exists = Build.file_exists linker_script_hot in
    let flags =
      let open Build.O in
      let+ hot_exists = hot_exists in
      let open Command.Args in
      if hot_exists then
        S [ A "-linker-script-hot"; Dep linker_script_hot ]
      else
        As []
    in
    Super_context.add_rule sctx ~dir
      (Command.run ~dir:(Path.build ctx.build_dir) ocamlfdo
         [ A "linker-script"
         ; A "-linker-script-template"
         ; Dep linker_script_template
         ; A "-o"
         ; Target linker_script_path
         ; Dyn flags
         ]);
    Path.build linker_script_path

  let create cctx name =
    let ctx = CC.context cctx in
    match ctx.fdo_target_exe with
    | None -> None
    | Some fdo_target_exe ->
      if
        String.equal name fdo_target_exe
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

let decode cctx fdo_target_exe =
  let sctx = CC.super_context cctx in
  let ctx = CC.context cctx in
  let dir = CC.dir cctx in
  let exe = Path.Build.(relative ctx.build_dir fdo_target_exe) in
  let perf_data = perf_data_filename fdo_target_exe in
  let perf_data_path = Path.(relative root perf_data) in
  let gen_suffix = "-gen" in
  let fdo_profile = fdo_profile_filename fdo_target_exe in
  let fdo_profile_gen = fdo_profile ^ gen_suffix in
  let hot = linker_script_hot_filename fdo_target_exe in
  let hot_gen = hot ^ gen_suffix in
  let fdo_profile_gen_path =
    Path.Build.relative ctx.build_dir fdo_profile_gen
  in
  let hot_gen_path = Path.Build.relative ctx.build_dir hot_gen in
  Super_context.add_rule sctx ~dir
    (Command.run ~dir:(Path.build ctx.build_dir) (ocamlfdo_binary sctx dir)
       [ A "decode"
       ; A "-binary"
       ; Dep (Path.build exe)
       ; A "-perf-profile"
       ; Dep perf_data_path
       ; A "-fdo-profile"
       ; Target fdo_profile_gen_path
       ; A "-linker-script-hot"
       ; Target hot_gen_path
       ; A "-q"
       ]);
  let copy_or_touch_in_build f =
    let dst = Path.Build.relative ctx.build_dir f in
    let src = Path.Source.(relative root f) in
    if not (File_tree.file_exists src) then
      Super_context.add_rule sctx ~dir (Build.write_file dst "");
    dst
  in
  let diff (f1, f2) =
    let f1 = Path.build f1 in
    let f2 = Path.build f2 in
    let action = Action.diff ~optional_in_source:true f1 f2 in
    let deps = [ f1; f2 ] in
    (deps, action)
  in
  let pairs =
    [ (copy_or_touch_in_build fdo_profile, fdo_profile_gen_path)
    ; (copy_or_touch_in_build hot, hot_gen_path)
    ]
  in
  (* CR gyorsh: Can't do it in sequence, because if the first diff fails, and
     then the file is promoted, then the second time decode target runs, it
     will use the promoted file and thus modify the executable. Both files need
     to be promoted at the same time. *)
  let deps, actions = List.map pairs ~f:diff |> List.split in
  let deps = List.concat deps in
  Super_context.add_alias_action sctx ~dir ~loc:None ~stamp:"fdo-decode"
    (Alias.fdo_decode ~dir)
    (let open Build.O in
    let+ () = Build.paths deps in
    Action.progn actions)

let decode_rule cctx name =
  let ctx = CC.context cctx in
  match ctx.fdo_target_exe with
  | None -> ()
  | Some fdo_target_exe ->
    if String.equal name fdo_target_exe then
      decode cctx fdo_target_exe
    else
      ()