# Bootstrapping Kotlin (and eventually Gradle) from source with Nix

Goal: build recent Kotlin and Gradle without any prebuilt Kotlin, Gradle,
IntelliJ or Maven-Central binaries, starting from the (bootstrappable) Nix
stdenv.

## Layout

| Path | What |
| --- | --- |
| `flake.nix` | pinned nixpkgs, exposes everything as `legacyPackages` |
| `nix/default.nix` | the scope tying the stages together |
| `nix/lib/mk-jar.nix` | `mkJar`: compile a source tree with javac into a jar (like Guix' `ant-build-system #:jar-name`) |
| `nix/lib/fetch-*.nix` | source fetchers that strip shipped binaries (`*.jar`, `*.class`, …) |
| `nix/java/` | Ant and ~30 third party Java libraries, from source |
| `nix/intellij/` | IntelliJ SDK modules (util, core, jps-model, javac2) for SDKs 139/141/143/172 |
| `nix/kotlin/` | the Kotlin chain 0.6.786 → 1.1.2-5 |
| `patches/tarcv/` | patches from [TarCV/kotlin-guix](https://github.com/TarCV/kotlin-guix) (Apache-2.0) |
| `tools/` | hash prefetch / fix helpers |

## Usage

```sh
nix build .#kotlin."0.6.786"      # first stage, pure Java
nix build .#kotlin.latest         # 1.1.2-5, 71 stages later
nix build .#intellij.\"172\".core # an IntelliJ core jar built from source
```

## Status

See `NOTES.md` for the detailed log.

* Ant, all Java dependencies, IntelliJ SDK modules: built from source.
* Kotlin 0.6.786 → 1.1.2-5: ported from TarCV/kotlin-guix.
* JDK: **still nixpkgs' `openjdk8`**, which nixpkgs builds from source but
  seeds with a temurin binary.  To be replaced by a jamvm/GNU Classpath →
  icedtea chain (as in Guix).
* Beyond Kotlin 1.1.x and Gradle: not done yet (see NOTES.md for the plan).

## Credits

The bootstrap path is the work of Emmanuel Bourg
([ebourg/kotlin-bootstrapping](https://github.com/ebourg/kotlin-bootstrapping)),
Julien Lepiller
([guix-android](https://framagit.org/tyreunom/guix-android)) and TarCV
([kotlin-guix](https://github.com/TarCV/kotlin-guix)).  This repository ports
it to Nix.
