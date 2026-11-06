#!/usr/bin/env bash
# The JVM runtime jars of a Kotlin 2.3.x or 2.4.x release as its Gradle build makes them, by kotlinc and javac
# run directly (README.md):
#   kotlin-stdlib          libraries/stdlib/build.gradle.kts (jvm compilations main, mainJdk7, mainJdk8; java9)
#   kotlin-stdlib-jdk7/8   libraries/stdlib/jdk7, jdk8 (module descriptors only)
#   kotlin-script-runtime  libraries/tools/script-runtime
#   kotlin-test            libraries/kotlin.test (jvmJar)
# Env: SRC (the release's tree), KOTLIN (the compiler), JDK8, JDK11, JDK17, ANN (org.jetbrains:annotations
# without type-use targets, like 13.0), JARPY (gradle-jar.py), VERSION, BUILD (the release's build number),
# WORK, OUT (the jars' directory).
set -euo pipefail
S=$SRC/libraries/stdlib
B=$WORK
mkdir -p $B $OUT
IMPL=$VERSION-release-$BUILD
LINE=${VERSION%.*}

# what changed between the release lines' build scripts
case $LINE in
2.3)
  # mainCompilationOptions: languageVersion, apiVersion 2.3; the return value checker in main only
  stdlibLV="-language-version 2.3 -api-version 2.3"
  redundant=""
  mainOnly="-Xcompile-builtins-as-part-of-stdlib -Xreturn-value-checker=full"
  rvc=""
  # the multiplatform plugin's default module name
  testModule=kotlin-test
  ;;
2.4)
  stdlibLV=""
  redundant="-Xwarning-level=REDUNDANT_CLI_ARG:disabled"
  mainOnly=""
  rvc="-Xreturn-value-checker=full"
  testModule=org.jetbrains.kotlin:kotlin-test
  ;;
*)
  echo "unknown release line $LINE"
  exit 1
  ;;
esac

# kotlinc as the Gradle plugin runs it: on the toolchain JDK (11), against its class library
kc() {
  $JDK11/bin/java -Xmx6g \
    -cp $KOTLIN/lib/kotlin-compiler.jar:$KOTLIN/lib/kotlin-stdlib.jar:$KOTLIN/lib/kotlin-reflect.jar:$KOTLIN/lib/kotlin-script-runtime.jar \
    org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -jdk-home $JDK11/lib/openjdk "$@"
}
# javac as Gradle's JavaCompile runs it (-g, -proc:none without processors, no source path)
jc() { "$@" -encoding UTF-8 -g -proc:none -XDuseUnsharedTable=true -nowarn; }
# configureJava9Compilation: module-info.java by JDK 17's javac for release 9
java9() {
  local dir=$1 name=$2 mp=$3 patch=$4
  mkdir -p $B/$name-v9/META-INF/versions/9
  jc $JDK17/bin/javac --release 9 -sourcepath $dir -d $B/$name-v9/META-INF/versions/9 --module-path $mp \
    ${patch:+--patch-module $patch} $dir/module-info.java
}
# LibrariesCommon.manifestAttributes
jar() {
  local name=$1 component=$2
  shift 2
  python3 $JARPY $OUT/$name.jar --attr 'Implementation-Vendor: JetBrains' --attr "Implementation-Title: $name" \
    --attr "Implementation-Version: $IMPL" --attr "Kotlin-Runtime-Component: $component" \
    --attr "Kotlin-Version: $LINE" "$@"
}
# the .kt (or EXT) files of source directories, as relative paths in the tree, sorted
srcs() { (cd $SRC && for d in "$@"; do find $d -name "${EXT:-*.kt}" | LC_ALL=C sort; done); }
cd $SRC

echo "## kotlin-stdlib"
mkdir -p $B/co $B/main $B/mainjava $B/jdk7 $B/jdk8
python3 $SCRIPTS/kotlin-version.py $S/src/kotlin/util/KotlinVersion.kt $VERSION $B/KotlinVersion.kt
common=$(srcs libraries/stdlib/{common/src,src,unsigned/src} | sed "s|^libraries/stdlib/src/kotlin/util/KotlinVersion.kt$|$B/KotlinVersion.kt|")
jvm=$(srcs libraries/stdlib/jvm/{src,runtime,builtins} | grep -v '^libraries/stdlib/jvm/[a-z]*/kotlin/internal/InternalAnnotations.kt$')
jvmJava=$(EXT='*.java' srcs libraries/stdlib/jvm/{src,runtime,builtins})
main="$stdlibLV -Xstdlib-compilation -Xdont-warn-on-error-suppression -Xcontext-parameters -Werror
  $redundant $rvc -opt-in=kotlin.ExperimentalMultiplatform -opt-in=kotlin.contracts.ExperimentalContracts"
# compileOnlyDeclarations
kc -no-stdlib -no-reflect -module-name kotlin-stdlib_compileOnlyDeclarations -jvm-target 1.8 \
  -Xallow-kotlin-package -Xsuppress-missing-builtins-error $redundant \
  -d $B/co $(srcs libraries/stdlib/jvm/compileOnly)
