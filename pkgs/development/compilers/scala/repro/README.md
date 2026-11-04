# Scala 3.10.0 from source, bit for bit

Goal: rebuild the Maven Central jars of Scala 3.10.0 from source, using only the chain's
compilers (d74, the nonbootstrapped 3.10.0, and s230, scalac 2.13.18), so that they are
**byte-identical** to the published ones.

```sh
nix build .#scala.repro.library    # scala-library-3.10.0.jar
nix build .#scala.repro.compiler   # scala3-interfaces, tasty-core_3, scala3-compiler_3, scala3-library_3
nix build .#scala.repro.check      # all five against Maven Central's (upstream)
nix build .#scala.repro.checkLibrary  # the library alone (deterministic; `check` fails when the
                                     # compiler jar does not come out identical: --rebuild it)
```

By hand (the scripts' work directory is `WORK`, default `./work`):

```sh
export REPRO_ENV=$(nix build --print-out-paths .#scala.repro.env)
scripts/build-library.sh out/scala-library-3.10.0.jar
scripts/build-compiler.sh out
scripts/check.sh $(nix build --print-out-paths .#scala.repro.upstream) out
```

The derivations need the chain up to d74 and s230.  In the sandbox (tested with the d74 and s230
of before 2026-11-04) the library and the four small jars came out identical; in the first
compiler run 6 of its 6552 entries differed (ClosureOptimizer, Comments, ParsedComment: the GC
dependence below).

Upstream's jars (`.#scala.repro.upstream`) are used only for comparison and diagnosis, never as
build inputs. The one exception is the two small replay lists described below. They record outcomes
of upstream's nondeterministic build that cannot be derived from the source.

## Result

`scripts/check.sh` (`.#scala.repro.check`) reports every published jar of the compiler release byte-identical:

| jar | sha256 (prefix) |
|---|---|
| scala-library-3.10.0.jar | b47befb29e02bbc0 |
| scala3-library_3-3.10.0.jar (empty placeholder) | 4daaede24ddfeea0 |
| scala3-interfaces-3.10.0.jar | 2293237c57462efc |
| tasty-core_3-3.10.0.jar | cd8088db4457e846 |
| scala3-compiler_3-3.10.0.jar | 51e241938950723f |

How deterministic each build is:
- `build-library.sh` gave the identical library jar in every run (about 8 runs).
- `build-compiler.sh` gave the identical interfaces, tasty-core and scala3-library jars in every run.
- The compiler jar was identical in 1 of 4 runs. The other runs differed in 3–6 TASTy files
  (plus their classes) because of GC-dependent typing; see "Upstream nondeterminism" below.

## Inputs (all from source)

| what | where |
|---|---|
| scala/scala3 at 25c18aa (tag 3.10.0) | `$SRC`; the Nix fetch, binaries stripped |
| nonbootstrapped compiler (3.10.0 compiled by 3.9.0) | Nix d74 `comp/` (+ `lib0`, `tasty`, `interfaces`, `deps` = ASM 9.10.1, compiler-interface) |
| scalac 2.13.18 | Nix s230 (`out2` + `classes` for scala.tools.asm; `quick/lib` on the class path) |
| scala/scala v2.13.18 `src/library` | identical, file by file, to the scala-library-2.13.18 sources jar |
| scala-js v1.22.0 `ir/{shared/src/main/scala,shared/src/main/scala-3,jvm/src/main/scala}` | identical to scalajs-ir_3-1.22.0-sources.jar (note `_3`: `%%` in a Scala 3 project) |
| JDK 17 (the chain's `jdks.openjdk17`) | upstream's release workflow uses JDK 17; JDK 21 changes constant pools |

## Build (what sbt does, step by step)

- `scripts/build-library.sh OUT.jar`: scala-library-bootstrapped.
  1. `lib.sh`: library/src + src-bootstrapped, compiled by the nonbootstrapped compiler with
     ThisBuild's scalacOptions plus `-opt -opt-inline:**,!java.**` and `-sourcepath`.
     The compiler runs from the source root with relative paths, because TASTy records
     source paths relative to it. It uses `compiler.properties` = `3.10.0-bin-nonbootstrapped`.
     Java is compiled by `javac --release 17`.
  2. `scala2lib.sh`: the scala2-library project. The 2.13.18 sources are compiled by scalac
     2.13.18 with the ThisBuild options minus the Scala 3 ones, plus `-release:17 -sourcepath:… -opt:local`.
     The source paths must be absolute; otherwise there is a cyclic reference on Predef.
  3. `tools/PatchScala2.java`: ScalaLibraryPlugin.manipulateBytecode and
     StripScala2Annotations.patchFile, reimplemented with ASM.
  4. Resources: rootdoc.txt, plus library.properties from `LibraryProperties.content`.
  5. `tools/MkJar.java`: sbt's packaging. The manifest comes first, then the sorted
     directories (STORED), then the sorted files (deflated). Every entry is dated
     2010-01-01 00:00 and the tool runs in UTC.
- `scripts/build-compiler.sh OUTDIR`: interfaces (javac), tasty-core-bootstrapped and
  scala3-compiler-bootstrapped (`compiler.sh`), plus compiler.properties, the manifests
  (`props.py`) and the jars.
  - `compiler.sh` copies the tree to WORK/tree. It writes the shaded scalajs-ir sources to
    the path upstream's TASTy records:
    `compiler/target/scala3-compiler-bootstrapped/scala-3.10.0-bin-nonbootstrapped/src_managed/main/scalajs-ir-src`.
    The shading is sbt's IO.readLines, then Shading.replacePackage on the first package
    line, then IO.writeLines.
  - Options: `-opt -opt-inline:dotty.**` and the three scalajs-ir `-Wconf` options.
  - The JVM uses upstream's `.jvmopts`: `-Xss2m -Xms1024m -Xmx8192m -XX:MaxInlineLevel=35`.

## Upstream nondeterminism (compiler bugs found on the way)

The 3.10.0 build is not reproducible as such. Four sources of nondeterminism showed up:

1. **Scala3InlineInfo (new `-opt` backend)**
   - Mechanism:
     - MoveStatics groups a package's classes with `groupBy(name)` over a HashMap whose keys are
       `Name`s, and `Name.hashCode` is `System.identityHashCode`, so the class order in each
       compilation unit is random.
     - That order decides where a class's ClassBType is first created.
     - If it is first created from the GenericSignatures callback, that callback's context is at
       `flattenPhase.next`, i.e. before LambdaLift, so the InlineInfo misses the lambda bodies
       (`$anonfun`, `$anonfun$adapted`).
   - Fix: build the InlineInfo at genBCode.
   - Replay: `scripts/inlineinfo-replay*.txt` lists the classes upstream got stale (8 in the
     library, 2 in the compiler). Every other class gets the fresh InlineInfo.
2. **Typing depends on GC**
   - Mechanism: hash-consed types live in a WeakHashSet (`Uniques`). When an unreferenced type
     is collected and later re-created, Java-interop results (flexible types under
     `-Yexplicit-nulls`) can come out differently: a `String` instead of a flexible `String?`
     in a pattern type or an inferred type argument.
   - Observed with JDK 17:
     - With Epsilon GC (no collection) or a WeakHashSet that holds its entries strongly
       (`overlay.sh`, the default unless `NO_STRONG=1`), runs are deterministic, but that
       outcome is not upstream's.
     - With upstream's heap options the outcome usually matches, and only 0–6 of the
       compiler's classes flip from run to run.
   - Not replayed: the mechanism inside the type comparer/typer is not pinned down yet.
     Affected so far: Comments, Completion, ParsedComment, ClassPathFactory, PropertiesTrait,
     scripting/Util, QuotesImpl, ClosureOptimizer, ExtractAPICollector (compiler), and
     Duration, SystemProperties, PropertiesTrait (library, stable under -Xmx6g).
3. **Wildcard export order**
   - Mechanism: `export X.*` forwards `memberNames`, a `Set[Name]`, so the order follows
     identity hashes. Upstream's hashes come from sbt's long-running JVM, which can't be replayed.
   - Replay: `scripts/export-order-compiler.txt` gives the order for Signature (`export MatchDegree._`)
     and BestEffortTastyFormat (`export TastyFormat.*`). It was read off upstream's
     TASTy/class files.
4. **Parallel pickling**: suspected, but never shown to change any output.

`scripts/overlay.sh` builds the diagnostic/replay overlay. These are classes put in front of
the unmodified d74 compiler:
- BTypeLoader: InlineInfo replay.
- Namer: export-order replay.
- WeakHashSet: strong entries; optional.
- Pickler: sequential; optional.

The default is `WORK/overlay-gc` (`NO_STRONG=1 PARALLEL_PICKLING=1`): replay only, normal GC.

## Tools

- `scripts/compare.py JAR DIR`: entry-by-entry comparison.
- `scripts/libcompare.py JAR DIR SRC`: the same, without the entries the plugin replaces.
- `scripts/inlineinfo.py CLASS…`: decodes Scala3InlineInfo.
- `scripts/export-order.py PRINT`: the EXPORTED definitions from a TastyPrinter listing.
- Our 3.10 TastyPrinter crashes on Signature.tasty ("Expected a 31-bit nat"), so its
  export order was read from the method order in `Signature$.class`.
