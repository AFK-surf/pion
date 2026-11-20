///|
pub struct Program {
  packages : Array[Package]
}

///|
pub fn program_new(packages : Array[Package]) -> Program {
  Program::{ packages: packages }
}

///|
pub struct Package {
  name : String
  files : Array[SourceFile]
}

///|
pub struct ImportDecl {
  path : String
  alias_name : String
  span : Span
}

///|
pub struct SourceFile {
  path : String
  imports : Array[ImportDecl]
  decls : Array[Decl]
}

///|
pub enum TypeExpr {
  TyName(String, Array[TypeExpr], Span)
  TyFn(Array[TypeExpr], TypeExpr, Span)
  TyTuple(Array[TypeExpr], Span)
  TyMissing(Span)
}

///|
pub struct FieldDecl {
  name : String
  is_mut : Bool
  ty : TypeExpr
  span : Span
}

///|
pub struct VariantDecl {
  name : String
  fields : Array[TypeExpr]
  span : Span
}

///|
pub struct Param {
  name : String
  ty : TypeExpr
  span : Span
}

///|
pub struct StructDecl {
  is_pub : Bool
  is_val : Bool
  name : String
  type_params : Array[String]
  fields : Array[FieldDecl]
  span : Span
}

///|
pub struct EnumDecl {
  is_pub : Bool
  name : String
  type_params : Array[String]
  variants : Array[VariantDecl]
  span : Span
}

///|
pub struct TypeBound {
  param : String
  traits : Array[String]
}

///|
pub struct FnDecl {
  is_pub : Bool
  receiver_type : String
  name : String
  type_params : Array[String]
  type_bounds : Array[TypeBound]
  params : Array[Param]
  ret_ty : TypeExpr
  body : Array[Stmt]
  span : Span
}

///|
pub struct ExternFnDecl {
  is_pub : Bool
  abi : String
  name : String
  c_symbol : String
  params : Array[Param]
  ret_ty : TypeExpr
  span : Span
}

///|
pub struct TraitMethodDecl {
  name : String
  params : Array[Param]
  ret_ty : TypeExpr
  span : Span
}

///|
pub struct TraitDecl {
  is_pub : Bool
  name : String
  methods : Array[TraitMethodDecl]
  span : Span
}

///|
pub struct ImplDecl {
  trait_name : String
  target_type : String
  methods : Array[FnDecl]
  span : Span
}

///|
pub struct ConstDecl {
  is_pub : Bool
  name : String
  ty : TypeExpr
  value : Expr
  span : Span
}

///|
pub struct TestDecl {
  name : String
  body : Array[Stmt]
  span : Span
}

///|
pub enum Decl {
  DStruct(StructDecl)
  DEnum(EnumDecl)
  DFn(FnDecl)
  DExternFn(ExternFnDecl)
  DTrait(TraitDecl)
  DImpl(ImplDecl)
  DConst(ConstDecl)
  DTest(TestDecl)
}

///|
pub enum Pattern {
  PWild(Span)
  PIdent(String, Span)
  PBool(Bool, Span)
  PInt(String, Span)
  PString(String, Span)
  PChar(String, Span)
  PVariant(String, String, Array[Pattern], Span)
  PTuple(Array[Pattern], Span)
}

///|
pub struct MatchArm {
  pat : Pattern
  guard_expr : Option[Expr]
  body : Expr
  span : Span
}

///|
pub struct FieldInit {
  name : String
  value : Expr
  span : Span
}

///|
pub enum Stmt {
  SLet(String, Bool, TypeExpr, Expr, Span)
  SLetTuple(Array[String], TypeExpr, Expr, Span)
  SAssign(Expr, Expr, Span)
  SWhile(Expr, Array[Stmt], Span)
  SFor(Stmt, Expr, Stmt, Array[Stmt], Span)
  SForRange(String, Expr, Expr, Array[Stmt], Span)
  SForIn(String, Expr, Array[Stmt], Span)
  SReturn(Option[Expr], Span)
  SBreak(Span)
  SContinue(Span)
  SDebugAssert(Expr, Expr, Span)
  SExpr(Expr, Span)
}

