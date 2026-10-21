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

  old = callPackage ./openjdk-9-10.nix { };

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
  openjdk11 = mkOpenjdk "11" (asBootJdk self.openjdk10 "${self.openjdk10}");
})
