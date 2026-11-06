# kotlinx-coroutines-core-jvm (a dependency of kotlin-compiler-embeddable in Gradle's
# distribution), compiled like its release: Kotlin 2.1.0 (gradle.properties' kotlin_version),
# the common, concurrent and jvm sources in one multiplatform compilation, atomicfu's JVM IR
# transformation (kotlinx.atomicfu.enableJvmIrTransformation) with the atomicfu library on the
# compile classpath only, and the JDK 9 module descriptor into META-INF/versions/9
# (Java9Modularity).  DebugProbesKt.bin, a compiled class in the source tree, is the class of
# jvm/src/debug/internal/DebugProbes.kt of this compilation instead.
{
  lib,
  stdenv,
  fetchzip,
  jdk,
  moduleInfoJdk, # 11 (Java9Modularity's toolchain)
  python3,
  writeShellScript,
  kotlinCompiler, # 2.1.0
  kotlinAsm,
  atomicfuPlugin,
  version ? "1.10.2",
  hash ? "sha256-FQcNPrk2Q5EDaQViyUEnPuBHUMeqQcdHZnXWf51WkXc=",
  atomicfuVersion ? "0.26.1",
  atomicfuHash ? "sha256-71qKveblHbzsYBS2BuOJdvKEAeWalto+jfneQS9GDX0=",
}:

let
  kotlinRun = writeShellScript "kotlinc" ''
    k=${kotlinCompiler}/lib
    exec ${jdk}/bin/java -Xmx3g \
      --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED \
      --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED \
      -cp ${kotlinAsm}/share/java/kotlin-asm.jar:$k/kotlin-compiler.jar:$k/kotlin-stdlib.jar:$k/kotlin-reflect.jar:$k/kotlin-script-runtime.jar \
      org.jetbrains.kotlin.cli.jvm.K2JVMCompiler "$@"
  '';
  stdlib = "${kotlinCompiler}/lib/kotlin-stdlib.jar";
  optIns = map (a: "-opt-in=${a}") [
    "kotlin.experimental.ExperimentalTypeInference"
    "kotlinx.coroutines.DelicateCoroutinesApi"
    "kotlinx.coroutines.ExperimentalCoroutinesApi"
    "kotlinx.coroutines.ObsoleteCoroutinesApi"
    "kotlinx.coroutines.InternalCoroutinesApi"
    "kotlinx.coroutines.FlowPreview"
    "kotlin.ExperimentalMultiplatform"
  ];

  atomicfu = stdenv.mkDerivation {
    pname = "atomicfu";
    version = atomicfuVersion;
    src = fetchzip {
      url = "https://github.com/Kotlin/kotlinx-atomicfu/archive/refs/tags/${atomicfuVersion}.tar.gz";
      hash = atomicfuHash;
    };
    nativeBuildInputs = [ jdk ];
    dontConfigure = true;
    buildPhase = ''
      mkdir -p build/classes
      find atomicfu/src/commonMain -name '*.kt' | LC_ALL=C sort > build/common
      { cat build/common; find atomicfu/src/jvmMain -name '*.kt' | LC_ALL=C sort; } > build/sources
      ${kotlinRun} -no-stdlib -no-reflect -nowarn -jvm-target 1.8 -Xmulti-platform -Xexpect-actual-classes \
        -Xcommon-sources=$(paste -sd, build/common) -module-name atomicfu \
        -cp ${stdlib} -d build/classes @build/sources
    '';
    installPhase = ''
      mkdir -p $out/share/java
      jar cf $out/share/java/atomicfu.jar -C build/classes .
    '';
  };
