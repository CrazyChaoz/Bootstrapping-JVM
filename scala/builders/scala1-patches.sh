# Source patches of the Scala 1.x trees (sourced by scala1.sh in the work directory, with
# the compiler in src/ and FJBG + MSIL in fjbg/).  The trees span 2004-2005, so every
# patch is tolerant: a pattern a tree does not have is reported and skipped.

# (FJBG of 2009 against the compiler of 2004)
sed -i 's/public static class OffsetTooBigException extends Exception/public static class OffsetTooBigException extends RuntimeException/' fjbg/ch/epfl/lamp/fjbg/JCode.java
# (the MSIL backend is not built)
sed -i 's/scalac\.backend\.msil\.GenMSILPhase\.class/scalac.backend.jvm.GenJVMPhase.class/' src/scalac/CompilerPhases.java

# The class file reader against JDK 8's class library: the constant pool tags of Java 7+ ...
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
# ... the bridge and synthetic methods of Java 5+, skipped ...
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
# (or, where the reader knows bridges (2005), made private)
pyreplace src/scalac/symtab/classfile/ClassfileParser.java <<'PY'
R=[("if ((jflags & JAVA_ACC_BRIDGE) != 0) sflags |= Modifiers.BRIDGE;",
    "if ((jflags & JAVA_ACC_BRIDGE) != 0) sflags |= Modifiers.BRIDGE | Modifiers.PRIVATE; // skip Java 5 bridges")]
PY
# ... and attributes it reads only partly (the generic signatures of Java 5) skipped as a whole
pyreplace src/scalac/symtab/classfile/AttributeParser.java <<'PY'
R=[("""                readAttribute(def, type, attr, attrLen);""",
    """                { int start$ = in.bp; readAttribute(def, type, attr, attrLen); in.bp = start$ + attrLen; }""")]
PY

# (unary operators of the primitive classes: Pizza overloads them by result type, Java cannot)
for c in Int Long Float; do
  sed -i -E 's/public (int|long|float) \$(plus|minus|tilde)\(\) \{/public \1 $\2$$pizza'$c'() {/' src/scala/$c.java
done

# (the MSIL reader of 2009 turned these Type fields into methods)
for f in src/scalac/symtab/classfile/CLRClassParser.java src/scalac/symtab/classfile/CLRPackageParser.java src/scalac/symtab/classfile/CLRTypes.java; do
  [ -f "$f" ] || continue
  python3 - "$f" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding="latin-1").read()
s = re.sub(r"\.(BaseType|Assembly)\b(?!\s*\()", r".\1()", s)
open(p, "w", encoding="latin-1").write(s)
PY
done

# The MSIL backend, a stub that refuses to run (the compiler is JVM-only)
if [ -f src/scalac/backend/msil/GenMSIL.java ]; then
  mkdir -p stubs/scalac/backend/msil
  cat > stubs/scalac/backend/msil/GenMSIL.java <<'JAVA'
package scalac.backend.msil;
/** stub: the MSIL backend is not bootstrapped */
public class GenMSIL {
    public static void translate(Object global, Object units) {
        throw new Error("MSIL support is not available");
    }
}
JAVA
fi
