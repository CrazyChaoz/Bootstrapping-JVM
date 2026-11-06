# Kotlin's published runtime jars, bit for bit

`nix build .#kotlin.repro."2.4.10".check` rebuilds a release's JVM runtime jars from its source tree
with the chain's compilers and compares them with the jars of Maven Central (fetched for that
comparison only, never an input): kotlin-stdlib, kotlin-stdlib-jdk7, kotlin-stdlib-jdk8,
kotlin-script-runtime, kotlin-test.

| release | compiler (upstream's bootstrap) | result |
|---|---|---|
| 2.2.0 | chain 2.2.0 (2.2.0-dev-15683) | 3 identical; kotlin-stdlib (26 of 1033) and kotlin-test (1 of 77) differ, see below |
| 2.3.0 | chain 2.3.0 (2.3.0-Beta2-130) | 3 identical; kotlin-stdlib (51 of 1041 entries) and kotlin-test (10 of 77) differ, see below |
| 2.4.0 | chain 2.4.0 (2.4.0-dev-8449) | all 5 identical |
| 2.4.10 | chain 2.4.0 (2.4.0-dev-8449) | all 5 identical |

`check` fails unless all are identical; `runtime` builds the jars alone.

## 2.2.0: open

- The stdlib's 26 classes: around inlined calls, ours keeps an argument in a temporary local
  (`key$iv` where upstream passes the caller's parameter on, `key$iv$iv` for `key$iv`), so the
  locals, the code and the constant pools shift.
- kotlin-test's AssertionsKt__AssertionsKt: its metadata (d1) differs.

Not yet known whether this is upstream's bootstrap compiler (2.2.0-dev-15683) against the 2.2.0
release, as for 2.3.0, or the chain's 2.2.0 behaving unlike the release.

## 2.3.0: the bootstrap compiler's

Upstream compiled 2.3.0's runtime with 2.3.0-Beta2-130, and what remains comes from that
compiler's behaviour, which the 2.3.0 release (the chain's) no longer has:

- Parameters and locals of inline-class types in inline functions and lambdas are named
  `$v$c$kotlin-UInt$-this$0` (756 such names in the stdlib); the release's compiler (and 2.4's,
  matching 2.4's published jars) writes the plain names (`arg0`, `other`, `it`). The string is
  nowhere in 2.3.0's tree. All of kotlin-test's differences and 50 of the stdlib's are this.
- `SafeContinuation.Companion.RESULT`'s metadata: the AtomicReferenceFieldUpdater's second type
  argument is `Any?` upstream, the flexible `Any!` with the release's compiler.

Matching them needs 2.3.0-Beta2 in the chain.

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
