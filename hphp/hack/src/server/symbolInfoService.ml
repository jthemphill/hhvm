(*
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Hh_prelude
open ServerCommandTypes.Symbol_info_service

(* This module dumps all the symbol info(like fun-calls) in input files *)

let recheck_naming ctx filename_l =
  List.iter filename_l (fun file ->
      Errors.ignore_ (fun () ->
          (* We only need to name to find references to locals *)
          List.iter (Ast_provider.get_ast ctx file) (function
              | Aast.Fun f ->
                let _ = Naming.fun_ ctx f in
                ()
              | Aast.Class c ->
                let _ = Naming.class_ ctx c in
                ()
              | _ -> ())))

let helper ctx acc filename_l =
  let filename_l = List.rev filename_l in
  recheck_naming ctx filename_l;
  let tasts =
    List.map filename_l ~f:(fun path ->
        let (ctx, entry) = Provider_context.add_entry_if_missing ~ctx ~path in
        let { Tast_provider.Compute_tast.tast; _ } =
          Tast_provider.compute_tast_unquarantined ~ctx ~entry
        in
        tast)
  in
  let fun_calls = SymbolFunCallService.find_fun_calls ctx tasts in
  let symbol_types = SymbolTypeService.generate_types ctx tasts in
  (fun_calls, symbol_types) :: acc

let parallel_helper workers filename_l tcopt =
  MultiWorker.call
    workers
    ~job:(helper tcopt)
    ~neutral:[]
    ~merge:List.rev_append
    ~next:(MultiWorker.next workers filename_l)

(* Format result from '(fun_calls * symbol_types) list' raw result into *)
(* 'fun_calls list, symbol_types list' and store in SymbolInfoService.result *)
let format_result raw_result =
  let result_list =
    List.fold_left
      raw_result
      ~f:
        begin
          fun acc bucket ->
          let (result1, result2) = acc in
          let (part1, part2) = bucket in
          (List.rev_append part1 result1, List.rev_append part2 result2)
        end
      ~init:([], [])
  in
  { fun_calls = fst result_list; symbol_types = snd result_list }

(* Entry Point *)
let go workers file_list env =
  let filename_l =
    file_list
    |> List.filter ~f:FindUtils.file_filter
    |> List.map ~f:(Relative_path.create Relative_path.Root)
  in
  let ctx = Provider_utils.ctx_from_server_env env in
  let raw_result =
    if List.length filename_l < 10 then
      helper ctx [] filename_l
    else
      parallel_helper workers filename_l ctx
  in
  format_result raw_result
