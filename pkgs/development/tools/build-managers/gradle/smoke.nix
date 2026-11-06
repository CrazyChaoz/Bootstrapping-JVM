# A Gradle distribution builds and runs a small project offline: the Kotlin DSL (root, which
# needs the embedded Kotlin compiler), the Groovy DSL (lib), java-library and application.
{
  runCommand,
  jdk,
  gradleDist,
}:

runCommand "gradle-${gradleDist.version}-smoke" { } ''
  cp -r --no-preserve=mode ${./tests/smoke} smoke
  cd smoke
  export JAVA_HOME=${jdk} GRADLE_USER_HOME=$PWD/.gradle HOME=$PWD
  ${gradleDist}/bin/gradle --offline --no-daemon --console=plain --stacktrace build :lib:greeting :app:run 2>&1 | tee log
  grep -q '^BUILD SUCCESSFUL' log
  grep -q '^greeting from the Groovy DSL$' log
  grep -q '^Hello from a from-source Gradle: fib(30) = 832040$' log
  cp log $out
''
