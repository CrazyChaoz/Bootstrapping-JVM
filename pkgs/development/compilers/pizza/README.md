# Pizza from source

[Pizza](https://pizzacompiler.sourceforge.net/) (Martin Odersky and Philip Wadler, 1996) is
Java with generics, function types and closures, and algebraic data types.  Its compiler is
written in Pizza.  The source releases came with a compiler binary to build them
(`bootstrap/pizzaself.jar` in 1.0 and 1.1) or with none at all (0.40).  Here no Pizza binary
is used:

    boot  (Pizza 0.40, translated to Java by tools/pizza2java.py, compiled by javac)
     → 0.40 → 1.0 → 1.1

```sh
nix build .#pizza.\"1.1\"       # = .#pizza.latest; result/bin/pizzac
nix build .#pizza.\"0.40\"      # the release the boot compiler is translated from
nix build .#pizza.boot          # the boot compiler itself
```

Each release is compiled three times (`builders/stage.sh`):

1. by the compiler before it
2. by the result of step 1
3. by the result of step 2

The class files of steps 2 and 3 must be the same, or the build fails.  The result of step 2
is installed (`share/java/pizza.jar`, `bin/pizzac`).  Every release's compiler then compiles
and runs `tests/Hello.pizza`.

In fact all three steps give the same class files for every release, including 0.40 built
by the boot compiler.  So the translated boot compiler compiles Pizza 0.40 exactly as
Pizza 0.40 compiles itself.

## The boot compiler

`tools/pizza2java.py` translates Pizza to Java.  It is also the translator of PiCo's boot
compiler (`../pico`), whose few extra needs are listed at its top.  For the Pizza that the
Pizza compiler is written in it does this:

| Pizza feature | Becomes in Java |
| --- | --- |
| generic algebraic types (`class List<A> { case Nil; case Cons(A head, List<A> tail); }`) | case classes that take the class's type parameters |
| a case named like its class (`class Pair<A, B> { case Pair(A fst, B snd); }`) | that class itself |
| type variables in patterns (`case <B> Cons(B y, List<B> ys)`) | erased to `Object` |
| function types `(A, B) throws E -> R` | interfaces `pizza0.FunN<…>` / `pizza0.FunNX<…>` (primitive types boxed, `void` as `Void`) |
| closures `fun(int x)->String { … }` | lambdas, cast to their `FunN` |
| calls of function-typed variables | `f.apply(…)` |
| a method used as a value | a method reference |
| a local variable that a closure assigns (Pizza passes it by reference) | a cell, `pizza0.Ref` |
| primitive type arguments (`Cell<boolean>`) | boxed |

The translator works on tokens and knows no types.  It covers what the compiler's sources
use, and there is one exception.  In `Gen.typecode`, `type.tag` names the method `tag()` as
a closure value, and the translator cannot tell that from a field read.  `builders/boot.sh`
makes it a method reference with `regex-edit`.

## Patches

`patches/classreader-*.patch` let every release read the class files of JDK 8's
`rt.jar`.  The compilers run on the chain's OpenJDK 8, because JDK 9 and later have no
`rt.jar`.  The patches:

- accept class file versions up to 52.0 (0.40 and 1.0 only took 45.3)
- skip the constant pool entries of Java 7+
- mask the access flags of Java 5+
- drop bridge and synthetic methods, as Java 1.4 did not have them

## Inputs

- The three source archives from SourceForge.  The jars and class files they contain are
  deleted when they are fetched: the bootstrap compilers, the Ant task, junit and the test
  data.
- The chain's OpenJDK 8, for javac and to run the compilers.

The Ant task (`net.sf.pizzacompiler.ant`) is not built, and the upstream test suite (junit)
is not run.  Pizza 1.1 reports itself as `v1.0g`, because its sources were not updated for
the release.
