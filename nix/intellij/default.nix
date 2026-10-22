# The parts of the IntelliJ platform that the Kotlin compiler needs, built
# from source for the SDK versions used along the bootstrap chain.  Ported
# from TarCV/kotlin-guix (intellij-*-139/141/143/172).
{
  lib,
  mkJar,
  ant,
  java,
  intellijSources,
}:

let
  p = name: ../../patches/tarcv + "/${name}";

  mkSdk =
    {
      version,
      # patches applied to every module
      basePatches,
      annotations,
      utilRtPatches ? [ ],
      utilPatches ? [ ],
      corePatches ? [ ],
      utilRemove ? [ ],
      target ? "1.6",
      newTarget ? target,
      asm ? java.jetbrains-asm-5,
      coreDeps ? [ ],
      utilDeps ? [ ],
      jdom ? java.jdom-1,
      # From 173 on jps-model-api uses util (xmlb annotations)
      jpsApiNeedsUtil ? false,
    }:
    let
      src = intellijSources.${version};
      self = {
        inherit annotations;

        util-rt = mkJar {
          pname = "intellij-util-rt";
          inherit version src;
          patches = basePatches ++ utilRtPatches;
          sourceDirs = [ "platform/util-rt/src" ];
          buildDeps = [ annotations ];
          javaRelease = target;
        };

        util = mkJar {
          pname = "intellij-util";
          inherit version src;
          patches = basePatches ++ utilPatches;
          postPatch = ''
            rm -rf ${lib.escapeShellArgs utilRemove}
          '';
          sourceDirs = [ "platform/util/src" ];
          resourceDirs = [ "platform/util/resources" ];
          buildDeps = [ annotations ];
          deps = [
            java.cglib
            java.jakarta-oro
            jdom
            java.log4j-1
            java.jna
            java.jna-platform
            java.jsr166e-seqlock
            java.picocontainer-1
            self.util-rt
            java.jetbrains-trove4j
          ]
          ++ utilDeps;
          javaRelease = newTarget;
        };

        jps-model-api = mkJar {
          pname = "intellij-jps-model-api";
          inherit version src;
          patches = basePatches;
          sourceDirs = [ "jps/model-api/src" ];
          buildDeps = [ annotations ];
          deps = [ self.util-rt ] ++ lib.optional jpsApiNeedsUtil self.util;
          javaRelease = newTarget;
        };

        jps-model-impl = mkJar {
          pname = "intellij-jps-model-impl";
          inherit version src;
          patches = basePatches;
          sourceDirs = [ "jps/model-impl/src" ];
          buildDeps = [ annotations ];
          deps = [
            self.jps-model-api
            self.util
          ];
          javaRelease = newTarget;
          postBuild = ''
            cp -r jps/model-impl/src/META-INF build/classes/
          '';
        };

        # "intellij-core" as Kotlin expects it: the core modules plus the jars
        # that the upstream intellij-core.jar bundles.
        core = mkJar {
          pname = "intellij-core";
          inherit version src;
          patches = basePatches ++ corePatches;
          sourceDirs = [
            "java/java-psi-api/src"
            "java/java-psi-impl/gen"
            "java/java-psi-impl/src"
            "platform/boot/src"
            "platform/core-api/src"
            "platform/core-impl/src"
            "platform/extensions/src"
          ];
          buildDeps = [ annotations ];
          deps = [
            java.automaton
            java.javax-inject
            java.jetbrains-asm-4
            asm
            java.iq80-snappy
            java.xstream
            self.jps-model-impl
            self.util
          ]
          ++ coreDeps;
          mergeJars = map (d: "${d}/share/java/${d.pname}.jar") [
            jdom
            java.javax-inject
            self.jps-model-api
            self.jps-model-impl
            self.util
            self.util-rt
          ];
          javaRelease = newTarget;
          passthru = { inherit asm; };
          preBuild = ''
            mkdir -p build/classes/messages build/classes/META-INF
            for m in java/java-psi-api/src/messages java/java-psi-impl/src/messages; do
              [ -d $m ] && cp -r $m/. build/classes/messages/
            done
            cp -r platform/boot/src/META-INF/. build/classes/META-INF/
            for d in platform/core-api/src/META-INF platform/core-impl/src/META-INF; do
              [ -d $d ] && cp -r $d/. build/classes/META-INF/ || true
            done
          '';
        };

        javac2 = mkJar {
          pname = "intellij-compiler-javac2";
          inherit version src;
          patches = basePatches;
          sourceDirs = [
            "java/compiler/javac2/src"
            "java/compiler/instrumentation-util/src"
          ];
          buildDeps = [ ant ];
          deps = [ asm ];
          # com.sun.istack.internal annotations are hidden by ct.sym
          javacFlags = [ "-XDignore.symbol.file" ];
          javaRelease = target;
        };
      };
    in
    self;

  annotations-141 = mkJar {
    pname = "intellij-annotations";
    version = "141";
    src = intellijSources."141";
    patches = [ (p "sdk-141.patch") ];
    sourceDirs = [ "platform/annotations/src" ];
    javaRelease = "1.5";
  };

  mkAnnotations =
    version:
    mkJar {
      pname = "intellij-annotations";
      inherit version;
      src = intellijSources.${version};
      sourceDirs = [
        "platform/annotations/java5/src"
        "platform/annotations/common/src"
      ];
      javaRelease = "1.5";
    };

  macUi = [
    "platform/util/src/com/intellij/util/AppleHiDPIScaledImage.java"
    "platform/util/src/com/intellij/util/ui/MacUIUtil.java"
    "platform/util/src/com/intellij/ui/mac"
  ];
