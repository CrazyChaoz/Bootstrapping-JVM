{ pkgs }:

pkgs.lib.makeScope pkgs.newScope (self: {
  # The JDK used by all stages.  For now this is nixpkgs' openjdk8, which is
  # itself built from source but seeded with a temurin binary; it is meant to be
  # replaced by a JDK bootstrapped from jamvm/classpath (see nix/jdk).
  jdk8 = pkgs.openjdk8;
  jdk = self.jdk8;

  # Helpers
  javaLib = self.callPackage ./lib/mk-jar.nix { };
  inherit (self.javaLib) mkJar classpathOf;

  fetchIntellij = self.callPackage ./lib/fetch-intellij.nix { };
  intellijSources = self.callPackage ./intellij/sources.nix { };
  intellij = self.callPackage ./intellij { };

  fetchKotlin = self.callPackage ./lib/fetch-kotlin.nix { };
  kotlinSources = self.callPackage ./kotlin/sources.nix { };
  kotlin = self.callPackage ./kotlin { };
  kotlinLibs = self.callPackage ./kotlin/libs.nix { };

  jdkBootstrap = self.callPackage ./jdk/bootstrap.nix { };
  icedtea7 = self.callPackage ./jdk/icedtea7.nix { };
  jdks = self.callPackage ./jdk { inherit pkgs; };

  # Build tools
  ant = self.callPackage ./java/ant.nix { };
  ant_1_10 = self.callPackage ./java/ant.nix {
    version = "1.10.15";
    hash = "sha256-oitJW5wFSChB+RnTRA0rOCE64iPgOYWbc6q83kRBmbE=";
  };
  java = self.callPackage ./java { };
  antlr = self.callPackage ./java/antlr.nix { };
  # Groovy needs JDK >= 9 to build.
  # TODO: use the JDK from nix/jdk once the chain is complete.
  jdk11 = pkgs.openjdk11;
  javaLib11 = self.callPackage ./lib/mk-jar.nix { jdk = self.jdk11; };
  # Gradle: JDK 21 from the chain (nix/jdk).
  jdk21 = self.jdks.openjdk21;
  javaLib21 = self.callPackage ./lib/mk-jar.nix { jdk = self.jdk21; };
  gradleLibs = self.callPackage ./gradle/libs.nix {
    jdk = self.jdk21;
    inherit (self.javaLib21) mkJar classpathOf;
  };

  gradleSrc = self.callPackage ./gradle/source.nix { };

  gradleGroovy = self.callPackage ./gradle/groovy.nix {
    jdk = self.jdk21;
    inherit (self.javaLib21) classpathOf closureOf;
    inherit (self.gradleLibs) mk gh;
    inherit (self.groovy) javacc qdox-1_12;
  };

  # a jar of the Kotlin 2.4.0 distribution, in the share/java layout used by classpathOf
  kotlinJar =
    name:
    pkgs.runCommand name { } ''
      mkdir -p $out/share/java
      ln -s ${self.kotlin."2.4.0"}/lib/${name}.jar $out/share/java/${name}.jar
    '';

  gradleModules = self.callPackage ./gradle/modules.nix {
    jdk = self.jdk21;
    inherit (self.javaLib21) classpathOf closureOf;
    inherit (self) gradleSrc gradleLibs gradleGroovy;
    kotlinCompiler = self.kotlin."2.4.0";
    extraLibs = {
      fastutil = self.java.fastutil;
      kotlinStdlib = self.kotlinJar "kotlin-stdlib";
      kotlinReflect = self.kotlinJar "kotlin-reflect";
      kotlinScriptRuntime = self.kotlinJar "kotlin-script-runtime";
    };
  };

  groovy = self.callPackage ./java/groovy.nix {
    jdk = self.jdk11;
    inherit (self.javaLib11) mkJar;
    ant = self.ant_1_10;
  };
})
