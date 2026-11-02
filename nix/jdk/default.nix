# JDKs built from the IcedTea bootstrap instead of nixpkgs' temurin seed.
#
# nixpkgs' own OpenJDK recipe takes its boot JDK as the `jdk-bootstrap`
# argument; we hand it the JDKs from our chain.
{
  lib,
  pkgs,
  callPackage,
  icedtea7,
}:

let
  generic = "${pkgs.path}/pkgs/development/compilers/openjdk/generic.nix";

  # nixpkgs expects `.home` and `.override { gtkSupport = ...; }`.
  asBootJdk =
    jdk: home:
    jdk
    // {
      inherit home;
      override = _: asBootJdk jdk home;
    };

  old = callPackage ./openjdk-own.nix { };

  mkOpenjdk =
    featureVersion: boot:
    pkgs.callPackage generic (
      {
        inherit featureVersion;
        headless = true;
        jdk-bootstrap = boot;
      }
      // lib.optionalAttrs (lib.versionOlder featureVersion "11") { enableGtk = false; }
    );
in
lib.fix (self: {
  openjdk8 = mkOpenjdk "8" (asBootJdk icedtea7 "${icedtea7}");
  # nixpkgs has no recipes for 9 and 10; ported from Guix.
  openjdk9 = old.openjdk9 self.openjdk8;
  openjdk10 = old.openjdk10 self.openjdk9;
  # Built serially, like in Guix, and without the javac server (one JVM for all javac
  # runs): otherwise javac hits a ConcurrentModificationException reading the boot JDK's
  # jrt filesystem.
  openjdk11 = (mkOpenjdk "11" (asBootJdk self.openjdk10 "${self.openjdk10}")).overrideAttrs (o: {
    preConfigure = ''
      configureFlags+=("--with-jobs=1" "--disable-javac-server")
    '';
  });
  openjdk12 = old.openjdk12 self.openjdk11;
  openjdk13 = old.openjdk13 self.openjdk12;
  openjdk14 = old.openjdk14 self.openjdk13;
  openjdk15 = old.openjdk15 self.openjdk14;
  openjdk16 = old.openjdk16 self.openjdk15;
  openjdk17 = mkOpenjdk "17" (asBootJdk self.openjdk16 "${self.openjdk16}");
  openjdk18 = old.openjdk18 self.openjdk17;
  openjdk19 = old.openjdk19 self.openjdk18;
  openjdk20 = old.openjdk20 self.openjdk19;
  openjdk21 = mkOpenjdk "21" (asBootJdk self.openjdk20 "${self.openjdk20}");
})