in
{
  inherit annotations-141;

  "139" = mkSdk {
    version = "139";
    basePatches = [ (p "sdk-139.patch") ];
    annotations = annotations-141;
    utilRtPatches = [ (p "sdk-util-rt-139-linkedhashmap.patch") ];
    corePatches = [ (p "sdk-core-139-compatibility.patch") ];
    utilRemove = macUi;
  };

  "141" = mkSdk {
    version = "141";
    basePatches = [ (p "sdk-141.patch") ];
    annotations = annotations-141;
    utilRemove = macUi;
    coreDeps = [ java.guava-20 ];
  };

  "143" = mkSdk {
    version = "143";
    basePatches = [ (p "sdk-143.patch") ];
    annotations = mkAnnotations "143";
    utilPatches = [
      (p "sdk-util-143-jdom.patch")
      (p "sdk-util-143-remove-imgscalr.patch")
      (p "sdk-util-143-tests.patch")
    ];
    corePatches = [
      (p "sdk-core-143-jdom.patch")
      (p "sdk-core-143-remove-mac.patch")
    ];
    utilRemove = macUi;
    utilDeps = [ java.iq80-snappy ];
    coreDeps = [ java.guava-20 ];
  };

  "172" = mkSdk {
    version = "172";
    basePatches = [ (p "sdk-172.patch") ];
    annotations = mkAnnotations "172";
    utilPatches = [
      (p "sdk-util-172-jdom.patch")
      (p "sdk-util-172-remove-gui-dependencies.patch")
      (p "sdk-util-143-tests.patch")
    ];
    corePatches = [
      (p "sdk-core-172-jdom.patch")
      (p "sdk-core-143-remove-mac.patch")
      (p "sdk-core-172.patch")
      (p "sdk-core-172-asm.patch")
      (p "sdk-core-172-remove-streamex.patch")
    ];
    utilRemove = macUi ++ [ "platform/util/src/com/intellij/util/SVGLoader.java" ];
    utilDeps = [ java.iq80-snappy ];
    coreDeps = [
      java.cglib
      java.guava-20
    ];
    target = "1.5";
    newTarget = "1.8";
    asm = java.jetbrains-asm-6;
  };

  # Not in TarCV: needed by Kotlin 1.2.31.  Starts from the 172 patch set.
  "173" = mkSdk {
    version = "173";
    jdom = java.jdom-ij;
    jpsApiNeedsUtil = true;
    basePatches = [ ../../patches/own/sdk-173.patch ];
    annotations = mkAnnotations "173";
    utilPatches = [ ];
    corePatches = [ ];
    utilRemove = macUi ++ [
      "platform/util/src/com/intellij/util/SVGLoader.java"
      "platform/util/src/com/intellij/util/io/TarUtil.java"
    ];
    utilDeps = [ java.iq80-snappy ];
    coreDeps = [
      java.cglib
      java.guava-20
    ];
    target = "1.5";
    newTarget = "1.8";
    asm = java.jetbrains-asm-6;
  };

  # Needed by Kotlin 1.2.31 (JavaModuleSystem, JvmElementProvider).
  "181" = mkSdk {
    version = "181";
    jdom = java.jdom-ij;
    jpsApiNeedsUtil = true;
    basePatches = [ ../../patches/own/sdk-181.patch ];
    annotations = mkAnnotations "181";
    utilPatches = [ ];
    corePatches = [ ];
    utilRemove = macUi ++ [
      "platform/util/src/com/intellij/util/SVGLoader.java"
      "platform/util/src/com/intellij/util/io/TarUtil.java"
    ];
    utilDeps = [ java.iq80-snappy ];
    coreDeps = [
      java.cglib
      java.guava-20
    ];
    target = "1.5";
    newTarget = "1.8";
    asm = java.jetbrains-asm-6;
  };

  "182" = mkSdk {
    version = "182";
    jdom = java.jdom-ij-2;
    jpsApiNeedsUtil = true;
    basePatches = [ ../../patches/own/sdk-182.patch ];
    annotations = java.jetbrains-annotations-16;
    utilRemove = macUi ++ [
      "platform/util/src/com/intellij/util/SVGLoader.java"
      "platform/util/src/com/intellij/util/io/TarUtil.java"
      # Batik/Rhino shims for SVGLoader
      "platform/util/src/org/apache/batik"
      "platform/util/src/org/w3c"
    ];
    utilDeps = [ java.lz4-compat ];
    coreDeps = [
      java.cglib
      java.guava-20
    ];
    target = "1.5";
    newTarget = "1.8";
    asm = java.jetbrains-asm-6;
  };
  "183" = mkSdk {
    version = "183";
    jdom = java.jdom-ij-2;
    jpsApiNeedsUtil = true;
    basePatches = [ ../../patches/own/sdk-183.patch ];
    annotations = java.jetbrains-annotations-16;
    utilRemove = macUi ++ [
      "platform/util/src/com/intellij/util/SVGLoader.java"
      "platform/util/src/com/intellij/util/io/TarUtil.java"
      # Batik/Rhino shims for SVGLoader
      "platform/util/src/org/apache/batik"
      "platform/util/src/org/w3c"
    ];
    utilDeps = [
      java.lz4-compat
      java.imgscalr
    ];
    coreDeps = [
      java.cglib
      java.guava-20
    ];
    target = "1.5";
    newTarget = "1.8";
    asm = java.jetbrains-asm-7;
  };
}
