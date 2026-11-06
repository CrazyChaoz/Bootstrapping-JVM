// Kotlin DSL: the root project, and the app (java + application)
subprojects {
    group = "smoke"
}

project(":app") {
    apply(plugin = "application")
    dependencies {
        "implementation"(project(":lib"))
    }
    configure<JavaApplication> {
        mainClass.set("smoke.Main")
    }
}
