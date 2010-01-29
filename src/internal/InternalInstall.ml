
(** Install using ocaml-autobuild internal scheme
    @author Sylvain Le Gall
  *)

open BaseEnv
open BaseStandardVar
open OASISTypes

let srcdir =
  var_define
    "srcdir"
    (lazy ".")

let builddir =
  var_define
    "builddir"
    (lazy (Filename.concat (srcdir ()) "_build"))

let dllfn path name = 
  Filename.concat path ("dll"^name^(ext_dll ()))

let libfn path name =
  Filename.concat path ("lib"^name^(ext_lib ()))

let exec_hook =
  ref (fun exec -> exec)

let lib_hook =
  ref (fun _ lib -> lib, [])

let install_file_ev = 
  "install-file"

let install_dir_ev =
  "install-dir"

let install_findlib_ev =
  "install-findlib"

let install pkg argv =
  let rootdirs =
    [srcdir (); builddir ()]
  in

  let ( * ) lst1 lst2 = 
    List.flatten 
      (List.map 
         (fun a -> 
            List.map 
              (fun b -> a,b) 
              lst2) 
         lst1)
  in

  let make_filename =
    function
      | [] -> "" 
      | hd :: tl  -> List.fold_left Filename.concat hd tl
  in

  let make_module nm = 
    [String.capitalize nm; String.uncapitalize nm]
  in

  let find_file f lst = 
    let alternatives =
      List.map (fun e -> make_filename (f e)) lst
    in
      try 
        List.find Sys.file_exists alternatives
      with Not_found ->
        failwith 
          (Printf.sprintf 
             "Cannot find any of the files: %s"
             (String.concat ", " 
                (List.map 
                   (Printf.sprintf "%S")
                   alternatives)))
  in

  let find_build_file fn =
    find_file
      (fun rootdir -> [rootdir; fn])
      rootdirs
  in

  let is_native comp_type =
    match comp_type with 
      | Best -> (ocamlbest ()) = "native" 
      | Byte -> false
      | Native -> true
  in

  let install_file src_file envdir = 
    let tgt_dir = 
      envdir ()
    in
    let tgt_file =
      Filename.concat 
        tgt_dir
        (Filename.basename src_file)
    in
      (* Check that target directory exist *)
      if not (Sys.file_exists tgt_dir) then
        (
          BaseMessage.info 
            (Printf.sprintf 
               "Creating directory '%s'"
               tgt_dir);
          BaseFileUtil.mkdir tgt_dir;
          BaseLog.register install_dir_ev tgt_dir
        );

      (* Really install files *)
      BaseMessage.info 
        (Printf.sprintf 
           "Copying file '%s' to '%s'"
           src_file
           tgt_file);
      BaseFileUtil.cp src_file tgt_file;
      BaseLog.register install_file_ev tgt_file
  in

  let install_data path files_targets = 
    List.iter
      (fun (src, tgt_opt) ->
         let real_srcs = 
           let real_src = 
             Filename.concat path src
           in
           (* Glob the src expression *)
           let filename = 
             Filename.basename real_src
           in
             if String.contains filename '*' then
               (
                 let ext = 
                   match BaseUtils.split '.' filename with 
                     | [a; b] when a = "*" -> 
                         "."^b
                     | _ ->
                         failwith 
                           (Printf.sprintf 
                              "Invalid file wildcard in '%s'"
                              src)
                 in
                 let ext_len =
                   String.length ext
                 in
                 let dirname =
                   Filename.dirname real_src
                 in
                 let res =
                   Array.fold_left
                     (fun acc fn ->
                        try 
                          let fn_ext = 
                            String.sub 
                              fn 
                              ((String.length fn) - ext_len) 
                              ext_len
                          in
                            if fn_ext = ext then
                              (Filename.concat dirname fn) :: acc
                            else
                              acc
                        with Invalid_argument "String.sub" ->
                          acc)
                     []
                     (Sys.readdir dirname)
                 in
                   if res = [] then
                     failwith 
                       (Printf.sprintf 
                          "Wildcard '%s' doesn't match any files"
                          src);
                   res
               )
             else
               (
                 [real_src]
               )
         in
           List.iter 
             (fun fn -> 
                install_file 
                  fn 
                  (fun () -> 
                     match tgt_opt with 
                       | Some s -> var_expand s
                       | None -> var_expand "$datarootdir/$pkg_name")) 
             real_srcs)
           
      files_targets
  in

  let install_lib (lib_name, lib) = 
    let lib, lib_extra =
      !lib_hook lib_name lib
    in
      if var_choose lib.lib_install then
        (
          let find_lib_file fn =
            find_file
              (fun rootdir -> [rootdir; lib.lib_path; fn])
              rootdirs
          in

          let module_to_cmi modul =
            find_file 
               (fun (rootdir, fn) -> [rootdir; lib.lib_path; (fn^".cmi")])
               (rootdirs * (make_module modul))
          in

          let module_to_header modul =
            assert(modul <> "");
            find_file 
               (fun ((rootdir, fn), ext) -> [rootdir; lib.lib_path; fn^ext])
               (rootdirs * (make_module modul) * [".mli"; ".ml"])
          in
            
          let files =
            List.flatten
              (
                [
                  find_lib_file "META";
                  find_lib_file (lib_name^".cma");
                ]
                :: 
                (if is_native lib.lib_compiled_object then
                   (
                     try 
                       [
                         find_lib_file (lib_name^".cmxa");
                         find_lib_file (lib_name^(ext_lib ()));
                       ]
                     with Failure txt ->
                       BaseMessage.warning 
                         (Printf.sprintf
                            "Cannot install native library %s: %s"
                            lib_name
                            txt);
                       []
                   )
                 else
                   []
                )
                ::
                lib_extra
                ::
                (if lib.lib_c_sources <> [] then
                   [
                     find_build_file (libfn lib.lib_path lib_name);
                   ]
                 else
                   [])
                ::
                (* Some architecture doesn't allow shared library (Cygwin, AIX) *)
                (if lib.lib_c_sources <> [] then
                   (try 
                     [
                       find_build_file (dllfn lib.lib_path lib_name);
                     ]
                    with Failure txt ->
                      if (os_type ()) <> "Cygwin" then
                        BaseMessage.warning
                          (Printf.sprintf
                             "Cannot install C static library %s: %s"
                             lib_name
                             txt);
                      [])
                 else
                   [])
                ::
                (
                  List.rev_map
                    (fun modul -> [module_to_cmi modul; module_to_header modul])
                    lib.lib_modules
                )
              )
          in
            BaseMessage.info 
              (Printf.sprintf
                 "Installing findlib library '%s'"
                 lib_name);
            BaseExec.run "ocamlfind" ("install" :: lib_name :: files);
            BaseLog.register install_findlib_ev lib_name;
            install_data lib.lib_path lib.lib_data_files;
        )
  in

  let install_exec (exec_name, exec) =
    let exec =
      !exec_hook exec
    in
      if var_choose exec.exec_install then
        (
          let exec_path = 
            (* TODO: move this to OASISExecutable *)
            Filename.dirname exec.exec_main_is
          in
          let () = 
            install_file
              (find_build_file
                 (exec.exec_is^(suffix_program ())))
              bindir;
            install_data 
              exec_path
              exec.exec_data_files 
          in
            if exec.exec_c_sources <> [] && 
               not exec.exec_custom && 
               not (is_native exec.exec_compiled_object) then
              (
                install_file
                  (find_build_file
                     (dllfn exec_path exec_name))
                  libdir
              )
            else
              ()
        )
  in
  
    List.iter install_lib pkg.libraries;
    List.iter install_exec pkg.executables

(* Uninstall already installed data *)
let uninstall _ argv =
  List.iter 
    (fun (ev, data) ->
       if ev = install_file_ev then
         (
           if Sys.file_exists data then
             (
               BaseMessage.info
                 (Printf.sprintf 
                    "Removing file '%s'"
                    data);
               Sys.remove data
             )
         )
       else if ev = install_dir_ev then
         (
           if Sys.file_exists data && Sys.is_directory data then
             (
               if Sys.readdir data = [||] then
                 (
                   BaseMessage.info
                     (Printf.sprintf 
                        "Removing directory '%s'"
                        data);
                   BaseFileUtil.rmdir data
                 )
               else
                 (
                   BaseMessage.warning 
                     (Printf.sprintf
                        "Directory '%s' is not empty (%s)"
                        data
                        (String.concat 
                           ", " 
                           (Array.to_list 
                              (Sys.readdir data))))
                 )
             )
         )
       else if ev = install_findlib_ev then
         (
           BaseMessage.info
             (Printf.sprintf
                "Removing findlib library '%s'"
                data);
           BaseExec.run (ocamlfind ()) ["remove"; data]
         )
       else
         (
           failwith (Printf.sprintf "Unknown log event '%s'" ev)
         );
       BaseLog.unregister ev data)
    (* We process event in reverse order *)
    (List.rev 
       (BaseLog.filter 
          [install_file_ev; 
           install_dir_ev;
           install_findlib_ev;]))

(* END EXPORT *)

open BasePlugin

(* Installation *)
let plugin_install_main pkg =
    {
      moduls       = [InternalData.internalsys_ml];
      setup        = func install "InternalInstall.install";
      clean        = None;
      distclean    = None;
      other_action = ignore;
      files_generated  = [];
    },
    pkg

(* Uninstall *)
let plugin_uninstall_main pkg = 
  {
    moduls       = [InternalData.internalsys_ml];
    setup        = func uninstall "InternalInstall.uninstall";
    clean        = None;
    distclean    = None;
    other_action = ignore;
    files_generated  = [];
  },
  pkg

