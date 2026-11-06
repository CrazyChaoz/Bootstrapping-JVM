// Scala 2.13 through Gradle's Zinc worker, everything resolved offline from the Maven
// repository of pkgs/development/scala-modules (-PscalaRepo=...)
plugins {
    scala
    application
}

repositories {
    maven { url = uri(providers.gradleProperty("scalaRepo").get()) }
}

scala {
    zincVersion = "1.12.0"
}

dependencies {
    implementation("org.scala-lang:scala-library:2.13.18")
}

application {
    mainClass = "smoke.Main"
}
