# The generations of the Scala chain: how its stages are built.
#
# A generation is a builder script (builders/) with settings for it (`env`, described at
# the top of the script), shared by consecutive stages of chain/scala2.txt.  Most
# generations follow a change of the upstream build (a new library layout, a new Java API, a
# new way to compile the library) and hold until the next one; a workaround that only one or
# two stages need is a generation of its own, right where those stages are in the chain.
#
# Hooks (FALLBACK_PATCH, ...) are scripts of patches/.
{ patches }:

let
  # FALLBACK_DROP: classes of the previous library left out of the fallback of locker's
  # library, where they would shadow or clash with what the new library has instead
  drop = builtins.concatStringsSep ",";
  valueClasses = map (t: "scala/runtime/${t}") [
    "Boolean"
    "Byte"
    "Short"
    "Char"
    "Int"
    "Long"
    "Float"
    "Double"
    "Unit"
  ];
  beanClasses =
    map (c: "scala/reflect/${c}") [
      "BeanDescription"
      "BeanDisplayName"
      "BeanInfo"
      "BeanInfoSkip"
      "BeanProperty"
      "BooleanBeanProperty"
      "ScalaBeanInfo"
    ]
    ++ map (c: "scala/annotation/target/${c}") [
      "beanGetter"
      "beanSetter"
      "field"
      "getter"
      "setter"
      "param"
    ];

  scala2 = env: {
    builder = "scala2.sh";
    inherit env;
  };

  # --- Scala 2: SABBUS, then sbt

  # 2006-01: the plain build of locker and quick
  nsc = { };
  # 2009-09: Predef extends LowPriorityImplicits and starts with imports, which make the
  # compilers import Predef into Predef itself (until 2013-07)
  predefImports = nsc // {
    SOURCE_PATCH = "${patches}/source/predef-imports.sh";
  };
  # 2009-10: the classes of the library's first run (Predef and what it needs) kept, as SABBUS
  # did: the new compiler needs e.g. `::` from a class file (its case accessor lookup of
  # 2009-07/08 crashes on source symbols)
  keepFirstRun = predefImports // {
    LIBRARY_KEEP_FIRST_RUN = "1";
  };
  # 2009-11: and the library's package objects (scala's aliases into scala.math) compiled with
  # Predef in that first run
  packageObjects = keepFirstRun // {
    PACKAGE_OBJECTS_FIRST = "1";
  };
  # 2010-02: scala.Array from source (Array.clone made public)
  arraySource = packageObjects // {
    ARRAY_FROM_SOURCE = "1";
  };
  # 2010-03: the compilers take Predef from the source path rather than from the class file of
  # the first run: the library's second run without the source path, as SABBUS (a4895b8592)
  noSourcepath = arraySource // {
    LIBRARY_NO_SOURCEPATH = "1";
  };
  # 2010-06: the library in one run (the parallel collections need much of it from the source
  # path in the first run, under names it cannot find there)
  oneRun =
    builtins.removeAttrs noSourcepath [
      "LIBRARY_KEEP_FIRST_RUN"
      "PACKAGE_OBJECTS_FIRST"
    ]
    // {
      LIBRARY_ONE_RUN = "1";
    };
  # 2011-01: package objects whose members became top-level objects ("DebugUtils is already
  # defined") left out of the fallback, and from then on all of them
  packageObjectsDrop = [ "*/package" ];
  fallbackPackageObjects = oneRun // {
    FALLBACK_DROP = drop packageObjectsDrop;
  };
  # 2011-01: the value classes' companions moved from scala.runtime (2010-04): the old ones left
  # out of the fallback ...
  valueCompanionsDrop = packageObjectsDrop ++ valueClasses;
  valueCompanions = fallbackPackageObjects // {
    FALLBACK_DROP = drop valueCompanionsDrop;
  };
  # ... and the old place of UnrolledBuffer, on which the compiler hangs
  unrolledBufferDrop = valueCompanionsDrop ++ [ "scala/collection/parallel/UnrolledBuffer" ];
  unrolledBuffer = valueCompanions // {
    FALLBACK_DROP = drop unrolledBufferDrop;
  };
  # 2011-10: the bean classes moved to scala.beans (bridge b110)
  beansDrop = unrolledBufferDrop ++ beanClasses;
  beans = unrolledBuffer // {
    FALLBACK_DROP = drop beansDrop;
  };
  # 2012-02: AnyRef specialization: with the source path again (else quick sees locker's
  # specialized Function1$mcLD$sp and GenJVM crashes)
  anyrefSpecialization = builtins.removeAttrs beans [ "LIBRARY_NO_SOURCEPATH" ];
  # 2012-04: macros, enabled by -Xmacros (until 2012-06, the compilers that know it)
  xmacros = anyrefSpecialization // {
    SCALAC_FLAGS = "-Xmacros";
  };
  # 2012-04: the Java 6 API (the compilers no longer get by with a stub for
  # java.util.concurrent.RunnableFuture, which forkjoin's ForkJoinPool refers to)
  java6 = xmacros // {
    JAVA_API = "1.6";
  };
  # 2013-07: (pruned at s176, 2013-04) neither FALLBACK_DROP nor -Xmacros needed any more
  java6Pruned = builtins.removeAttrs java6 [
    "FALLBACK_DROP"
    "SCALAC_FLAGS"
  ];
  # 2013-07: quasiquotes (9def2ada82), with which the move of Predef's imports breaks the build
  quasiquotes = builtins.removeAttrs java6Pruned [ "SOURCE_PATCH" ];
  # 2015-03: the Java 5 API is enough again; the compiler parses the version in the library's
  # library.properties at start-up (ScalaVersion.current), which older compilers trip over
  java5Api = builtins.removeAttrs quasiquotes [ "JAVA_API" ] // {
    VERSION_PROPERTIES = "1";
  };
  # 2015-07: JDK 8's class library (ReflectiveOperationException and the like)
  java8 = java5Api // {
    JAVA_API = "1.8";
  };
  # 2016-08: the library's Java sources call its Scala code (LambdaDeserializer): scalac reads
  # them with the Scala sources and javac compiles them afterwards, as sbt does
  javaAfterScala = java8 // {
    JAVA_AFTER_SCALA = "1";
  };
  # 2020-11: Name is a CharSequence; compiled with the compiler, src/reflect infers other types
  # than in a run of its own, as sbt's reflect project has it
  reflectSeparately = javaAfterScala // {
    REFLECT_SEPARATELY = "1";
  };

  # compiler first with library sources the new compiler needs and the previous library lacks
  cfLibrary =
    base: sources: patch:
    base
    // {
      CF_LIBRARY_SOURCES = drop sources;
    }
    // (if patch == null then { } else { CF_LIBRARY_PATCH = "${patches}/compiler-first/${patch}.sh"; });
