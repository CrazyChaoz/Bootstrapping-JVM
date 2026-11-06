# The Gradle versions built here: the hash of each release's source tree (source.nix, binaries
# stripped) and its module graph, modules/VERSION.json.  The settings of a release line (8.x,
# 9.x) are in pkgs/top-level/all-packages.nix (gradleLine).
#
# A new release: maintainers/scripts/gradle-add-version VERSION (adds it here and writes its
# modules/VERSION.json), then `nix build .#gradle."VERSION".dist`.  `upstreamLock`: build it like
# the published distribution (dists/VERSION.json, from scripts/gradle-dist-lock).
{
  "8.14.3".hash = "sha256-fyKRoK9AlZzoURvx3aMK4H1AV8M/KszLQtvo3rTSbUk=";
  "9.8.0".hash = "sha256-5KRHOveEOeA11TZGbUi8etSd7av9Tt6fe7u4TeRQkbQ=";
  "9.8.1".hash = "sha256-WfMmNLPxSW924mK2iFEH56q/P7pBgwBNb/fuZF57ohM=";
  "9.8.2".hash = "sha256-Slf7kTDSMgALWbiw17A0gkhnmNTQqKp1y+cs+djexes=";
  "9.8.2".upstreamLock = ./dists/9.8.2.json;
  "9.8.2".kotlinVersion = "2.4.10";
  "9.8.2".embeddedKotlin = "2.4.10";
  "9.9.0-RC1".hash = "sha256-2H1vXf9WE36zE+DbZkVZSP5bSpzf8nGJmPPwk4fh1Yo=";
}
