# gradle-kotlin-dsl-extensions.jar: the Kotlin DSL extensions generated for the Gradle API of a
# distribution (build-logic's GenerateKotlinExtensionsForGradleApi + compileGradleApiKotlinExtensions).
{
  lib,
  stdenv,
  jdk,
  zip,
  stripJavaArchivesHook,
  writeShellScript,
  gradleDistBase,
  gradleModules,
  gradleLibs,
  classpathOf,
  kotlinCompiler,
  kotlinAsm,
  version ? "9.8.0",
}:

let
  kotlinRun = writeShellScript "kotlinc" ''
    k=${kotlinCompiler}/lib
    exec ${jdk}/bin/java -Xmx4g \
      --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED \
      --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED \
      --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.desktop/java.awt.font=ALL-UNNAMED \
      -cp ${kotlinAsm}/share/java/kotlin-asm.jar:$k/kotlin-compiler.jar:$k/kotlin-stdlib.jar:$k/kotlin-reflect.jar:$k/kotlin-script-runtime.jar \
      org.jetbrains.kotlin.cli.jvm.K2JVMCompiler "$@"
  '';
  includes = "org/gradle/* org/gradle/api/** org/gradle/authentication/** org/gradle/build/** org/gradle/buildconfiguration/** org/gradle/buildinit/** org/gradle/caching/** org/gradle/concurrent/** org/gradle/deployment/** org/gradle/external/javadoc/** org/gradle/ide/** org/gradle/ivy/** org/gradle/jvm/** org/gradle/language/** org/gradle/maven/** org/gradle/nativeplatform/** org/gradle/normalization/** org/gradle/platform/** org/gradle/plugin/devel/** org/gradle/plugin/use/* org/gradle/plugin/management/* org/gradle/plugins/** org/gradle/process/** org/gradle/swiftpm/** org/gradle/model/** org/gradle/testkit/** org/gradle/testing/** org/gradle/vcs/** org/gradle/work/** org/gradle/workers/** org/gradle/util/**";
  excludes = "org/gradle/tooling org/gradle/tooling/** org/gradle/testfixtures org/gradle/testfixtures/** org/gradle/plugins/ide/eclipse/model org/gradle/plugins/ide/idea/model org/gradle/api/tasks/testing/logging org/gradle/plugins/binaries/model";
in
stdenv.mkDerivation {
  pname = "gradle-kotlin-dsl-extensions";
  inherit version;
  dontUnpack = true;
  nativeBuildInputs = [
    jdk
    zip
    stripJavaArchivesHook
  ];
  buildPhase = ''
    d=${gradleDistBase}
    ls $d/lib/*.jar $d/lib/plugins/*.jar > all-jars
    grep '/gradle-' all-jars | grep -v '/gradle-kotlin-' > api-jars
    grep -vxFf api-jars all-jars > dep-jars
    : > runtime
    for j in ${gradleModules.kotlin-dsl-shared-runtime} ${gradleLibs.asm-tree} ${gradleLibs.asm} ${gradleLibs.jsr305} ${gradleLibs.jspecify}; do
      ls $j/share/java/*.jar >> runtime
    done
    echo ${kotlinCompiler}/lib/kotlin-stdlib.jar >> runtime

    mkdir -p cls gen
    cp ${./GenerateExtensions.java} GenerateExtensions.java
    javac -nowarn -d cls GenerateExtensions.java
    java -cp cls GenerateExtensions gen runtime api-jars dep-jars \
      '${lib.concatStringsSep "," (lib.splitString " " includes)}' '${lib.concatStringsSep "," (lib.splitString " " excludes)}'
    find gen -name '*.kt' | sort > sources
    echo "generated $(wc -l < sources) files"

    mkdir classes
    ${kotlinRun} -no-stdlib -no-reflect -nowarn -language-version 2.2 -api-version 2.2 -jvm-target 1.8 \
      -Xskip-prerelease-check -Xjsr305=strict -Xsam-conversions=class -Xjvm-default=all-compatibility \
      -opt-in=kotlin.contracts.ExperimentalContracts \
      -module-name gradle-kotlin-dsl-extensions \
      -cp "$(tr '\n' ':' < all-jars)${kotlinCompiler}/lib/kotlin-stdlib.jar" -d classes @sources
  '';
  installPhase = ''
    mkdir -p $out/share/java
    cp -r gen/. classes/
    jar cf $out/share/java/gradle-kotlin-dsl-extensions.jar -C classes .
  '';
}
