// Copyright (c) Facebook, Inc. and its affiliates.
//
// This source code is licensed under the MIT license found in the
// LICENSE file in the "hack" directory of this source tree.
//
// @generated SignedSource<<2e318772c018495cc81a6f4374d61cc4>>
//
// To regenerate this file, run:
//   hphp/hack/src/oxidized_regen.sh

use arena_trait::TrivialDrop;
use no_pos_hash::NoPosHash;
use ocamlrep_derive::FromOcamlRepIn;
use ocamlrep_derive::ToOcamlRep;
use serde::Serialize;

#[allow(unused_imports)]
use crate::*;

pub use aast_defs::*;
pub use typing_defs::PossiblyEnforcedTy;
pub use typing_defs::Ty;
pub use typing_defs::ValKind;

pub type DeclTy<'a> = typing_defs::Ty<'a>;

#[derive(
    Clone,
    Debug,
    Eq,
    FromOcamlRepIn,
    Hash,
    NoPosHash,
    Ord,
    PartialEq,
    PartialOrd,
    Serialize,
    ToOcamlRep
)]
pub struct FunTastInfo {
    /// True if there are leaves of the function's imaginary CFG without a return statement
    pub has_implicit_return: bool,
    /// Result of {!Nast.named_body_is_unsafe}
    pub named_body_is_unsafe: bool,
}
impl TrivialDrop for FunTastInfo {}

#[derive(
    Clone,
    Debug,
    Eq,
    FromOcamlRepIn,
    Hash,
    NoPosHash,
    Ord,
    PartialEq,
    PartialOrd,
    Serialize,
    ToOcamlRep
)]
pub struct SavedEnv<'a> {
    pub tcopt: &'a typechecker_options::TypecheckerOptions<'a>,
    pub inference_env: &'a typing_inference_env::TypingInferenceEnv<'a>,
    pub tpenv: &'a type_parameter_env::TypeParameterEnv<'a>,
    pub condition_types: s_map::SMap<'a, &'a Ty<'a>>,
    pub pessimize: bool,
    pub fun_tast_info: Option<&'a FunTastInfo>,
}
impl<'a> TrivialDrop for SavedEnv<'a> {}

pub type Program<'a> =
    aast::Program<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type Def<'a> = aast::Def<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type Expr<'a> =
    aast::Expr<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type Expr_<'a> =
    aast::Expr_<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type Stmt<'a> =
    aast::Stmt<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type Block<'a> =
    aast::Block<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type Class_<'a> =
    aast::Class_<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type ClassId<'a> =
    aast::ClassId<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type TypeHint<'a> = aast::TypeHint<'a, &'a Ty<'a>>;

pub type Targ<'a> = aast::Targ<'a, &'a Ty<'a>>;

pub type ClassGetExpr<'a> =
    aast::ClassGetExpr<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type ClassTypeconst<'a> =
    aast::ClassTypeconst<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type UserAttribute<'a> =
    aast::UserAttribute<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type Fun_<'a> =
    aast::Fun_<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type FileAttribute<'a> =
    aast::FileAttribute<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type FunDef<'a> =
    aast::FunDef<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type FunParam<'a> =
    aast::FunParam<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type FuncBody<'a> =
    aast::FuncBody<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type Method_<'a> =
    aast::Method_<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type ClassVar<'a> =
    aast::ClassVar<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type ClassConst<'a> =
    aast::ClassConst<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type Tparam<'a> =
    aast::Tparam<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type Typedef<'a> =
    aast::Typedef<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type RecordDef<'a> =
    aast::RecordDef<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;

pub type Gconst<'a> =
    aast::Gconst<'a, (&'a pos::Pos<'a>, &'a Ty<'a>), (), &'a SavedEnv<'a>, &'a Ty<'a>>;