in
stdenv.mkDerivation {
  pname = "kotlinx-coroutines-core-jvm";
  inherit version;
  src = fetchzip {
    url = "https://github.com/Kotlin/kotlinx.coroutines/archive/refs/tags/${version}.tar.gz";
    inherit hash;
  };
  nativeBuildInputs = [
    jdk
    python3
  ];
  dontConfigure = true;
  buildPhase = ''
    runHook preBuild
    c=kotlinx-coroutines-core
    mv $c/jvm/resources/DebugProbesKt.bin shipped-DebugProbesKt.bin
    mkdir -p build/classes build/resources build/versions/9 build/stubs
    # the source sets: jvm refines concurrent refines common
    for f in common concurrent jvm; do find $c/$f/src -name '*.kt' | LC_ALL=C sort > build/$f; done
    cat build/common build/concurrent build/jvm > build/sources
    fragments=$(for f in common concurrent jvm; do sed "s|^|$f:|" build/$f; done | paste -sd,)
    # compileOnly annotations (com.google.android:annotations, animal-sniffer-annotations), both
    # CLASS-retained like the originals
    mkdir -p build/stubs-src/android/annotation build/stubs-src/org/codehaus/mojo/animal_sniffer
    cat > build/stubs-src/android/annotation/SuppressLint.java <<'JAVA'
    package android.annotation;
    import java.lang.annotation.*;
    import static java.lang.annotation.ElementType.*;
    @Target({TYPE, FIELD, METHOD, PARAMETER, CONSTRUCTOR, LOCAL_VARIABLE})
    @Retention(RetentionPolicy.CLASS)
    public @interface SuppressLint { String[] value(); }
    JAVA
    cat > build/stubs-src/org/codehaus/mojo/animal_sniffer/IgnoreJRERequirement.java <<'JAVA'
    package org.codehaus.mojo.animal_sniffer;
    import java.lang.annotation.*;
    @Retention(RetentionPolicy.CLASS)
    @Documented
    @Target({ElementType.METHOD, ElementType.CONSTRUCTOR, ElementType.TYPE})
    public @interface IgnoreJRERequirement {}
    JAVA
    javac -nowarn --release 8 -d build/stubs $(find build/stubs-src -name '*.java')
    ${kotlinRun} -no-stdlib -no-reflect -nowarn -jvm-target 1.8 -progressive \
      -Xmulti-platform -Xexpect-actual-classes -Xfragments=common,concurrent,jvm \
      -Xfragment-refines=concurrent:common,jvm:concurrent -Xfragment-sources=$fragments \
      -Xexplicit-api=strict -Xdont-warn-on-error-suppression \
      -Xno-param-assertions -Xno-call-assertions -Xno-receiver-assertions -Xjvm-default=disable \
      ${lib.concatStringsSep " " optIns} \
      -Xplugin=${atomicfuPlugin}/share/java/${atomicfuPlugin.pname}.jar \
      -module-name kotlinx-coroutines-core \
      -cp ${stdlib}:${atomicfu}/share/java/atomicfu.jar:build/stubs -d build/classes @build/sources
    # DebugProbesKt.bin (the agent puts it in place of the stdlib's DebugProbesKt): the class of
    # integration-testing's debugAgentTest DebugProbes.kt, compiled against this one
    mkdir build/probes
    ${kotlinRun} -no-stdlib -no-reflect -nowarn -jvm-target 1.8 \
      -module-name kotlinx-coroutines-integration-testing_debugAgentTest -Xallow-kotlin-package \
      -cp ${stdlib}:build/classes -d build/probes integration-testing/src/debugAgentTest/kotlin/DebugProbes.kt
    cp build/probes/kotlin/coroutines/jvm/internal/DebugProbesKt.class build/DebugProbesKt.bin
    cmp build/DebugProbesKt.bin shipped-DebugProbesKt.bin && echo "DebugProbesKt.bin: identical to the shipped one" || true
    cp -r $c/jvm/resources/. build/resources/
    cp build/DebugProbesKt.bin build/resources/
    printf '%s' ${version} > build/kotlinx_coroutines_core.version
    # Java9Modularity: module-info.java without the atomicfu requirement, by a JDK 11 javac
    mkdir -p build/module-info build/v9/META-INF/versions
    grep -v kotlinx.atomicfu $c/jvm/src/module-info.java > build/module-info/module-info.java
    ${moduleInfoJdk}/bin/javac -nowarn --release 9 -Xlint:-requires-transitive-automatic -d build/versions/9 \
      --module-path ${stdlib} --patch-module kotlinx.coroutines.core=build/classes \
      build/module-info/module-info.java
    mv build/versions/9 build/v9/META-INF/versions/9
    runHook postBuild
  '';
  installPhase = ''
    mkdir -p $out/share/java
    # (the jvmJar task: classes, resources, META-INF/versions/9, then the version file)
    python3 ${./gradle-jar.py} $out/share/java/kotlinx-coroutines-core-jvm.jar \
      --attr 'Premain-Class: kotlinx.coroutines.debug.internal.AgentPremain' \
      --attr 'Can-Retransform-Classes: true' --attr 'Multi-Release: true' \
      --root build/classes --root build/resources --root build/v9 \
      --append META-INF/kotlinx_coroutines_core.version=build/kotlinx_coroutines_core.version
  '';
  passthru = { inherit atomicfu; };
  meta = {
    description = "kotlinx-coroutines-core for the JVM";
    homepage = "https://github.com/Kotlin/kotlinx.coroutines";
    license = lib.licenses.asl20;
  };
}
