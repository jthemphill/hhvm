(*
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

(*****************************************************************************)
(* Module used to enforce that Enum subclasses are used reasonably.
 * Exports the Enum type as the type of all constants, checks that constants
 * have the proper type, and restricts what types can be used for enums.
 *)
(*****************************************************************************)
open Hh_prelude
open Aast
open Typing_defs
module Phase = Typing_phase
module Cls = Decl_provider.Class
module MakeType = Typing_make_type

let member_type env member_ce =
  let (lazy default_result) = member_ce.ce_type in
  if Option.is_none (get_ce_xhp_attr member_ce) then
    default_result
  else
    match get_node default_result with
    | Tapply (enum_id, _) ->
      (* XHP attribute type transform is necessary to account for
       * non-first class Enums:

       * attribute MyEnum x; // declaration: MyEnum
       * $this->:x;          // usage: MyEnumType
       *)
      let maybe_enum = Typing_env.get_class env (snd enum_id) in
      (match maybe_enum with
      | None -> default_result
      | Some tc ->
        (match
           Decl_enum.enum_kind
             (Cls.pos tc, Cls.name tc)
             (Cls.enum_type tc)
             Option.(
               Cls.get_typeconst tc Naming_special_names.FB.tInner >>= fun t ->
               t.ttc_type)
             (Cls.get_ancestor tc)
         with
        | None -> default_result
        | Some
            {
              Decl_enum.base = _;
              type_ = enum_ty;
              constraint_ = _;
              interface = _;
            } ->
          let ty = mk (get_reason default_result, get_node enum_ty) in
          ty))
    | _ -> default_result

let enum_check_const ty_exp env cc t =
  let p = fst cc.cc_id in
  Typing_ops.sub_type
    p
    Reason.URenum
    env
    t
    ty_exp
    Errors.constant_does_not_match_enum_type

(* Check that the `as` bound or the underlying type of an enum is a subtype of
 * arraykey. For enum class, check that it is a denotable closed type:
 * no free type parameters are allowed, and we also prevent uncertain cases,
 * like any, or dynamic. The free status of type parameter is caught during
 * naming (Unbound name), so we only check the kind of type that is used.
 *)
let enum_check_type env pos ur ty_interface ty _on_error =
  let ty_arraykey =
    MakeType.arraykey (Reason.Rimplicit_upper_bound (pos, "arraykey"))
  in
  let rec is_valid_base lty =
    match get_node lty with
    | Tprim _
    | Tnonnull ->
      true
    | Toption lty -> is_valid_base lty
    | Ttuple ltys -> List.for_all ~f:is_valid_base ltys
    | Tnewtype (_, ltys, lty) -> List.for_all ~f:is_valid_base (lty :: ltys)
    | Tclass (_, _, ltys) -> List.for_all ~f:is_valid_base ltys
    | _ -> false
  in
  match ty_interface with
  | Some interface ->
    if not (is_valid_base interface) then
      Errors.enum_type_bad
        pos
        true
        (Typing_print.full_strip_ns env interface)
        [];
    env
  | None ->
    Typing_ops.sub_type pos ur env ty ty_arraykey (fun ?code:_ _ _ ->
        Errors.enum_type_bad pos false (Typing_print.full_strip_ns env ty) [])

(* Check an enum declaration of the form
 *    enum E : <ty_exp> as <ty_constraint>
 * or
 *    class E extends Enum<ty_exp>
 * where the absence of <ty_constraint> is assumed to default to arraykey.
 *
 * Check that <ty_exp> is int or string, and that
 *   ty_exp <: ty_constraint <: arraykey
 * Also that each type constant is of type ty_exp.
 *)
let enum_class_check env tc consts const_types =
  let pos = Cls.pos tc in
  let enum_info_opt =
    Decl_enum.enum_kind
      (pos, Cls.name tc)
      (Cls.enum_type tc)
      Option.(
        Cls.get_typeconst tc Naming_special_names.FB.tInner >>= fun t ->
        t.ttc_type)
      (Cls.get_ancestor tc)
  in
  match enum_info_opt with
  | Some
      {
        Decl_enum.base = ty_exp;
        type_ = _;
        constraint_ = ty_constraint;
        interface = ty_interface;
      } ->
    let (env, ty_exp) =
      Phase.localize_with_self env ~ignore_errors:false ty_exp
    in
    let (env, ty_interface) =
      match ty_interface with
      | Some dty ->
        let (env, lty) =
          Phase.localize_with_self env ~ignore_errors:false dty
        in
        (env, Some lty)
      | None -> (env, None)
    in
    (* Check that ty_exp <: arraykey *)
    let env =
      enum_check_type
        env
        pos
        Reason.URenum_underlying
        ty_interface
        ty_exp
        Errors.enum_underlying_type_must_be_arraykey
    in
    (* Check that ty_exp <: ty_constraint <: arraykey *)
    let env =
      match ty_constraint with
      | None -> env
      | Some ty ->
        let (env, ty) = Phase.localize_with_self env ~ignore_errors:false ty in
        let env =
          enum_check_type
            env
            pos
            Reason.URenum_cstr
            None (* Enum classes do not have constraints *)
            ty
            Errors.enum_constraint_must_be_arraykey
        in
        Typing_ops.sub_type
          pos
          Reason.URenum_incompatible_cstr
          env
          ty_exp
          ty
          Errors.enum_subtype_must_have_compatible_constraint
    in
    List.fold2_exn ~f:(enum_check_const ty_exp) ~init:env consts const_types
  | None -> env
