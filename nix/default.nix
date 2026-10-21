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
  java = self.callPackage ./java { };
  antlr = self.callPackage ./java/antlr.nix { };
  # Groovy needs JDK >= 9 to build.
  # TODO: use the JDK from nix/jdk once the chain is complete.
  jdk11 = pkgs.openjdk11;
  javaLib11 = self.callPackage ./lib/mk-jar.nix { jdk = self.jdk11; };
  groovy = self.callPackage ./java/groovy.nix {
    jdk = self.jdk11;
    inherit (self.javaLib11) mkJar;
  };
})
