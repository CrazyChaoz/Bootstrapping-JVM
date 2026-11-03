# Kotlin compiler plugins (from the Kotlin 2.4.0 sources) used to compile Gradle's
# own Kotlin modules.  Built against the unshaded kotlin-compiler.jar.
{
  lib,
  stdenv,
  fetchzip,
  jdk,
  zip,
  unzip,
  stripJavaArchivesHook,
  kotlinSrc,
  kotlinSrc17,
  withPowerAssert ? true,
  kxVersion ? "1.11.0",
  kxHash ? "sha256-mDlxNHJCVCpjG42EDaHVpDEA9qiB4gSv+3HkBeqVYno=",
  kotlinCompiler,
  kotlinAsm,
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
      -cp ${kotlinAsm}/share/java/kotlin-asm.jar:$k/kotlin-compiler.jar:$k/kotlin-stdlib.jar:$k/kotlin-reflect.jar:$k/kotlin-script-runtime.jar \
      org.jetbrains.kotlin.cli.jvm.K2JVMCompiler "$@"
  '';
  mkPlugin =
    {
      name,
      dirs, # source directories, relative to the Kotlin source root
      resourceDirs ? [ ],
      deps ? [ ],
      patch ? "",
      postCompile ? "",
      extraArgs ? [ ],
      src ? kotlinSrc,
    }:
    stdenv.mkDerivation {
      pname = name;
      version = "2.4.0";
      inherit src;
      nativeBuildInputs = [
        jdk
        zip
        unzip
        stripJavaArchivesHook
      ];
      dontConfigure = true;
      buildPhase = ''
        mkdir -p build/classes
        ${patch}
        find ${lib.escapeShellArgs dirs} \( -name '*.kt' -o -name '*.java' \) -not -path '*/test/*' -not -path '*/testData/*' > build/sources
        ${kotlinRun} -no-stdlib -no-reflect -nowarn -Xskip-prerelease-check -Xallow-kotlin-package -jvm-target 17 -Xjvm-default=all \
          -opt-in=org.jetbrains.kotlin.compiler.plugin.ExperimentalCompilerApi \
          -opt-in=org.jetbrains.kotlin.fir.symbols.SymbolInternals \
          -opt-in=org.jetbrains.kotlin.fir.FirImplementationDetail \
          -opt-in=org.jetbrains.kotlin.ir.symbols.UnsafeDuringIrConstructionAPI \
          ${lib.escapeShellArgs extraArgs} \
          -module-name ${name} \
          -cp "${kotlinCompiler}/lib/kotlin-compiler.jar:${kotlinCompiler}/lib/kotlin-stdlib.jar:${kotlinCompiler}/lib/kotlin-reflect.jar:${kotlinCompiler}/lib/kotlin-script-runtime.jar${
            lib.concatMapStrings (d: ":${d}/share/java/${d.pname}.jar") deps
          }" \
          -d build/classes @build/sources
        if [ -n "$(grep '\.java$' build/sources)" ]; then
          grep '\.java$' build/sources > build/jsources
          javac -nowarn -d build/classes -cp "build/classes:${kotlinCompiler}/lib/kotlin-compiler.jar:${kotlinCompiler}/lib/kotlin-stdlib.jar${
            lib.concatMapStrings (d: ":${d}/share/java/${d.pname}.jar") deps
          }" @build/jsources
        fi
        for d in ${lib.escapeShellArgs resourceDirs}; do cp -r $d/. build/classes/; done
        ${postCompile}
      '';
      installPhase = ''
        mkdir -p $out/share/java
        jar cf $out/share/java/${name}.jar -C build/classes .
      '';
    };
  kxSrc = fetchzip {
    url = "https://github.com/Kotlin/kotlinx.serialization/archive/refs/tags/v${kxVersion}.tar.gz";
    hash = kxHash;
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
      version = kxVersion;
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
          ${
            lib.optionalString (kxVersion == "1.11.0") "-Xreturn-value-checker=check"
          } -opt-in=kotlinx.serialization.SealedSerializationApi -opt-in=kotlinx.serialization.json.internal.JsonFriendModuleApi -opt-in=kotlinx.serialization.internal.CoreFriendModuleApi \
          -Xmulti-platform -Xexpect-actual-classes -Xno-check-actual \
          -opt-in=kotlin.RequiresOptIn -opt-in=kotlinx.serialization.InternalSerializationApi \
          -opt-in=kotlinx.serialization.ExperimentalSerializationApi -opt-in=kotlin.ExperimentalUnsignedTypes \
          -opt-in=kotlin.contracts.ExperimentalContracts -opt-in=kotlin.ExperimentalStdlibApi \
          -Xplugin=${self.serialization}/share/java/kotlinx-serialization-compiler-plugin.jar \
          -module-name ${name} \
          -cp "${kotlinCompiler}/lib/kotlin-stdlib.jar${
            lib.concatMapStrings (d: ":${d}/share/java/${d.pname}.jar") deps
          }:$(echo ${jetbrainsAnnotations}/share/java/*.jar)" \
          -d build/classes @build/sources
        for d in ${lib.escapeShellArgs resourceDirs}; do if [ -d $d ]; then cp -r $d/. build/classes/; fi; done
      '';
      installPhase = ''
        mkdir -p $out/share/java
        printf 'Manifest-Version: 1.0\nImplementation-Version: ${kxVersion}\nBundle-Version: ${kxVersion}\nBundle-SymbolicName: ${name}\n' > manifest
        jar cfm $out/share/java/${name}.jar manifest -C build/classes .
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

    # kotlin-metadata-jvm: the kotlinx-metadata API plus the compiler's metadata classes and protobuf
    # (relocated to kotlin.metadata.internal in default.nix)
    metadataJvmUnshaded = mkPlugin {
      name = "kotlin-metadata-jvm-unshaded";
      dirs = [
        "core/metadata/src"
        "core/metadata.jvm/src"
        "libraries/kotlinx-metadata/src"
        "libraries/kotlinx-metadata/jvm/src"
      ];
      resourceDirs = [ "libraries/kotlinx-metadata/jvm/resources" ];
      postCompile = ''
        unzip -q ${kotlinCompiler}/lib/kotlin-compiler.jar 'org/jetbrains/kotlin/protobuf/*' -d build/classes
      '';
    };

    # kotlinx-metadata-jvm 0.5.0 (the API Gradle 8's Kotlin DSL uses) from the Kotlin 1.7.0 sources
    metadataJvm050Unshaded = mkPlugin {
      name = "kotlinx-metadata-jvm-unshaded";
      src = kotlinSrc17;
      dirs = [
        "core/metadata/src"
        "core/metadata.jvm/src"
        "libraries/kotlinx-metadata/src"
        "libraries/kotlinx-metadata/jvm/src"
      ];
      resourceDirs = [ "libraries/kotlinx-metadata/jvm/resources" ];
      extraArgs = [
        "-language-version"
        "2.2"
        "-api-version"
        "2.2"
      ];
      postCompile = ''
        unzip -q ${kotlinCompiler}/lib/kotlin-compiler.jar 'org/jetbrains/kotlin/protobuf/*' -d build/classes
      '';
    };

    # --- scripting and build tools (unshaded; the embeddable variants are relocated in default.nix)
    scriptingCommon = mkPlugin {
      name = "kotlin-scripting-common";
      dirs = [ "libraries/scripting/common/src" ];
    };
    scriptingJvm = mkPlugin {
      name = "kotlin-scripting-jvm";
      dirs = [ "libraries/scripting/jvm/src" ];
      deps = [ self.scriptingCommon ];
    };
    scriptingCompilerImpl = mkPlugin {
      name = "kotlin-scripting-compiler-impl";
      # (the IntelliJ core of the bootstrapped compiler has no LocalFileSystem)
      patch = ''
        sed -i 's|LocalFileSystem.getInstance().findFileByIoFile(file)|com.intellij.openapi.vfs.StandardFileSystems.local().findFileByPath(file.absolutePath)|' plugins/scripting/scripting-compiler-impl/src/org/jetbrains/kotlin/scripting/resolve/refineCompilationConfiguration.kt
      '';
      dirs = [ "plugins/scripting/scripting-compiler-impl/src" ];
      resourceDirs = [ ];
      deps = [
        self.scriptingCommon
        self.scriptingJvm
      ];
    };
    powerAssert = mkPlugin {
      name = "kotlin-power-assert-compiler-plugin";
      dirs = map (m: "plugins/power-assert/power-assert-compiler/power-assert.${m}/src") [
        "common"
        "frontend"
        "backend"
        "cli"
      ];
      resourceDirs = [ "plugins/power-assert/power-assert-compiler/power-assert.cli/resources" ];
    };
    scriptingCompiler = mkPlugin {
      name = "kotlin-scripting-compiler";
      patch = ''
        f=plugins/scripting/scripting-compiler/src/org/jetbrains/kotlin/scripting/compiler/plugin/dependencies/ScriptsCompilationDependencies.kt
        sed -i '/^import com.intellij.openapi.vfs.originalFile$/d; s/(virtualFile.originalFile() ?: virtualFile)/virtualFile/' $f
      '';
      dirs = [ "plugins/scripting/scripting-compiler/src" ];
      resourceDirs = [ "plugins/scripting/scripting-compiler/resources" ];
      deps = [
        self.scriptingCommon
        self.scriptingJvm
        self.scriptingCompilerImpl
      ]
      ++ lib.optional withPowerAssert self.powerAssert;
    };
    scriptingJvmHost = mkPlugin {
      name = "kotlin-scripting-jvm-host";
      dirs = [ "libraries/scripting/jvm-host/src" ];
      deps = [
        self.scriptingCommon
        self.scriptingJvm
        self.scriptingCompilerImpl
        self.scriptingCompiler
      ];
    };
    buildToolsApi = mkPlugin {
      name = "kotlin-build-tools-api";
      dirs = [
        "compiler/build-tools/kotlin-build-tools-api/src"
        "compiler/build-tools/kotlin-build-tools-api/gen"
      ];
    };
    # the implementation of the build tools API (with the compiler runner, daemon client, ... that it embeds)
    buildToolsImpl = mkPlugin {
      name = "kotlin-build-tools-impl";
      dirs = [
        "compiler/build-tools/kotlin-build-tools-impl/src"
        "compiler/build-tools/kotlin-build-tools-impl/gen"
        "compiler/build-tools/kotlin-build-tools-cri-impl/src"
        "compiler/build-tools/kotlin-build-tools-jdk-utils/src"
        "compiler/compiler-runner-unshaded/src"
        "compiler/daemon/daemon-common/src"
        "compiler/daemon/daemon-client/src"
        "libraries/tools/kotlin-tooling-core/src"
        "libraries/tools/abi-validation/abi-tools-api/src"
        "libraries/tools/abi-validation/abi-tools/src"
        "compiler/util-klib-abi/src"
      ];
      resourceDirs = [ "compiler/build-tools/kotlin-build-tools-impl/src/main/resources" ];
      extraArgs = [
        "-opt-in=org.jetbrains.kotlin.buildtools.api.ExperimentalBuildToolsApi"
        "-opt-in=kotlinx.serialization.ExperimentalSerializationApi"
        "-Xplugin=${self.serialization}/share/java/kotlinx-serialization-compiler-plugin.jar"
      ];
      deps = [
        self.kotlinx-serialization-core
        self.kotlinx-serialization-protobuf
        self.diff-utils
        self.buildToolsApi
        self.scriptingCommon
        self.scriptingJvm
        self.scriptingCompilerImpl
        self.scriptingCompiler
        self.metadataJvmUnshaded
      ];
    };
    assignment = mkPlugin {
      name = "kotlin-assignment-compiler-plugin";
      dirs = map (m: "plugins/assign-plugin/assign-plugin.${m}/src") [
        "common"
        "k1"
        "k2"
        "cli"
      ];
      resourceDirs = [ "plugins/assign-plugin/assign-plugin.cli/resources" ];
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
    kotlinx-serialization-protobuf = mkKx {
      name = "kotlinx-serialization-protobuf";
      commonDir = "formats/protobuf/commonMain/src";
      dirs = [
        "formats/protobuf/commonMain/src"
        "formats/protobuf/jvmMain/src"
      ];
      deps = [ self.kotlinx-serialization-core ];
    };

    diff-utils = stdenv.mkDerivation {
      pname = "java-diff-utils";
      version = "4.12";
      src = fetchzip {
        url = "https://github.com/java-diff-utils/java-diff-utils/archive/refs/tags/java-diff-utils-parent-4.12.tar.gz";
        hash = "sha256-QhdBPejv9yQBY4Oc4NQw2FultQPdi0eGJyqiIL56jQE=";
      };
      nativeBuildInputs = [ jdk ];
      dontConfigure = true;
      buildPhase = ''
        mkdir classes
        find java-diff-utils/src/main/java -name '*.java' > sources
        javac -nowarn -d classes @sources
      '';
      installPhase = ''
        mkdir -p $out/share/java
        jar cf $out/share/java/java-diff-utils.jar -C classes .
      '';
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
