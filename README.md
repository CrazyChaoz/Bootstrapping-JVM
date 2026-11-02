# Bootstrapping Gradle, Kotlin, a JDK and Scala from source with Nix

Goal: build recent Gradle, Kotlin and Scala without any prebuilt JDK, Kotlin,
Scala, Gradle, IntelliJ or Maven-Central binaries, starting from the
(bootstrappable) Nix stdenv.

## Layout

| Path | What |
| --- | --- |
| `flake.nix` | pinned nixpkgs, exposes everything as `legacyPackages` |
| `nix/default.nix` | the scope tying the stages together (`jdk8`/`jdk11`/`jdk21` come from `nix/jdk`; `gradleFor` instantiates a Gradle version) |
| `nix/jdk/` | the JDK chain: jikes → GNU Classpath/JamVM → ecj → IcedTea 7 → OpenJDK 8 … 21 (`jdks.openjdkNN`); Guix-derived recipes for 9, 10 and 12–20 |
| `nix/lib/mk-jar.nix` | `mkJar`: compile a source tree with javac into a jar (like Guix' `ant-build-system #:jar-name`) |
| `nix/lib/fetch-*.nix` | source fetchers that strip shipped binaries (`*.jar`, `*.class`, …) |
| `nix/java/` | Ant, ANTLR (2 … tunnelvisionlabs 4.7.4), ICU data, Groovy 3.0.5, protobuf and ~30 third party Java libraries, from source |
| `nix/intellij/` | IntelliJ SDK modules (util, core, jps-model, javac2, …) for SDKs 139 … 193, 201+ |
| `nix/kotlin/` | the Kotlin chain 0.6.786 → 1.1 → 1.2 → 1.3 → … → 2.4.0 |
| `nix/gradle/` | Gradle 9.8.0 and 8.14.3: ~80 third party libs, Groovy 4.0.33/3.0.24, Kotlin plugins/embeddable jars, every Gradle module compiled directly by javac/kotlinc, distribution assembly |
| `nix/scala/` | the Scala chain (2004 Java scalac → 1.x → nsc → 2.13.18, and dotty → 3.10.0) |
| `scala/` | the Scala chain records (`chain/`), stage builders, their tools and tests, and the prototype that found the stages; see `scala/README.md` |
| `patches/tarcv/` | patches from [TarCV/kotlin-guix](https://github.com/TarCV/kotlin-guix) (Apache-2.0) |
| `patches/guix/` | patches from Guix for the JDK, ANTLR and Groovy recipes |
| `patches/own/` | our patches: IntelliJ SDK ports, Ant runtime targets for Kotlin 1.1.x–1.4 |
| `patches/scala/` | the hooks of the Scala generations and the scripts of the bridge stages |
| `tools/` | hash prefetch/fix helpers, module-graph extraction (`gradle-modules`, `kotlin-modules`, `intellij-modules`), the generators of the Scala chains' Nix files (`scala-chain`, `dotty-nix`) |

## Usage

```sh
nix build .#jdks.openjdk21                  # JDK 21, from jikes up
nix build .#kotlin."0.6.786"                # first Kotlin stage, pure Java
nix build .#kotlin."2.4.0"                  # Kotlin 2.4.0 (many stages later)
nix build .#gradleDist                      # Gradle 9.8.0 (= .#gradle."9.8.0".dist)
nix build .#gradle."8.14.3".dist            # Gradle 8.14.3
nix build .#scala.\"2.13.18\"                # Scala 2.13.18, from the 2004 Java scalac
nix build .#scala.\"3.10.0\"                 # Scala 3.10.0 (= .#scala.latest)
```

Smoke test of the Gradle build:
`JAVA_HOME=$(nix build --no-link --print-out-paths .#jdks.openjdk21) result/bin/gradle --offline --no-daemon build`

## Status

See `NOTES.md` for the detailed log.

* **JDK**: built entirely from source.  `nix/jdk` provides OpenJDK 8–21, boot-strapped
  from jikes + GNU Classpath + JamVM → ecj → IcedTea 7 (nixpkgs' OpenJDK recipe is
  reused for 8, 11, 17 and 21, fed with our own boot JDK).  `jdk8`, `jdk11` and
  `jdk21` in `nix/default.nix` all point into this chain; no temurin seed is used.
* **Kotlin**: 0.6.786 → 2.4.0, every version compiled by the previous one
  (Ant-based up to 1.2.x, then module-wise kotlinc/javac).  Built and
  smoke-tested up to 2.4.0 (K2 enabled from 2.1.0).  Note `kotlin.latest` is
  still 1.1.2-5; use `kotlin."2.4.0"`.
* **Gradle**: 9.8.0 and 8.14.3 distributions build and run (Groovy and Kotlin DSL
  `java`/`application` builds, offline, `--no-daemon`).  Not done: AWS/GCS/maven
  modules (`resources-s3`, `resources-gcs`, `build-init`), JNI libraries, and
  Scala compilation (the Zinc worker is stubbed).
* **Scala**: 2.13.18 and 3.10.0.  A chain of scala/scala commits (Java scalac of 2004 →
  Scala 1.x → nsc → 2.x, the first stage translated from Pizza to Java by
  `scala/tools/pizza2java.py`), each stage compiled by the previous one, reaches 2.13.18;
  from 2.12.8 a chain of scala/scala3 commits, each built by the reference compiler it
  names, reaches 3.10.0.  The MSIL backend is stubbed; jline, jansi, scala-asm, zinc's
  interfaces and the other Java inputs are built from source.
* Ant, all Java dependencies, IntelliJ SDK modules: built from source.
* ICU's data (`icudata.jar`, used by icu4j to generate ANTLR 4's Unicode tables)
  is rebuilt from the Unicode Character Database text files (`nix/java/icu`);
  the prebuilt data in ICU's sources is deleted at fetch time.
* Source edits that `substituteInPlace` cannot express are done with `regex-edit`
  (`nix/lib/regex-edit.py`, a short Python script that fails when an edit no longer
  matches) or small inline Python; the recipes themselves use no perl.  (nixpkgs' stdenv
  and glibc still bring perl and Python into every build closure.)

## Credits

The bootstrap path for Kotlin 1.1.2-5 is the work of Emmanuel Bourg
([ebourg/kotlin-bootstrapping](https://github.com/ebourg/kotlin-bootstrapping)),
Julien Lepiller
([guix-android](https://framagit.org/tyreunom/guix-android)) and TarCV
([kotlin-guix](https://github.com/TarCV/kotlin-guix)).  This repository ports
it to Nix.