in
{
  # --- the start: the Java boot compiler (2004-02), Scala 1.x (2004-2005), the first Scala 2
  # compiler (2005-12)
  boot.builder = "boot.sh";
  scala1.builder = "scala1.sh";
  nsc0.builder = "nsc0.sh";

  nsc = scala2 nsc;
  # 6a9d9f379a: chained package clauses (`package a; package b`), which the previous compiler
  # does not know, in locker's sources rewritten to single ones
  "2009-08-chained-packages" = scala2 (
    nsc
    // {
      LOCKER_SOURCE_PATCH = "${patches}/locker/unnest.sh";
    }
  );
  "2009-09-predef-imports" = scala2 predefImports;
  # d5b02c8652: the new arrays, which the previous compiler compiles with -Ynewarrays
  "2009-09-new-arrays" = scala2 (
    predefImports
    // {
      STARR_FLAGS = "-Ynewarrays";
    }
  );
  # 6a6a0ce235: Sequence => Seq; locker's compiler built against the previous library, which
  # has no collection.Seq
  "2009-10-seq-rename" = scala2 (
    predefImports
    // {
      LOCKER_SOURCE_PATCH = "${patches}/locker/seq-rename.patch";
    }
  );
  "2009-10-keep-first-run" = scala2 keepFirstRun;
  "2009-10-package-objects" = scala2 packageObjects;
  "2010-02-array-source" = scala2 arraySource;
  "2010-03-no-sourcepath" = scala2 noSourcepath;
  "2010-06-one-run" = scala2 oneRun;
  # 4be5e11ccc: @serializable deprecated, scala.serializable an alias of the new trait
  # scala.Serializable (bridge b96): the old class left out of the fallback, and in the
  # fallback's Scala signatures the inherited annotation renamed
  "2010-11-serializable" = scala2 (
    oneRun
    // {
      FALLBACK_DROP = drop [ "scala/serializable" ];
      FALLBACK_PATCH = "${patches}/fallback/serializable-rename.sh";
    }
  );
  # 8922c4ed09: the annotation base classes moved to scala.annotation (bridge b98)
  "2010-12-annotations" = scala2 (
    oneRun
    // {
      FALLBACK_DROP = drop [
        "scala/Annotation"
        "scala/ClassfileAnnotation"
        "scala/StaticAnnotation"
        "scala/TypeConstraint"
      ];
    }
  );
  "2011-01-fallback-package-objects" = scala2 fallbackPackageObjects;
  # 4253124eec: the AnyVal types as source files (compiler first, with the source path)
  "2011-01-anyval-sources" = scala2 (
    builtins.removeAttrs valueCompanions [ "LIBRARY_NO_SOURCEPATH" ]
  );
  "2011-01-value-companions" = scala2 valueCompanions;
  "2011-01-unrolled-buffer" = scala2 unrolledBuffer;
  "2011-10-beans" = scala2 beans;
  "2012-02-anyref-specialization" = scala2 anyrefSpecialization;
  # 0321df7292: value classes; the compiler first, with the library's reflection API
  "2012-03-reflect-api" = scala2 (cfLibrary anyrefSpecialization [ "scala/reflect/api" ] null);
  # e4976678fa: the next generation of macros, Manifest an alias of the new TypeTag, and
  # ClassTag; built by the compiler of bridge b119, which synthesizes ClassTags: locker's
  # sources without macro definitions and with the old Manifest, locker on the previous library
  # as well as its own (its code needs scala.reflect.Manifest), the old ClassManifest out of
  # the fallback
  "2012-04-macros" = scala2 (
    xmacros
    // {
      FALLBACK_DROP = drop (beansDrop ++ [ "scala/reflect/ClassManifest" ]);
      LOCKER_SOURCE_PATCH = "${patches}/locker/macros-2012-04.sh";
      LOCKER_ON_PREVIOUS_LIBRARY = "1";
    }
  );
  "2012-04-xmacros" = scala2 xmacros;
  "2012-04-java6" = scala2 java6;
  # 14df5d74b5: anyValClass takes a ClassTag (STARR update); the compiler first with the
  # reflection API and the macro context
  "2012-04-anyval-class" = scala2 (
    cfLibrary java6 [
      "scala/reflect/api"
      "scala/reflect/makro"
    ] null
  );
  # 5acac4d806: TypeTag => AbsTypeTag, ConcreteTypeTag => TypeTag
  "2012-06-abs-type-tags" = scala2 (cfLibrary java6 [ "scala/reflect" ] "abs-type-tags");
  # cba0cbb892: ClassManifest an alias of ClassTag
  "2012-06-classmanifest-alias" = scala2 (
    cfLibrary java6 [
      "scala/reflect/ClassManifest.scala"
      "scala/reflect/Manifest.scala"
      "scala/reflect/package.scala"
      "scala/reflect/ClassTag.scala"
    ] "classmanifest-alias"
  );
  # 3becbd55af: ClassTag.String removed (STARR update); with the previous ClassTag
  "2012-07-classtag-string" = scala2 (
    cfLibrary java6 [
      "scala/reflect"
      "!scala/reflect/ClassTag.scala"
    ] null
  );
  # ed2408f160 and 25e2bb072c (2.10.x): scala.Cloneable and annotation.cloneable
  "2012-07-cloneable" = scala2 (
    cfLibrary java6 [
      "scala/reflect"
      "scala/Cloneable.scala"
      "scala/annotation/cloneable.scala"
    ] null
  );
  # 930c85d6c9, adf2d3632b: STARR updates of the reflection library
  "2012-09-cf-reflect" = scala2 (cfLibrary java6 [ "scala/reflect" ] null);
  "2013-07-java6" = scala2 java6Pruned;
  "2013-07-quasiquotes" = scala2 quasiquotes;
  "2015-03-java5-api" = scala2 java5Api;
  "2015-07-java8" = scala2 java8;
  # c8e6050c3c: the new trait encoding (default methods, no impl classes); the commit does not
  # build itself (its JFunctionN still call Function2$class), but its locker, old-encoding
  # classes compiling the new encoding, builds the next
  "2016-03-trait-encoding" = scala2 (
    java8
    // {
      LOCKER_ONLY = "1";
    }
  );
  "2016-08-java-after-scala" = scala2 javaAfterScala;
  # 980833e92d: the removed mutable.IterableOps would shadow collection.IterableOps
  "2018-07-iterable-ops" = scala2 (
    javaAfterScala
    // {
      FALLBACK_DROP = drop [ "scala/collection/mutable/IterableOps" ];
    }
  );
  # 5d118abb20: the old reflect package object, with its val Manifest
  "2019-01-reflect-package" = scala2 (
    javaAfterScala
    // {
      FALLBACK_DROP = drop [ "scala/reflect/package" ];
    }
  );
  "2020-11-reflect-separately" = scala2 reflectSeparately;
}
