#!/usr/bin/env bash
# classtag-synth.sh TREE FROMTREE : a compiler that synthesizes scala.reflect.ClassTags (the
# bridge to e4976678fa, 2012-04, "Next generation of macros": its compiler needs ClassTags
# to be compiled, its library has them, and the reference compiler for it was built
# outside the history).  TREE's compiler (the one before) synthesizes a ClassTag[T] like a
# class manifest, ClassTag[T](classOf[erasure of T]); FROMTREE is not used.
set -euo pipefail
python3 -I - $1/src/compiler/scala/tools/nsc/typechecker/Implicits.scala <<'PY'
import sys
f = sys.argv[1]; s = open(f).read()
anchor = "      case TypeRef(_, sym, args) if ManifestSymbols(sym) =>"
assert s.count(anchor) == 1, "anchor"
s = s.replace(anchor, """      // (bridge: ClassTags synthesized from the class's erasure)
      case TypeRef(_, sym, List(arg)) if sym.fullName == "scala.reflect.ClassTag" =>
        classTagOf(sym, arg)
""" + anchor)
anchor2 = "    /** The manifest corresponding to type `pt`, provided `pt` is an instance of Manifest."
assert s.count(anchor2) == 1, "anchor2"
s = s.replace(anchor2, """    private def classTagOf(ctagClass: Symbol, tp: Type): SearchResult = {
      val tp1 = tp.dealias.widen
      def ctag(t: Type) = inferImplicit(tree, appliedType(ctagClass.typeConstructor, List(t)), true, false, context).tree
      val res: Tree = tp1 match {
        case TypeRef(_, definitions.ArrayClass, List(elem)) if elem.typeSymbol.isAbstractType =>
          val e = ctag(elem)
          if (e.isEmpty) EmptyTree else typedPos(tree.pos.focus)(Select(e, newTermName("wrap")))
        case _ if tp1.typeSymbol.isAbstractType || tp1.typeSymbol.isExistentiallyBound => EmptyTree
        case _ =>
          typedPos(tree.pos.focus)(Apply(TypeApply(Select(gen.mkAttributedRef(ctagClass.companionModule), nme.apply),
            List(TypeTree(tp))), List(gen.mkClassOf(tp1))))
      }
      if (res.isEmpty) SearchFailure else wrapResult(res)
    }

""" + anchor2)
# (looked up lazily: ClassTag may be a source file of the run)
old = "  private val ManifestSymbols = Set(PartialManifestClass, FullManifestClass, OptManifestClass)"
assert s.count(old) == 1, "ManifestSymbols"
s = s.replace(old, old.replace("private val", "private lazy val"))
open(f, "w").write(s)
PY
# (and without a ClassManifest class, which the new library makes an alias of ClassTag, class
# manifests are ClassTags)
python3 -I - $1/src/compiler/scala/reflect/internal/Definitions.scala <<'PY'
import sys
f = sys.argv[1]; s = open(f).read()
old = """    lazy val PartialManifestClass  = getRequiredClass("scala.reflect.ClassManifest")
    lazy val PartialManifestModule = getRequiredModule("scala.reflect.ClassManifest")"""
assert s.count(old) == 1, "Definitions"
s = s.replace(old, """    lazy val PartialManifestClass  = getClassIfDefined("scala.reflect.ClassManifest") orElse getRequiredClass("scala.reflect.ClassTag")
    lazy val PartialManifestModule = getModuleIfDefined("scala.reflect.ClassManifest") orElse getRequiredModule("scala.reflect.ClassTag")""")
open(f, "w").write(s)
PY
# (and `new Array[T]` takes a ClassTag of T, as a class manifest, when there is no class manifest)
python3 -I - $1/src/compiler/scala/tools/nsc/typechecker/Typers.scala <<'PY'
import sys
f = sys.argv[1]; s = open(f).read()
old = """    def findManifest(tp: Type, full: Boolean) = beforeTyper {
      inferImplicit(
        EmptyTree,
        appliedType((if (full) FullManifestClass else PartialManifestClass).typeConstructor, List(tp)),
        true, false, context)
    }"""
assert s.count(old) == 1, "findManifest"
s = s.replace(old, """    def findManifest(tp: Type, full: Boolean) = beforeTyper {
      val r = inferImplicit(
        EmptyTree,
        appliedType((if (full) FullManifestClass else PartialManifestClass).typeConstructor, List(tp)),
        true, false, context)
      val ct = if (full || !r.tree.isEmpty) NoSymbol else definitions.getClassIfDefined("scala.reflect.ClassTag")
      if (ct == NoSymbol) r
      else inferImplicit(EmptyTree, appliedType(ct.typeConstructor, List(tp)), true, false, context)
    }""")
open(f, "w").write(s)
PY
