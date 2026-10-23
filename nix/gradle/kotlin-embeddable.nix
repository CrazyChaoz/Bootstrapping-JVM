# kotlin-compiler-embeddable and friends: the compiler and its plugins with the
# third party packages relocated into org.jetbrains.kotlin.* (the relocation list of
# Kotlin's embeddable.kt), done with jarjar (classes) plus a script for resources.
{
  lib,
  stdenv,
  jdk,
  zip,
  gradleLibs,
  classpathOf,
  stripJavaArchivesHook,
}:

let
  # embeddable.kt: packagesToRelocate (+ protobuf, intellij, javax.inject)
  prefix = "org.jetbrains.kotlin";
  packages = [
    "com.google"
    "com.sampullara"
    "org.apache"
    "org.jdom"
    "org.picocontainer"
    "org.jline"
    "org.fusesource"
    "net.jpountz"
    "one.util.streamex"
    "it.unimi.dsi.fastutil"
    "kotlinx.collections.immutable"
    "com.fasterxml"
    "org.codehaus"
    "io.opentelemetry"
    "io.vavr"
    "org.antlr"
    "javax.inject"
    "com.intellij"
  ];
  keep = [
    "com.intellij.projectService"
    "com.intellij.applicationService"
    "org.fusesource.jansi.internal.CLibrary"
  ];
in
{
  # `jars`: the input jars (merged), `exclude`: path prefixes to drop
  relocate =
    {
      name,
      jars,
      exclude ? [ ],
    }:
    stdenv.mkDerivation {
      pname = name;
      version = "2.4.0";
      dontUnpack = true;
      nativeBuildInputs = [
        jdk
        zip
        stripJavaArchivesHook
      ];
      buildPhase = ''
        export CLASSPATH="${classpathOf [ gradleLibs.asm gradleLibs.asm-commons gradleLibs.asm-tree ]}"
        mkdir cls
        cp ${./Relocate.java} Relocate.java
        javac -nowarn -d cls Relocate.java
        java -Xmx8g -cp "cls:$CLASSPATH" Relocate ${prefix} ${lib.concatStringsSep "," packages} \
          ${lib.concatStringsSep "," keep} ${lib.concatStringsSep "," exclude} relocated.jar ${lib.concatStringsSep " " jars}
      '';
      installPhase = ''
        mkdir -p $out/share/java
        cp relocated.jar $out/share/java/${name}.jar
      '';
    };
}