# main: the commonMain and jvmMain fragments (and jvmMain's Java sources, for reference)
fragments=$( { echo "$common" | sed 's|^|commonMain:|'; echo "$jvm" | sed 's|^|jvmMain:|'; } | paste -sd,)
kc -no-stdlib -no-reflect -module-name kotlin-stdlib -jvm-target 1.8 -Xmulti-platform \
  -Xfragments=commonMain,jvmMain -Xfragment-refines=jvmMain:commonMain -Xfragment-sources="$fragments" \
  -Xjdk-release=6 -jvm-default=disable -Xallow-kotlin-package -Xexpect-actual-classes -Xmultifile-parts-inherit \
  -Xuse-14-inline-classes-mangling-scheme -Xno-new-java-annotation-targets -Xoutput-builtins-metadata \
  $main $mainOnly -Xexplicit-api=strict -cp $B/co:$ANN -d $B/main $common $jvm $jvmJava
jc $JDK8/bin/javac -source 1.8 -target 1.8 -sourcepath "" -cp $B/main:$B/co:$ANN -d $B/mainjava $jvmJava
kc -no-stdlib -no-reflect -module-name kotlin-stdlib-jdk7 -jvm-target 1.8 -Xjdk-release=7 -jvm-default=disable \
  -Xallow-kotlin-package -Xexpect-actual-classes -Xmultifile-parts-inherit -Xno-new-java-annotation-targets \
  -Xexplicit-api=strict $main -Xfriend-paths=$B/main,$B/mainjava -cp $B/main:$B/mainjava:$ANN \
  -d $B/jdk7 $(srcs libraries/stdlib/jdk7/src)
kc -no-stdlib -no-reflect -module-name kotlin-stdlib-jdk8 -jvm-target 1.8 -jvm-default=disable \
  -Xallow-kotlin-package -Xmultifile-parts-inherit -Xno-new-java-annotation-targets -Xexplicit-api=strict \
  $main -Xfriend-paths=$B/main,$B/mainjava,$B/jdk7 -cp $B/main:$B/mainjava:$B/jdk7:$ANN \
  -d $B/jdk8 $(srcs libraries/stdlib/jdk8/src)
java9 $S/jvm/java9 kotlin-stdlib $ANN kotlin.stdlib=$B/main:$B/mainjava:$B/jdk7:$B/jdk8
# jvmJar: main's outputs (Kotlin classes, Java classes), mainJdk7's, mainJdk8's, java9's
jar kotlin-stdlib Main --attr 'Multi-Release: true' \
  --root $B/main --root $B/mainjava --root $B/jdk7 --root $B/jdk8 --root $B/kotlin-stdlib-v9
STDLIB=$OUT/kotlin-stdlib.jar

echo "## kotlin-stdlib-jdk7, kotlin-stdlib-jdk8"
java9 $S/jdk7/java9 kotlin-stdlib-jdk7 $STDLIB ""
jar kotlin-stdlib-jdk7 Main --attr 'Multi-Release: true' --root $B/kotlin-stdlib-jdk7-v9
java9 $S/jdk8/java9 kotlin-stdlib-jdk8 $STDLIB:$OUT/kotlin-stdlib-jdk7.jar ""
jar kotlin-stdlib-jdk8 Main --attr 'Multi-Release: true' --root $B/kotlin-stdlib-jdk8-v9

echo "## kotlin-script-runtime"
mkdir -p $B/script-runtime
kc -no-stdlib -no-reflect -module-name kotlin-script-runtime -jvm-target 1.8 -Xallow-kotlin-package \
  -cp $STDLIB -d $B/script-runtime $(srcs core/script.runtime/src)
jar kotlin-script-runtime Main --root $B/script-runtime

echo "## kotlin-test"
T=libraries/kotlin.test
mkdir -p $B/test
assertions=$(srcs $T/common/src/main/kotlin)
testJvm=$(srcs $T/jvm/src/main/kotlin)
fragments=$( { echo "$assertions" | sed 's|^|assertionsCommonMain:|'; echo "$testJvm" | sed 's|^|jvmMain:|'; } | paste -sd,)
kc -no-stdlib -no-reflect -module-name $testModule -jvm-target 1.8 -Xmulti-platform \
  -Xfragments=commonMain,assertionsCommonMain,jvmMain \
  -Xfragment-refines=assertionsCommonMain:commonMain,jvmMain:assertionsCommonMain -Xfragment-sources="$fragments" \
  -language-version $LINE -api-version $LINE -Xdont-warn-on-error-suppression -Xreturn-value-checker=full \
  -opt-in=kotlin.contracts.ExperimentalContracts -Xallow-kotlin-package -Xexpect-actual-classes \
  -Xexplicit-api=strict -Werror -cp $STDLIB -d $B/test $assertions $testJvm
java9 $SRC/$T/jvm/src/java9/java kotlin-test $STDLIB kotlin.test=$B/test
jar kotlin-test Test --attr 'Multi-Release: true' --root $B/test --root $B/kotlin-test-v9
