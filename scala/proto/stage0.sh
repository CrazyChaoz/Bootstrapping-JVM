#!/usr/bin/env bash
# stage 0: the Java/Pizza scalac of 2003-11-12 (f8ed082d80)
set -euo pipefail
T=/home/kemp/ins/development/bootstrapping-gradle/tools
J=${J:-/nix/store/nkd7mzlsa4d113n0xwh98m4l6dx9bnax-openjdk-headless-21.0.12.1+1}
S=/tmp/sc
W=$S/st0; rm -rf $W; mkdir -p $W; cd $W
cp -r $S/old/sources src; chmod -R u+w src
cp -r $S/fjbg/src/fjbg fjbg
# --- patches
sed -i 's/public static class OffsetTooBigException extends Exception/public static class OffsetTooBigException extends RuntimeException/' fjbg/ch/epfl/lamp/fjbg/JCode.java
sed -i 's/scalac\.backend\.msil\.GenMSILPhase\.class/scalac.backend.jvm.GenJVMPhase.class/' src/scalac/CompilerPhases.java
python3 - src/scalac/symtab/classfile/ConstantPool.java <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
a="""                case CONSTANT_LONG:
                case CONSTANT_DOUBLE:
                    in.skip(8);
                    i++;
                    break;
                default:"""
b="""                case CONSTANT_LONG:
                case CONSTANT_DOUBLE:
                    in.skip(8);
                    i++;
                    break;
                case 15: in.skip(3); break;           // MethodHandle
                case 16: case 19: case 20: in.skip(2); break; // MethodType, Module, Package
                case 17: case 18: in.skip(4); break;  // (Invoke)Dynamic
                default:"""
assert a in s; open(p,'w').write(s.replace(a,b))
PY
python3 - src/scalac/symtab/classfile/ClassfileParser.java <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
a="""    protected void parseMethod() {
        int flags = in.nextChar();
        Name name = (Name)pool.readPool(in.nextChar());
        Type type = readType(in.nextChar());"""
b="""    protected void parseMethod() {
        int flags = in.nextChar();
        Name name = (Name)pool.readPool(in.nextChar());
        if ((flags & 0x1040) != 0) { // bridge or synthetic (Java 5+)
            in.nextChar();
            for (int n = in.nextChar(); n > 0; n--) { in.nextChar(); in.skip(in.nextInt()); }
            return;
        }
        Type type = readType(in.nextChar());"""
assert a in s; open(p,'w').write(s.replace(a,b))
PY
for c in Int Long Float; do
  sed -i -E 's/public (int|long|float) \$(plus|minus|tilde)\(\) \{/public \1 $\2$$pizza'$c'() {/' src/scala/$c.java
done
# --- meta: generate Tree.java etc.
mkdir -p meta-cls
python3 -I $T/pizza2java.py src meta-java $(cd src && find meta -name '*.java')
$J/bin/javac -nowarn -encoding latin1 --release 8 -d meta-cls $(find meta-java -name '*.java') 2>&1 | grep -v '^Note' || true
$J/bin/java -cp meta-cls meta.GenerateAll src generated.lst > /dev/null
# --- translate
L=$S/old/config/list
{ grep -v '^#' $L/compiler.lst | grep . | sed 's|^|scalac/|'
  grep -v '^#' $L/lamplib.lst | grep . | sed 's|^|ch/epfl/lamp/|'
  grep -v '^#' $L/library.lst | grep '\.java' | sed 's|^|scala/|'; } | grep -v msil > jfiles.txt
python3 -I $T/pizza2java.py src java --classpath-src fjbg --meta-out meta.json $(cat jfiles.txt)
mkdir -p classes
$J/bin/javac -nowarn -encoding latin1 --release 8 -d classes $(find fjbg java -name '*.java') 2>&1 | grep -v '^Note' || true
python3 -I $T/pico-classfiles.py classes meta.json
echo stage0 done
