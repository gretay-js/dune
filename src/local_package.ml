open Stdune

type t =
  { odig_files : Path.t list
  ; ctx_build_dir : Path.t
  ; lib_stanzas : Dune_file.Library.t Super_context.Installable.t list
  ; installs : string Dune_file.Install_conf.t Super_context.Installable.t list
  ; docs : Dune_file.Documentation.t list
  ; mlds : Path.t list
  ; pkg : Package.t
  ; libs : Lib.Set.t
  }

let is_odig_doc_file fn =
  List.exists [ "README"; "LICENSE"; "CHANGE"; "HISTORY"]
    ~f:(fun prefix -> String.is_prefix fn ~prefix)

let add_stanzas t ~sctx =
  List.fold_left ~init:t
    ~f:(fun t (installable : Stanza.t Super_context.Installable.t) ->
      let path_expander =
        Super_context.expand_vars_string sctx
          ~scope:installable.scope ~dir:installable.dir
      in
      let open Dune_file in
      match installable.data with
      | Install i ->
        let i = { i with files = File_bindings.map ~f:path_expander i.files } in
        { t with
          installs = { installable with data = i } :: t.installs
        }
      | Library l ->
        { t with
          lib_stanzas = { installable with data = l } :: t.lib_stanzas
        }
      | Documentation l ->
        { t with
          docs = l :: t.docs
        ; mlds =
            let dir_contents = Dir_contents.get sctx ~dir:installable.dir in
            List.rev_append (Dir_contents.mlds dir_contents l)
              t.mlds
        }
      | _ -> t)

let of_sctx (sctx : Super_context.t) =
  let ctx = Super_context.context sctx in
  let stanzas = Super_context.stanzas_to_consider_for_install sctx in
  let stanzas_per_package =
    List.filter_map stanzas
      ~f:(fun (installable : Stanza.t Super_context.Installable.t) ->
        match Dune_file.stanza_package installable.data with
        | None -> None
        | Some p -> Some (p.name, installable))
    |> Package.Name.Map.of_list_multi
  in
  let libs_of =
    let libs = Super_context.libs_by_package sctx in
    fun (pkg : Package.t) ->
      match Package.Name.Map.find libs pkg.name with
      | Some (_, libs) -> libs
      | None -> Lib.Set.empty
  in
  Super_context.packages sctx
  |> Package.Name.Map.map ~f:(fun (pkg : Package.t) ->
    let odig_files =
      let files = Super_context.source_files sctx ~src_path:Path.root in
      String.Set.fold files ~init:[] ~f:(fun fn acc ->
        if is_odig_doc_file fn then
          Path.relative ctx.build_dir fn :: acc
        else
          acc)
    in
    let libs = libs_of pkg in
    let t =
      add_stanzas
        ~sctx
        { odig_files
        ; lib_stanzas = []
        ; docs = []
        ; installs = []
        ; pkg
        ; ctx_build_dir = ctx.build_dir
        ; libs
        ; mlds = []
        }
        (Package.Name.Map.find stanzas_per_package pkg.name
         |> Option.value ~default:[])
    in
    t
  )

let odig_files t = t.odig_files
let libs t = t.libs
let docs t = t.docs
let installs t = t.installs
let lib_stanzas t = t.lib_stanzas
let mlds t = t.mlds

let package t = t.pkg
let opam_file t = Path.append t.ctx_build_dir (Package.opam_file t.pkg)
let meta_file t = Path.append t.ctx_build_dir (Package.meta_file t.pkg)
let build_dir t = Path.append t.ctx_build_dir t.pkg.path
let name t = t.pkg.name

let install_paths t =
  Install.Section.Paths.make ~package:t.pkg.name ~destdir:Path.root ()