///|
pub enum Expr {
  EInt(String, Span)
  EInt64(String, Span)
  EDouble(String, Span)
  EBool(Bool, Span)
  EByte(String, Span)
  EChar(String, Span)
  EString(String, Span)
  EIdent(String, Span)
  EPath(String, String, Span)
  EUnary(String, Expr, Span)
  EBinary(String, Expr, Expr, Span)
  ECall(Expr, Array[Expr], Span)
  EField(Expr, String, Span)
  EMethodCall(Expr, String, Array[Expr], Span)
  EIndex(Expr, Expr, Span)
  EArrayLit(Array[Expr], Span)
  EStructLit(String, Array[FieldInit], Span)
  ETuple(Array[Expr], Span)
  EBlock(Array[Stmt], Span)
  EIf(Expr, Array[Stmt], Option[Expr], Span)
  EMatch(Expr, Array[MatchArm], Span)
  EClosure(Array[Param], TypeExpr, Array[Stmt], Span)
  EScope(Expr, Expr, Span)
  ESpawn(Expr, Expr, Span)
  EMove(Expr, Span)
  EAs(Expr, TypeExpr, Span)
  ETry(Expr, Span)
  EInterp(Array[Expr], Span)
  EUnit(Span)
}

///|
pub fn expr_span(e : Expr) -> Span {
  match e {
    EInt(_, sp) => sp
    EInt64(_, sp) => sp
    EDouble(_, sp) => sp
    EBool(_, sp) => sp
    EByte(_, sp) => sp
    EChar(_, sp) => sp
    EString(_, sp) => sp
    EIdent(_, sp) => sp
    EPath(_, _, sp) => sp
    EUnary(_, _, sp) => sp
    EBinary(_, _, _, sp) => sp
    ECall(_, _, sp) => sp
    EField(_, _, sp) => sp
    EMethodCall(_, _, _, sp) => sp
    EIndex(_, _, sp) => sp
    EArrayLit(_, sp) => sp
    EStructLit(_, _, sp) => sp
    ETuple(_, sp) => sp
    EBlock(_, sp) => sp
    EIf(_, _, _, sp) => sp
    EMatch(_, _, sp) => sp
    EClosure(_, _, _, sp) => sp
    EScope(_, _, sp) => sp
    ESpawn(_, _, sp) => sp
    EMove(_, sp) => sp
    EAs(_, _, sp) => sp
    ETry(_, sp) => sp
    EInterp(_, sp) => sp
    EUnit(sp) => sp
  }
}

///|
pub fn type_expr_span(t : TypeExpr) -> Span {
  match t {
    TyName(_, _, sp) => sp
    TyFn(_, _, sp) => sp
    TyTuple(_, sp) => sp
    TyMissing(sp) => sp
  }
}

///|
pub fn type_expr_to_string(t : TypeExpr) -> String {
  match t {
    TyName(name, args, _) => {
      if args.length() == 0 {
        name
      } else {
        let sb = StringBuilder()
        sb.write_string(name)
        sb.write_string("[")
        let mut i = 0
        while i < args.length() {
          if i > 0 {
            sb.write_string(", ")
          }
          sb.write_string(type_expr_to_string(args[i]))
          i = i + 1
        }
        sb.write_string("]")
        sb.to_string()
      }
    }
    TyFn(params, ret, _) => {
      let sb = StringBuilder()
      sb.write_string("(")
      let mut i = 0
      while i < params.length() {
        if i > 0 {
          sb.write_string(", ")
        }
        sb.write_string(type_expr_to_string(params[i]))
        i = i + 1
      }
      sb.write_string(") -> ")
      sb.write_string(type_expr_to_string(ret))
      sb.to_string()
    }
    TyTuple(elems, _) => {
      let sb = StringBuilder()
      sb.write_string("(")
      let mut i = 0
      while i < elems.length() {
        if i > 0 {
          sb.write_string(", ")
        }
        sb.write_string(type_expr_to_string(elems[i]))
        i = i + 1
      }
      sb.write_string(")")
      sb.to_string()
    }
    TyMissing(_) => "<missing>"
  }
}
