# Kotlin compiler plugins (from the Kotlin 2.4.0 sources) used to compile Gradle's
# own Kotlin modules.  Built against the unshaded kotlin-compiler.jar.
{
  lib,
  stdenv,
  fetchzip,
  jdk,
  zip,
  stripJavaArchivesHook,
  kotlinSrc,
  kotlinCompiler,
  jetbrainsAnnotations,
  writeShellScript,
}:

let
  kotlinRun = writeShellScript "kotlinc" ''
    k=${kotlinCompiler}/lib
    exec ${jdk}/bin/java -Xmx4g \
      --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED \
      --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED \
      --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.desktop/java.awt.font=ALL-UNNAMED \
      -cp $k/kotlin-compiler.jar:$k/kotlin-stdlib.jar:$k/kotlin-reflect.jar:$k/kotlin-script-runtime.jar \
      org.jetbrains.kotlin.cli.jvm.K2JVMCompiler "$@"
  '';
  mkPlugin =
    {
      name,
      dirs, # source directories, relative to the Kotlin source root
      resourceDirs,
      extraArgs ? [ ],
    }:
    stdenv.mkDerivation {
      pname = name;
      version = "2.4.0";
      src = kotlinSrc;
      nativeBuildInputs = [
        jdk
        zip
        stripJavaArchivesHook
      ];
      dontConfigure = true;
      buildPhase = ''
        mkdir -p build/classes
        find ${lib.escapeShellArgs dirs} -name '*.kt' -o -name '*.java' > build/sources
        ${kotlinRun} -no-stdlib -no-reflect -nowarn -Xskip-prerelease-check -jvm-target 17 -Xjvm-default=all \
          -opt-in=org.jetbrains.kotlin.compiler.plugin.ExperimentalCompilerApi \
          -opt-in=org.jetbrains.kotlin.fir.symbols.SymbolInternals \
          -opt-in=org.jetbrains.kotlin.fir.FirImplementationDetail \
          -opt-in=org.jetbrains.kotlin.ir.symbols.UnsafeDuringIrConstructionAPI \
          ${lib.escapeShellArgs extraArgs} \
          -module-name ${name} \
          -cp "${kotlinCompiler}/lib/kotlin-compiler.jar:${kotlinCompiler}/lib/kotlin-stdlib.jar" \
          -d build/classes @build/sources
        for d in ${lib.escapeShellArgs resourceDirs}; do cp -r $d/. build/classes/; done
      '';
      installPhase = ''
        mkdir -p $out/share/java
        jar cf $out/share/java/${name}.jar -C build/classes .
      '';
    };
  kxSrc = fetchzip {
    url = "https://github.com/Kotlin/kotlinx.serialization/archive/refs/tags/v1.11.0.tar.gz";
    hash = "sha256-mDlxNHJCVCpjG42EDaHVpDEA9qiB4gSv+3HkBeqVYno=";
  };

  # multiplatform sources (common + jvm) compiled together for the JVM
  mkKx =
    {
      name,
      dirs,
      commonDir,
      resourceDirs ? [ ],
      deps ? [ ],
    }:
    stdenv.mkDerivation {
      pname = name;
      version = "1.11.0";
      src = kxSrc;
      nativeBuildInputs = [
        jdk
        zip
        stripJavaArchivesHook
      ];
      dontConfigure = true;
      buildPhase = ''
        mkdir -p build/classes
        find ${lib.escapeShellArgs dirs} \( -name '*.kt' -o -name '*.java' \) > build/sources
        find ${commonDir} -name '*.kt' | paste -sd, > build/common
        ${kotlinRun} -no-stdlib -no-reflect -nowarn -Xskip-prerelease-check -jvm-target 1.8 -Xcommon-sources=$(cat build/common) -Xjvm-default=all \
          -Xreturn-value-checker=check -opt-in=kotlinx.serialization.SealedSerializationApi -opt-in=kotlinx.serialization.json.internal.JsonFriendModuleApi -opt-in=kotlinx.serialization.internal.CoreFriendModuleApi \
          -Xmulti-platform -Xexpect-actual-classes -Xno-check-actual \
          -opt-in=kotlin.RequiresOptIn -opt-in=kotlinx.serialization.InternalSerializationApi \
          -opt-in=kotlinx.serialization.ExperimentalSerializationApi -opt-in=kotlin.ExperimentalUnsignedTypes \
          -opt-in=kotlin.contracts.ExperimentalContracts -opt-in=kotlin.ExperimentalStdlibApi \
          -Xplugin=${self.serialization}/share/java/kotlinx-serialization-compiler-plugin.jar \
          -module-name ${name} \
          -cp "${kotlinCompiler}/lib/kotlin-stdlib.jar${lib.concatMapStrings (d: ":${d}/share/java/${d.pname}.jar") deps}:$(echo ${jetbrainsAnnotations}/share/java/*.jar)" \
          -d build/classes @build/sources
        for d in ${lib.escapeShellArgs resourceDirs}; do [ -d $d ] && cp -r $d/. build/classes/; done
      '';
      installPhase = ''
        mkdir -p $out/share/java
        jar cf $out/share/java/${name}.jar -C build/classes .
      '';
    };

  self = {
  samWithReceiver = mkPlugin {
    name = "kotlin-sam-with-receiver-compiler-plugin";
    dirs = [
      "plugins/sam-with-receiver/sam-with-receiver.common/src"
      "plugins/sam-with-receiver/sam-with-receiver.k1/src"
      "plugins/sam-with-receiver/sam-with-receiver.k2/src"
      "plugins/sam-with-receiver/sam-with-receiver.cli/src"
    ];
    resourceDirs = [ "plugins/sam-with-receiver/sam-with-receiver.cli/resources" ];
  };

  serialization = mkPlugin {
    name = "kotlinx-serialization-compiler-plugin";
    dirs = [
      "plugins/kotlinx-serialization/kotlinx-serialization.common/src"
      "plugins/kotlinx-serialization/kotlinx-serialization.k1/src"
      "plugins/kotlinx-serialization/kotlinx-serialization.k2/src"
      "plugins/kotlinx-serialization/kotlinx-serialization.backend/src"
      "plugins/kotlinx-serialization/kotlinx-serialization.cli/src"
    ];
    resourceDirs = [ "plugins/kotlinx-serialization/kotlinx-serialization.cli/resources" ];
  };

  kotlinx-serialization-core = mkKx {
    name = "kotlinx-serialization-core";
    commonDir = "core/commonMain/src";
    dirs = [
      "core/commonMain/src"
      "core/jvmMain/src"
    ];
    resourceDirs = [ "core/jvmMain/resources" ];
  };
  kotlinx-serialization-json = mkKx {
    name = "kotlinx-serialization-json";
    commonDir = "formats/json/commonMain/src";
    dirs = [
      "formats/json/commonMain/src"
      "formats/json/jvmMain/src"
    ];
    deps = [ self.kotlinx-serialization-core ];
  };
  };
in
self
