# PiCo from source

PiCo is the Pizza front end of [JaCo](https://github.com/objecthub/jaco), Matthias Zenger's
extensible Java compiler (the 2003 sources, published in 2023).  It is the compiler that Scala's
boot compiler of 2004 was written for (`PICO ?= pico`, `-make -source 1.4` in that tree's
`Makefile.config`), and it is written in PiCo itself.  JaCo's repository ships three compiler jars,
JCup's parse tables and the tables of its two parsers; none is used here.

```sh
nix build .#pico.pico         # = .#pico.latest; result/bin/pico
nix build .#pico.jcup         # the parser generator
nix build .#pico.boot         # the first PiCo
```

## Chain

| Step | What | Where |
| --- | --- | --- |
| `src` | JaCo's `sources/` (framework, java, pizza, jcup) without jars, tables and the other extensions (whose tests come with OCaml and SPARC objects) | `default.nix` |
| `patched` | its class file reader reads the class files of Java 8 (pool tags of Java 7+, flags of Java 5+, synthetic methods) | `patches/classreader.patch` |
| `jcup` | the parser generator, with tables of its own | `builders/jcup.sh` |
| `parsers` | the two parsers made from `Grammar.cup`; the generated sources shipped are overwritten | `default.nix` |
| `boot` | the sources translated to Java by `tools/pico2java.py` and compiled by javac | `builders/boot.sh` |
| `pico` | compiled by `boot`, then by itself twice; the last two are the same class files | `builders/stage.sh` |

## JCup's tables

JCup reads grammars with a parser that was made by JCup from `jcup/parser.cup`, so it needs
tables to make tables.  `jcup-bootstrap/parser.java` stands in for that parser: it reads the
symbol declarations and productions of a specification without precedence (which `parser.cup`
is), and builds them with the calls that the real parser's actions make.  The unchanged
`jcup.Main` then writes the tables.  `jcup.sh` compiles JCup with them and has it make its
tables again; they must be the same.

The check against what the repository ships: the tables made this way for `parser.cup`,
`java/grammar/Grammar.cup` and `pizza/grammar/Grammar.cup` are the same bytes as the shipped
ones, and the parsers differ from the shipped sources in white space only.

## Hacks

- JCup's shipped `parser.java`, the generated parser of its own specification language, is used
  as source.  It is text with the actions in it; only its tables were binary.
- The boot translator (`tools/pico2java.py`) works on tokens and knows only what JaCo's
  sources use: algebraic cases (also those a type extension adds: `PizzaTree` adds `CaseDecl`
  to `Tree`), pattern switches, `enum` and `assert` as names.  It began as the boot translator
  of the Pizza chain (`../pizza`), cut down to
  what JaCo needs; its translation of JaCo stayed the same bytes.  The Pizza chain
  (`../pizza`) keeps its own full `pizza2java.py`; neither uses the other's files.
- Not built: the Ant task.
- The compiler exits with status 0 after errors; `builders/common.sh` looks for them.
- The compilers run on the chain's OpenJDK 8 (they read `rt.jar`).
- The LICENSE file of the repository is Apache-2.0; its COPYRIGHT file (1997-2002) allows
  research and teaching use only.

## Scala

The Scala chain (`../scala`) compiles its Java sources with PiCo, as Scala's builds did until
2006-06: the boot compiler of 2004 (`st1`), the Java parts of Scala 1.x and of the first
Scala 2 trees, with the flags of their builds (`-source 1.4`, `-scala-hack`).  Before, the
chain translated them to Java (a translator of its own and a post-processor for PiCo's class
file attributes).  The library and compiler that `st1` compiles (`lib2`, `sc2`) are the same
either way, but for the numbers in generated names (`Set$$anon$49`, `loop$1`), the order of
members in a class file and the type of a constant case's static field (PiCo: `Tree.Empty` is
a `Tree$$Var`).  See `NOTES.md`.
