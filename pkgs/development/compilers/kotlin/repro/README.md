# Kotlin's published runtime jars, bit for bit

`nix build .#kotlin.repro."2.4.10".check` rebuilds a release's JVM runtime jars from its source tree
with the chain's compilers and compares them with the jars of Maven Central (fetched for that
comparison only, never an input): kotlin-stdlib, kotlin-stdlib-jdk7, kotlin-stdlib-jdk8,
kotlin-script-runtime, kotlin-test.

| release | compiler (upstream's bootstrap) | result |
|---|---|---|
| 2.4.10 | chain 2.4.0 (2.4.0-dev-8449) | all 5 identical |

## How

The release's Gradle build is not run; `scripts/runtime-2.4.sh` calls kotlinc and javac the way its
Gradle tasks do, read off the build scripts:

- kotlinc runs on the toolchain JDK (11) with `-jdk-home` of it; `-no-stdlib -no-reflect`, and the
  multiplatform compilations as `-Xmulti-platform -Xfragments -Xfragment-refines -Xfragment-sources`
  with the source sets' names (commonMain, jvmMain, ...), sources sorted by path.
- The stdlib's flags are the exhaustive lists of `libraries/stdlib/build.gradle.kts` (main, mainJdk7,
  mainJdk8 and compileOnlyDeclarations); KotlinVersion.kt gets the release's version components first
  (prepare/build.version's writeStdlibVersion; scripts/kotlin-version.py).
- jvmMain's Java sources: javac of JDK 8 (`configureJvmToolchain(JDK_1_8)`) with Gradle's options
  (`-g -proc:none -XDuseUnsharedTable=true -sourcepath ""`).
- module-info.java (configureJava9Compilation): JDK 17's javac with `--release 9` (without it javac
  records `requires java.base` with the JDK's version).
- The classpath's org.jetbrains:annotations must not have type-use targets (13.0 upstream; the
  chain's 16.0.3 Java 5 variant): with 24.x's, javac adds RuntimeInvisibleTypeAnnotations to the
  Java classes.
- The jars: Gradle's reproducible Jar (gradle/gradle-jar.py), the roots in the order of the jar
  task's `from`s, LibrariesCommon.manifestAttributes. The build number in Implementation-Version
  (2.4.10-release-377) is a fact of JetBrains' CI, recorded in default.nix.

The chain's own stdlibs (`kotlin."V"`) are built differently (Ant, flags of their own) and do not
match upstream; see NOTES.md.
