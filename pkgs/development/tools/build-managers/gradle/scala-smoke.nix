# Gradle compiles Scala 2.13 (Zinc, joint Java/Scala), runs it and builds its scaladoc, offline,
# with Scala and Zinc from scalaModules.mavenRepo (gradle/tests/scala)
{ runCommand, jdk, gradleDist, scalaRepo }:
runCommand "gradle-${gradleDist.version}-scala-smoke" { } ''
  cp -r --no-preserve=mode ${./tests/scala} smoke
  cd smoke
  export JAVA_HOME=${jdk} GRADLE_USER_HOME=$PWD/.gradle HOME=$PWD
  ${gradleDist}/bin/gradle --offline --no-daemon --console=plain --stacktrace -PscalaRepo=file://${scalaRepo} \
    build run scaladoc 2>&1 | tee log
  grep -q '^BUILD SUCCESSFUL' log
  grep -q '^Hello from Scala 2.13.18 via Zinc: fib(90) = 2880067194370816120$' log
  test -f build/docs/scaladoc/index.html
  cp log $out
''
