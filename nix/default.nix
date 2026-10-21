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

  # Build tools
  ant = self.callPackage ./java/ant.nix { };
  java = self.callPackage ./java { };
})
