#!/usr/bin/env bash
# pizza.sh TREE OUT : the first stage.  TREE is scala/scala of 2004-02-19 (3b4e70e1bd), the
# last commit with a complete boot compiler written in Java ("scalacboot", Pizza: Java with
# algebraic data types).  tools/pizza2java.py translates it to plain Java and javac compiles
# it; it compiles the library and the compiler parts written in Scala (lib/, scalac/), which
# then compile themselves again (lib2/, sc2/: what the next stage runs).
#
# Inputs (besides those of common.sh): FJBG_SRC, the sources of FJBG, the class file
# library of the JVM backend (not in the tree at the time; src/fjbg of 2009).
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"
require FJBG_SRC
TREE=$1 W=$2
rm -rf "$W"; mkdir -p "$W"; cd "$W"
cp -r "$TREE/sources" src
cp -r "$FJBG_SRC" fjbg
L=$TREE/config/list

# --- patches
# (FJBG of 2009 against the compiler of 2004)
sed -i 's/public static class OffsetTooBigException extends Exception/public static class OffsetTooBigException extends RuntimeException/' fjbg/ch/epfl/lamp/fjbg/JCode.java
# (the MSIL backend is not built)
sed -i 's/scalac\.backend\.msil\.GenMSILPhase\.class/scalac.backend.jvm.GenJVMPhase.class/' src/scalac/CompilerPhases.java
# the class file reader against JDK 8's class library: the constant pool tags of Java 7+ ...
pyreplace src/scalac/symtab/classfile/ConstantPool.java <<'PY'
R=[("""                default:
                    throw new RuntimeException("bad constant pool tag: \"""",
"""                case 15: in.skip(3); break;
                case 16: case 19: case 20: in.skip(2); break;
                case 17: case 18: in.skip(4); break;
                default:
                    throw new RuntimeException("bad constant pool tag: \"""")]
PY
# ... and the bridge and synthetic methods of Java 5+, skipped
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
# (unary operators of the primitive classes: Pizza overloads them by result type, Java cannot)
for c in Int Long Float; do
  sed -i -E 's/public (int|long|float) \$(plus|minus|tilde)\(\) \{/public \1 $\2$$pizza'$c'() {/' src/scala/$c.java
done

# --- the meta programs generate Tree.java and friends
mkdir -p meta-cls
python3 -I "$T/pizza2java.py" src meta-java $(cd src && find meta -name '*.java' | sort)
javac8 -encoding latin1 -d meta-cls $(find meta-java -name '*.java' | sort)
"$JDK21/bin/java" -cp meta-cls meta.GenerateAll src generated.lst > /dev/null

# --- the boot compiler: Pizza -> Java -> javac (without the MSIL backend)
{ grep -v '^#' "$L/compiler.lst" | grep . | sed 's|^|scalac/|'
  grep -v '^#' "$L/lamplib.lst" | grep . | sed 's|^|ch/epfl/lamp/|'
  grep -v '^#' "$L/library.lst" | grep '\.java' | sed 's|^|scala/|'
} | sed 's/\s*$//' | grep -v -i 'msil\|CLR' > jfiles.txt
python3 -I "$T/pizza2java.py" src java --classpath-src fjbg --meta-out meta.json $(cat jfiles.txt)
mkdir -p classes stubs/scalac/symtab/classfile
cat > stubs/scalac/symtab/classfile/CLRPackageParser.java <<'JAVA'
package scalac.symtab.classfile;
/** stub: the MSIL backend is not bootstrapped */
public class CLRPackageParser {
    public static CLRPackageParser create(scalac.Global global) { return null; }
    public void importCLRTypes(Object p, Object members, Object parser) {
        throw new Error("MSIL support is not available");
    }
}
JAVA
javac8 -encoding latin1 -d classes $(find fjbg java stubs -name '*.java' | sort)
# (what the Pizza compiler would have written: Scala attributes, flags; see the tool)
python3 -I "$T/pico-classfiles.py" classes meta.json

scalac() { "$JDK8/bin/java" -Xss32m -cp "$1" scala.tools.scalac.Main "${@:2}"; }
# --- the library's Scala sources, by the boot compiler
grep -v '^#' "$L/library.lst" | sed 's/\s*$//' | grep '\.scala$' | sed 's|^|src/scala/|' > sfiles.txt
mkdir -p lib
"$JDK8/bin/java" -Xss32m -cp classes scalac.Main -d lib -classpath lib:classes:src $(cat sfiles.txt)
# --- the compiler parts written in Scala
grep -v '^#' "$L/scalac.lst" | sed 's/\s*$//' | grep . | sed 's|^|src/scala/tools/scalac/|' > scfiles.txt
mkdir -p scalac
"$JDK8/bin/java" -Xss32m -cp classes scalac.Main -d scalac -classpath scalac:lib:classes:src $(cat scfiles.txt)

# --- both again, by themselves
mkdir -p lib2 sc2
scalac scalac:lib:classes -d lib2 -classpath lib2:classes:src $(cat sfiles.txt)
scalac scalac:lib:classes -d sc2 -classpath sc2:lib2:classes:src $(cat scfiles.txt)
echo "stage done"
