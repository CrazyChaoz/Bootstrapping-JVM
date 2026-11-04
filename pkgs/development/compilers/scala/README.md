# Scala from source

Scala 2.13.18 and Scala 3.10.0, built without any Scala binary.  The chain starts with a
compiler for Scala that was in the scala/scala tree in 2004, written in PiCo (Java with
algebraic data types), and PiCo (`../pico`), which compiles it, as the tree's Makefile did.
From there every stage is a commit of scala/scala (or, later, scala/scala3) compiled by the
stage before it:

    st1 (2004-02, the boot compiler "scalacboot", by PiCo)
     → Scala 1.x (v111 … s10, 2004-2005)
     → n0, the first Scala 2 compiler, nsc (2005-12)
     → s11 … s230: 2.0.0, 2.7, 2.8, … 2.11.0, 2.12.0, 2.13.0 … 2.13.18
     → d0 … d74: dotty (2019-04, built by 2.12.8) … Scala 3.10.0

```sh
nix build .#scala.\"2.13.18\"        # = .#scala.stages.s230
nix build .#scala.\"3.10.0\"         # = .#scala.latest = .#scala.dotty.stages.d74
nix build .#scala.stages.s52         # 2.7.7 (a dead end: a release branch)
nix build .#scala.all                # every stage, the dead ends included
nix build .#scala.repro.check        # the published 3.10.0 jars, bit for bit (repro/README.md)
```

Every stage's compiler compiles and runs a small program (`tests/`) as its install check.

The Java sources of the trees are compiled the way their own builds compiled them: by PiCo up
to 2006-06 (s16: the Makefile until 2005, then Ant's `<pico>` task, both with `-scala-hack`,
which allows `scala.Int.coerce()` to be overloaded by its result type), by javac from then on.

## Layout

| Path | What |
| --- | --- |
| `chain/scala2.txt` | the Scala 2 chain: one line per stage (commit, previous stage, mode), grouped by generation |
| `chain/dotty.txt` | the Scala 3 chain: one line per stage (commit, previous stage, version, Scala 2 library) |
| `default.nix` | the Scala 2 stages; `dotty.nix` the Scala 3 stages, `generations.nix` how a stage is built, `deps.nix` jline, jansi, scala-asm, java-diff-utils from source; `chain.nix` and `dotty-chain.nix` are generated |
| `builders/` | the stage builders: `boot.sh` (st1), `scala1.sh` (Scala 1.x), `nsc0.sh` (n0), `scala2.sh` (Scala 2), `dotty.sh` (Scala 3); `common.sh` and the source patches every tree of a builder gets (`scala1-patches.sh`, `nsc-patches.sh`) |
| `tools/` | what the builders run: `jdk-api-view.py` (the Java class library as of 1.4/1.5/1.6), `scala-unnest.py`, `scala-pickle-rename.py`, `classfile.py` (class files for these two), `dotty-*` (the inputs of a dotty build) |
| `tests/` | the smoke tests |
| `repro/` | Scala 3.10.0's Maven Central jars rebuilt byte-identical from d74 and s230, and the upstream nondeterminism found on the way; see its `README.md` |
| `patches/` | the hooks of single generations, and the bridges' scripts |
| `scripts/` | `scala-chain` and `dotty-nix`, which generate `chain.nix` and `dotty-chain.nix` from the chain files, and the prototype that found the stages, building commits outside Nix (see below) |

## Stages, modes and generations

A line of `chain/scala2.txt` is `NAME COMMIT PREV MODE`, and its file header explains the modes.
`normal` builds the library first and then the compiler.  The others are for upstream flag
days, where the new tree no longer builds with an old compiler:

- `cf` builds the compiler first.
- `fresh` builds the library without the previous one behind it.
- `bridge:…` and `bridge-script:…` build a tree from a few files of a later commit.  These
  stand in for the unpublished intermediate compilers that upstream built its reference
  compilers from.

The stages are grouped under `generation NAME` lines.  A generation is a builder script plus
settings for it, an attribute of `generations.nix`.  The settings are environment
variables, and `builders/scala2.sh` explains them in its header.  Most generations follow a
change of the upstream build and hold until the next one, for example:

- the library's package objects (2009-10)
- the Java 6 API (2012-04)
- sbt's order of Java and Scala sources (2016-08)

A workaround that only one or two stages need is a generation of its own, named after its date
and cause (`2010-11-serializable`, `2012-04-macros`, …).  Its hooks are in `patches/`:

| Hook directory | Applied to |
| --- | --- |
| `source/` | the whole tree |
| `locker/` | the first compiler and library, built by the previous stage |
| `fallback/` | the previous library, which locker's library builds against |
| `compiler-first/` | the library sources that a compiler-first compiler needs |
| `bridges/` | a bridge tree |

The dotty stages have a single builder.  Each dotty tree names its reference compiler, the stage
before it, and the Scala 2 release whose library it uses.

## Inputs

- The Scala trees are GitHub's archives of the commits.  Everything binary is removed from them
  (`lib/*.jar`, among other things).
- The external Java inputs are built from source:
  - FJBG and the MSIL reader, from the scala/scala tree of 2009
  - jline 1.0
  - Scala's jline of 2009
  - jansi 1.4
  - scala-asm and ASM
  - java-diff-utils
  - zinc's compiler interface and sbt's util interface
  - jline 3
  - the Scala.js IR
- The chain's OpenJDK 8 runs the old compilers, whose class file readers and run-time libraries
  want a Java 8 class library.
- OpenJDK 21 compiles the Java parts (`--release 8`, later `--release 17`).
- The old class file readers see JDK 8's class library through a view of the Java API they knew
  (`tools/jdk-api-view.py`).
- The MSIL (.NET) backend is stubbed in every stage.

## The prototype (`scripts/`)

New stages were found by building candidate commits outside Nix, in a work directory
(`SCALA_WORK`, default `/tmp/sc`).  The prototype uses this checkout's builders and the other
inputs of the Nix builds (`nix build .#scala.builderEnv`).  `scripts/env.sh` describes the work
directory.  The scripts are:

| Script | What it does |
| --- | --- |
| `try.sh NAME COMMIT PREV` | builds one commit with the builder and settings of `GENERATION` (default: the last generation) |
| `auto.sh` | tries the modes in turn and runs the smoke test |
| `bisect.sh` | finds the farthest commit that the last stage builds, probing several commits in parallel |
| `climb.sh PREV PREVCOMMIT TARGET` | repeats bisect up to `TARGET`, climbing around merges that do not build, and records the stages in `chain.txt` |
| `bridge.sh` | builds a bridge |
| `diag.sh` | shows the first errors of the next commit |
| `dclimb.sh` | builds the dotty chain |
| `dotty-chain` | lists the dotty chain from the trees' reference compilers |

The stages found go into `chain/scala2.txt`, into a new generation if they needed anything new.
Then `scripts/scala-chain` regenerates `chain.nix`, adding the hashes of new trees.
