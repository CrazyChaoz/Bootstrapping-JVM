pyreplace() { # file  -- reads python dict of a->b pairs on stdin: tolerant
  python3 -c '
import sys; p=sys.argv[1]; s=open(p).read(); exec(sys.stdin.read())
for a,b in R:
    if a in s: s=s.replace(a,b)
    else: print("patch not applicable in",p,":",a.splitlines()[0][:60],file=sys.stderr)
open(p,"w").write(s)' "$1"
}
# --- patches
sed -i 's/public static class OffsetTooBigException extends Exception/public static class OffsetTooBigException extends RuntimeException/' fjbg/ch/epfl/lamp/fjbg/JCode.java
sed -i 's/scalac\.backend\.msil\.GenMSILPhase\.class/scalac.backend.jvm.GenJVMPhase.class/' src/scalac/CompilerPhases.java
pyreplace src/scalac/symtab/classfile/ConstantPool.java <<'PY'
R=[("""                default:
                    throw new RuntimeException("bad constant pool tag: \"""",
"""                case 15: in.skip(3); break;
                case 16: case 19: case 20: in.skip(2); break;
                case 17: case 18: in.skip(4); break;
                default:
                    throw new RuntimeException("bad constant pool tag: \""""),
("""            default:
                throw errorBadTag(in.bp - 1);""",
"""            case 15: in.skip(3); break;
            case 16: case 19: case 20: in.skip(2); break;
            case 17: case 18: in.skip(4); break;
            default:
                throw errorBadTag(in.bp - 1);""")]
PY
pyreplace src/scalac/symtab/classfile/ClassfileParser.java <<'PY'
R=[("""    protected void parseMethod() {
        int flags = in.nextChar();
        Name name = (Name)pool.readPool(in.nextChar());""",
"""    protected void parseMethod() {
        int flags = in.nextChar();
        Name name = (Name)pool.readPool(in.nextChar());
        if ((flags & 0x0040) != 0 || ((flags & 0x1000) != 0 && !name.toString().equals("<init>"))) { // bridge or synthetic (Java 5+)
            in.nextChar();
            for (int n = in.nextChar(); n > 0; n--) { in.nextChar(); in.skip(in.nextInt()); }
            return;
        }""")]
PY
for c in Int Long Float; do
  sed -i -E 's/public (int|long|float) \$(plus|minus|tilde)\(\) \{/public \1 $\2$$pizza'$c'() {/' src/scala/$c.java
done
pyreplace src/scalac/symtab/classfile/ClassfileParser.java <<'PY'
R=[("if ((jflags & JAVA_ACC_BRIDGE) != 0) sflags |= Modifiers.BRIDGE;",
    "if ((jflags & JAVA_ACC_BRIDGE) != 0) sflags |= Modifiers.BRIDGE | Modifiers.PRIVATE; // skip Java 5 bridges")]
PY
pyreplace src/scalac/symtab/classfile/AttributeParser.java <<'PY'
R=[("""                readAttribute(def, type, attr, attrLen);""",
    """                { int start$ = in.bp; readAttribute(def, type, attr, attrLen); in.bp = start$ + attrLen; }""")]
PY
for f in src/scalac/symtab/classfile/CLRClassParser.java src/scalac/symtab/classfile/CLRPackageParser.java src/scalac/symtab/classfile/CLRTypes.java; do
  [ -f $f ] && python3 - $f <<'PY'
import re,sys; p=sys.argv[1]; s=open(p).read()
# the 2009 msil library turned these Type fields into methods
s=re.sub(r"\.(BaseType|Assembly)\b(?!\s*\()", r".\1()", s)
open(p,"w").write(s)
PY
done
true
