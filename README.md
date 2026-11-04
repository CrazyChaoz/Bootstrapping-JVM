# Bootstrapping Gradle, Kotlin, a JDK, Scala, Pizza and PiCo from source with Nix

Goal: build recent Gradle, Kotlin and Scala, and the Pizza and PiCo compilers, without any
prebuilt JDK, Kotlin, Scala, Pizza, PiCo, Gradle, IntelliJ or Maven-Central binaries,
starting from the (bootstrappable) Nix stdenv.

## Layout

The tree follows nixpkgs: the package set in `pkgs/top-level/all-packages.nix`, the build
helpers in `pkgs/build-support/`, and each package in a directory of its own under
`pkgs/development/`, with its patches, build scripts and maintenance scripts next to it.
`docs/scala-dependency-graph.md` and `docs/kotlin-dependency-graph.md` draw the two chains,
with the JDK chain, PiCo, IntelliJ SDKs and ANTLR they are built with (generated:
`maintainers/scripts/dep-graph docs`).

| Path | What |
| --- | --- |
| `flake.nix` | pinned nixpkgs, exposes everything as `legacyPackages` |
| `pkgs/top-level/all-packages.nix` | the scope tying the stages together (`jdk8`/`jdk11`/`jdk21` come from the OpenJDK chain; `gradleFor` instantiates a Gradle version) |
| `pkgs/build-support/java/mk-jar.nix` | `mkJar`: compile a source tree with javac into a jar (like Guix' `ant-build-system #:jar-name`) |
| `pkgs/build-support/fetch{intellij,kotlin}/` | source fetchers that strip shipped binaries (`*.jar`, `*.class`, …) |
| `pkgs/build-support/regex-edit/` | `regex-edit`, the source editor of the recipes |
| `pkgs/development/compilers/openjdk/` | the JDK chain: jikes → GNU Classpath/JamVM → ecj → IcedTea 7 → OpenJDK 8 … 21 (`jdks.openjdkNN`); Guix-derived recipes for 9, 10 and 12–20 |
| `pkgs/development/compilers/kotlin/` | the Kotlin chain 0.6.786 → 1.1 → 1.2 → 1.3 → … → 2.4.0 |
| `pkgs/development/compilers/scala/` | the Scala chain (the 2004 boot compiler → 1.x → nsc → 2.13.18, and dotty → 3.10.0); see its `README.md` |
| `pkgs/development/compilers/pizza/` | the Pizza compiler: boot (0.40 translated to Java) → 0.40 → 1.0 → 1.1; standalone, nothing depends on it; see its `README.md` |
| `pkgs/development/compilers/pico/` | PiCo, the compiler of Scala's Java sources until 2006: JCup → boot (JaCo translated to Java) → pico; see its `README.md` |
| `pkgs/development/java-modules/` | ~30 third party Java libraries, protobuf, ICU data; `intellij-sdk/`: IntelliJ SDK modules (util, core, jps-model, javac2, …) for SDKs 139 … 193, 201+ |
| `pkgs/development/tools/build-managers/apache-ant/` | Ant |
| `pkgs/development/tools/build-managers/gradle/` | Gradle 9.8.0 and 8.14.3: ~80 third party libs, Groovy 4.0.33/3.0.24, Kotlin plugins/embeddable jars, every Gradle module compiled directly by javac/kotlinc, distribution assembly |
| `pkgs/development/tools/parsing/antlr/` | ANTLR 2 … tunnelvisionlabs 4.7.4 |
| `pkgs/development/interpreters/groovy/` | Groovy 3.0.5 |
| `maintainers/scripts/` | hash prefetch/fix helpers (`prefetch`, `fix-hashes`, …) and patch porting (`port-patch`, `make-patch`) |

Patches from elsewhere carry their license next to them: `LICENSE-TarCV-kotlin-guix.txt`
([TarCV/kotlin-guix](https://github.com/TarCV/kotlin-guix), Apache-2.0) and `COPYING-guix`
(Guix, GPL-3.0).  The other patches are this repository's.

## Usage

```sh
nix build .#jdks.openjdk21                  # JDK 21, from jikes up
nix build .#kotlin."0.6.786"                # first Kotlin stage, pure Java
nix build .#kotlin."2.4.0"                  # Kotlin 2.4.0 (many stages later)
nix build .#gradleDist                      # Gradle 9.8.0 (= .#gradle."9.8.0".dist)
nix build .#gradle."8.14.3".dist            # Gradle 8.14.3
nix build .#scala.\"2.13.18\"                # Scala 2.13.18, from the 2004 Java scalac
nix build .#scala.\"3.10.0\"                 # Scala 3.10.0 (= .#scala.latest)
nix build .#scala.repro.check              # Scala 3.10.0's published jars rebuilt bit for bit, checked
nix build .#pizza.\"1.1\"                    # the Pizza compiler 1.1 (= .#pizza.latest)
nix build .#pico.pico                       # PiCo (= .#pico.latest)
```

Smoke test of the Gradle build:
`JAVA_HOME=$(nix build --no-link --print-out-paths .#jdks.openjdk21) result/bin/gradle --offline --no-daemon build`

## Status

See `NOTES.md` for the detailed log.

* **JDK**: built entirely from source.  The OpenJDK chain provides OpenJDK 8–21, boot-strapped
  from jikes + GNU Classpath + JamVM → ecj → IcedTea 7 (nixpkgs' OpenJDK recipe is
  reused for 8, 11, 17 and 21, fed with our own boot JDK).  `jdk8`, `jdk11` and
  `jdk21` in `all-packages.nix` all point into this chain; no temurin seed is used.
* **Kotlin**: 0.6.786 → 2.4.0, every version compiled by the previous one
  (Ant-based up to 1.2.x, then module-wise kotlinc/javac).  Built and
  smoke-tested up to 2.4.0 (K2 enabled from 2.1.0).  Note `kotlin.latest` is
  still 1.1.2-5; use `kotlin."2.4.0"`.
* **Gradle**: 9.8.0 and 8.14.3 distributions build and run (Groovy and Kotlin DSL
  `java`/`application` builds, offline, `--no-daemon`).  Not done: AWS/GCS/maven
  modules (`resources-s3`, `resources-gcs`, `build-init`), JNI libraries, and
  Scala compilation (the Zinc worker is stubbed).
* **Scala**: 2.13.18 and 3.10.0.  A chain of scala/scala commits (the boot compiler of
  2004 → Scala 1.x → nsc → 2.x; their Java sources compiled by PiCo until 2006-06, as
  Scala's own builds did), each stage compiled by the previous one, reaches 2.13.18;
  from 2.12.8 a chain of scala/scala3 commits, each built by the reference compiler it
  names, reaches 3.10.0.  The MSIL backend is stubbed; jline, jansi, scala-asm, zinc's
  interfaces and the other Java inputs are built from source.  From the chain's compilers,
  the five jars of the 3.10.0 release on Maven Central are rebuilt byte for byte
  (`compilers/scala/repro`; the compiler jar in about 1 of 4 runs: upstream's typing
  depends on GC timing).
* **Pizza**: 0.40, 1.0 and 1.1.  The Pizza compiler is written in Pizza; its 0.40
  sources, translated to Java by its `tools/pizza2java.py` and compiled by javac,
  compile 0.40, which compiles 1.0, which compiles 1.1.  Each release then compiles
  itself twice, and the two results must be the same class files.  (They are
  also the same as the class files the previous compiler produced.)  Standalone:
  nothing else in the repository uses it.
* **PiCo**: JaCo's Pizza front end of 2003, which Scala's boot compiler of 2004 was written for.
  A boot translator (to Java) and javac make a boot compiler from its sources, which compiles PiCo,
  and PiCo compiles itself twice (same class files).  JCup's parse tables are made by a stand-in
  for JCup's own parser and are the same bytes as the shipped ones; no jar or table of the
  repository is used.  The Scala chain compiles its Java sources with it.
* Ant, all Java dependencies, IntelliJ SDK modules: built from source.
* ICU's data (`icudata.jar`, used by icu4j to generate ANTLR 4's Unicode tables)
  is rebuilt from the Unicode Character Database text files (`java-modules/icu`);
  the prebuilt data in ICU's sources is deleted at fetch time.
* Source edits that `substituteInPlace` cannot express are done with `regex-edit`
  (`pkgs/build-support/regex-edit`, a short Python script that fails when an edit no longer
  matches) or small inline Python; the recipes themselves use no perl.  (nixpkgs' stdenv
  and glibc still bring perl and Python into every build closure.)

## Credits

The bootstrap path for Kotlin 1.1.2-5 is the work of Emmanuel Bourg
([ebourg/kotlin-bootstrapping](https://github.com/ebourg/kotlin-bootstrapping)),
Julien Lepiller
([guix-android](https://framagit.org/tyreunom/guix-android)) and TarCV
([kotlin-guix](https://github.com/TarCV/kotlin-guix)).  This repository ports
it to Nix.
