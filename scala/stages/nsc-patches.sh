# patches for the classfile reader of nsc (Scala 2), applied in src/
F=src/scala/tools/nsc/symtab/classfile/ClassfileParser.scala
[ -f $F ] || F=$(find src -path '*nsc/symtab/classfile/ClassfileParser.scala' | head -1)
python3 - $F <<'PY'
import re,sys; p=sys.argv[1]; s=open(p).read()
# new constant pool tags (Java 7+)
s2=re.sub(r"(\n(\s*)case _ =>\s*\n\s*errorBadTag\(in\.bp - 1\))",
          r"\n\2case 15 => in.skip(3);\n\2case 16 | 19 | 20 => in.skip(2);\n\2case 17 | 18 => in.skip(4);\1", s, count=1)
if s2==s: print("nsc patch: constant pool tags not applied", file=sys.stderr)
s=s2
# always continue after the attribute, whatever its parser consumed
s2=re.sub(r"(val attrLen = in\.nextInt\(\);?\n)(\s*)(attrName match \{)",
          r"\1\2val attrEnd = in.bp + attrLen;\n\2try { \3", s, count=1)
if s2==s: print("nsc patch: attribute resync not applied", file=sys.stderr)
else:
    i=s2.index("try { attrName match {")
    # find the end of the match block by brace counting
    j=s2.index("{", i+len("try { attrName match "))
    d=0;k=j
    while True:
        if s2[k]=="{": d+=1
        elif s2[k]=="}":
            d-=1
            if d==0: break
        k+=1
    s2=s2[:k+1]+" } finally { in.bp = attrEnd }"+s2[k+1:]
s=s2
open(p,"w").write(s)
PY
# r18344 (#1373, 2009-07-18, reverted 2009-08-21 "as it is interacting badly with..."):
# the compiler it gives crashes in the pattern matcher on scala/concurrent/pilib.scala
F=$(find src -path '*nsc/symtab/Symbols.scala' | head -1)
if [ -n "$F" ]; then python3 - $F <<'PY'
import re,sys; p=sys.argv[1]; s=open(p).read()
s2=re.sub(r"final def caseFieldAccessors: List\[Symbol\] = \{.*?constrParamAccessors map findRightAccessor flatten\s*\}",
          "final def caseFieldAccessors: List[Symbol] =\n      info.decls.toList filter (sym => !(sym hasFlag PRIVATE) && sym.hasFlag(CASEACCESSOR))",
          s, count=1, flags=re.S)
if s2!=s: print("nsc patch: r18344 reverted", file=sys.stderr); open(p,"w").write(s2)
PY
fi
