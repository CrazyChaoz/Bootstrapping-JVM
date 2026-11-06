# org.gradle.buildtool.internal:configuration-cache-report-jvm 1.36 (Gradle 9.9's
# libs.configurationCacheReport): the report model (commonMain, kotlinx-serialization) and
# HtmlReportWriter (jvmMain).  1.36 is not tagged; its published sources are those of c52219d.
#
# The jar of upstream carries configuration-cache-report.html, the report viewer, compiled from
# jsMain with Kotlin/JS, which is not bootstrapped here.  In its place: report-template.html, a
# page that shows the report data as JSON.  It keeps the placeholder <script> line that
# HtmlReportTemplateLoader splits the template at.
{
  lib,
  stdenv,
  fetchzip,
  jdk,
  stripJavaArchivesHook,
  writeShellScript,
  kotlinCompiler,
  kotlinAsm,
  kotlinPlugins,
}:

let
  kotlinRun = writeShellScript "kotlinc" ''
    k=${kotlinCompiler}/lib
    exec ${jdk}/bin/java -Xmx2g \
      --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED \
      --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED \
      --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.desktop/java.awt.font=ALL-UNNAMED \
      -cp ${kotlinAsm}/share/java/kotlin-asm.jar:$k/kotlin-compiler.jar:$k/kotlin-stdlib.jar:$k/kotlin-reflect.jar:$k/kotlin-script-runtime.jar \
      org.jetbrains.kotlin.cli.jvm.K2JVMCompiler "$@"
  '';
  json = kotlinPlugins.kotlinx-serialization-json;
  core = kotlinPlugins.kotlinx-serialization-core;
in
stdenv.mkDerivation {
  pname = "configuration-cache-report";
  version = "1.36";
  src = fetchzip {
    url = "https://github.com/gradle/configuration-cache-report/archive/c52219d9fb9c57d234d712795770e9005e8b2917.tar.gz";
    hash = "sha256-hi7y1+mLAyTpBGeSt8EXAWw3VLe4S/+Rq3UFYNnsQrc=";
  };
  nativeBuildInputs = [
    jdk
    stripJavaArchivesHook
  ];
  dontConfigure = true;
  buildPhase = ''
    runHook preBuild
    mkdir -p build/classes/org/gradle/problems/internal/report
    find src/commonMain/kotlin -name '*.kt' | LC_ALL=C sort > build/common
    { cat build/common; find src/jvmMain/kotlin -name '*.kt' | LC_ALL=C sort; } > build/sources
    ${kotlinRun} -no-stdlib -no-reflect -nowarn -jvm-target 1.8 \
      -Xmulti-platform -Xcommon-sources=$(paste -sd, build/common) \
      -Xplugin=${kotlinPlugins.serialization}/share/java/kotlinx-serialization-compiler-plugin.jar \
      -module-name org.gradle.buildtool.internal_configuration-cache-report \
      -cp "${kotlinCompiler}/lib/kotlin-stdlib.jar:${json}/share/java/kotlinx-serialization-json.jar:${core}/share/java/kotlinx-serialization-core.jar" \
      -d build/classes @build/sources
    cp ${./configuration-cache-report/report-template.html} \
      build/classes/org/gradle/problems/internal/report/configuration-cache-report.html
    runHook postBuild
  '';
  installPhase = ''
    mkdir -p $out/share/java
    jar cf $out/share/java/configuration-cache-report.jar -C build/classes .
  '';
  passthru.javaDeps = [
    json
    core
  ];
  meta = {
    description = "The model and HTML writer of Gradle's configuration cache and problems reports";
    homepage = "https://github.com/gradle/configuration-cache-report";
    license = lib.licenses.asl20;
  };
}
