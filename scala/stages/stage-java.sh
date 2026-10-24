#!/usr/bin/env bash
# build the Java (Pizza) boot compiler of a Scala 1.x source tree, then use it
# to compile the library and the Scala-written compiler parts.
# usage: stage-java.sh SRCTREE WORKDIR
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/env.sh"
TREE=$1; W=$2
rm -rf $W; mkdir -p $W; cd $W
cp -r $TREE/sources src; chmod -R u+w src
cp -r $FJBG_SRC fjbg
L=$TREE/config/list
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
                    throw new RuntimeException("bad constant pool tag: \"""")]
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
[ -f $W/../extra-patches.sh ] && . $W/../extra-patches.sh
# --- meta: generate Tree.java etc.
mkdir -p meta-cls
python3 -I $T/pizza2java.py src meta-java $(cd src && find meta -name '*.java')
$J/bin/javac -nowarn -encoding latin1 --release 8 -d meta-cls $(find meta-java -name '*.java') 2>&1 | grep -v '^Note' || true
$J/bin/java -cp meta-cls meta.GenerateAll src generated.lst > /dev/null
# --- translate + javac
{ grep -v '^#' $L/compiler.lst | grep . | sed 's|^|scalac/|'
  grep -v '^#' $L/lamplib.lst | grep . | sed 's|^|ch/epfl/lamp/|'
  grep -v '^#' $L/library.lst | grep '\.java' | sed 's|^|scala/|'; } | sed 's/\s*$//' | grep -v -i 'msil\|CLR' > jfiles.txt
python3 -I $T/pizza2java.py src java --classpath-src fjbg --meta-out meta.json $(cat jfiles.txt)
mkdir -p classes stubs
if [ -f src/scalac/symtab/classfile/CLRPackageParser.java ]; then
  mkdir -p stubs/scalac/symtab/classfile
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
fi
$J/bin/javac -nowarn -encoding latin1 --release 8 -d classes $(find fjbg java stubs -name '*.java') 2>&1 | grep -v '^Note' || true
python3 -I $T/pico-classfiles.py classes meta.json
# --- library (Scala part) with the boot compiler
grep -v '^#' $L/library.lst | sed 's/\s*$//' | grep '\.scala$' | sed 's|^|src/scala/|' > sfiles.txt
mkdir -p lib
$J8/bin/java -Xss32m -cp classes scalac.Main -d lib -classpath lib:classes:src $(cat sfiles.txt)
# --- Scala-written compiler parts
if [ -f $L/scalac.lst ]; then
  grep -v '^#' $L/scalac.lst | sed 's/\s*$//' | grep . | sed 's|^|src/scala/tools/scalac/|' > scfiles.txt
  mkdir -p scalac
  $J8/bin/java -Xss32m -cp classes scalac.Main -d scalac -classpath scalac:lib:classes:src $(cat scfiles.txt)
fi
echo stage done
