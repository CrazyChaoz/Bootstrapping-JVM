// The artifact transforms of Gradle's build that change third-party jars of the distribution,
// run outside Gradle: build-logic-commons' Minify (compiled with its JarAnalyzer, ClassGraph)
// and build-logic's NoModuleAnnotation.  The bodies are those of the transforms.
//
//   minify IN OUT CLASS...            (gradlebuild.minify's keepPatterns of the artifact)
//   no-module-annotation IN OUT TIME  (TIME: the entries' time, epoch millis; upstream's is
//                                      the time of its build, JarEntry's default)
package gradlebuild.transforms

import gradlebuild.basics.classanalysis.ClassDetails
import gradlebuild.basics.classanalysis.ClassGraph
import gradlebuild.basics.classanalysis.JarAnalyzer
import gradlebuild.basics.classanalysis.addJarEntry
import org.objectweb.asm.AnnotationVisitor
import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.Opcodes
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.util.jar.JarEntry
import java.util.jar.JarFile
import java.util.jar.JarOutputStream


fun main(args: Array<String>) {
    when (args[0]) {
        "minify" -> minify(File(args[1]), args.drop(3).toSet(), File(args[2]))
        "no-module-annotation" -> transformJar(File(args[1]), File(args[2]), args[3].toLong())
        else -> error("unknown transform ${args[0]}")
    }
}


// Minify.minify, createJar, visitTree
fun minify(artifact: File, keepClasses: Set<String>, jarFile: File): File {
    val tempDirectory = java.nio.file.Files.createTempDirectory(jarFile.name).toFile()
    val classesDir = tempDirectory.resolve("classes")
    val manifestFile = tempDirectory.resolve("MANIFEST.MF")
    val buildReceiptFile = tempDirectory.resolve("build-receipt.properties")
    val classGraph = JarAnalyzer("", keepClasses, keepClasses, setOf()).analyze(artifact, classesDir, manifestFile, buildReceiptFile)

    createJar(classGraph, classesDir, manifestFile, jarFile)

    return jarFile
}

fun createJar(classGraph: ClassGraph, classesDir: File, manifestFile: File, jarFile: File) {
    JarOutputStream(BufferedOutputStream(FileOutputStream(jarFile))).use { jarOutputStream ->
        if (manifestFile.exists()) {
            jarOutputStream.addJarEntry(JarFile.MANIFEST_NAME, manifestFile)
        }
        val visited = linkedSetOf<ClassDetails>()
        for (classDetails in classGraph.entryPoints) {
            visitTree(classDetails, classesDir, jarOutputStream, visited)
        }
    }
}

fun visitTree(
    classDetails: ClassDetails,
    classesDir: File,
    jarOutputStream: JarOutputStream,
    visited: MutableSet<ClassDetails>
) {
    if (!visited.add(classDetails)) {
        return
    }
    if (classDetails.visited) {
        val fileName = classDetails.outputClassFilename
        val classFile = classesDir.resolve(fileName)
        jarOutputStream.addJarEntry(fileName, classFile)
        for (dependency in classDetails.dependencies) {
            visitTree(dependency, classesDir, jarOutputStream, visited)
        }
    }
}


// NoModuleAnnotation.transformJar (with the entries' time given)
fun transformJar(inputFile: File, outputFile: File, time: Long) {
    JarFile(inputFile).use { inputJar ->
        JarOutputStream(outputFile.outputStream().buffered()).use { outputJar ->
            inputJar.entries().iterator().forEach { entry ->
                outputJar.putNextEntry(JarEntry(entry.name).also { it.time = time })
                inputJar.getInputStream(entry).use { entryInput ->
                    if (entry.name.endsWith(".class")) {
                        transformClass(entryInput, outputJar)
                    } else {
                        entryInput.copyTo(outputJar)
                    }
                }
            }
        }
    }
}

fun transformClass(inputStream: InputStream, outputStream: OutputStream) {
    ClassWriter(0).let { writer ->
        ClassReader(inputStream).accept(TransformClassVisitor(writer), 0)
        outputStream.write(writer.toByteArray())
    }
}

class TransformClassVisitor(parent: ClassWriter) : ClassVisitor(ASM_LEVEL, parent) {
    override fun visitAnnotation(descriptor: String?, visible: Boolean): AnnotationVisitor {
        if (descriptor == TARGET_ANNOTATION_DESCRIPTOR) {
            return TransformAnnotationVisitor(super.visitAnnotation(descriptor, visible))
        }
        return super.visitAnnotation(descriptor, visible)
    }
}

class TransformAnnotationVisitor(parent: AnnotationVisitor) : AnnotationVisitor(ASM_LEVEL, parent) {
    override fun visitEnum(name: String?, descriptor: String?, value: String?) {
        if (value != MODULE_TARGET_ENUM_VALUE) {
            super.visitEnum(name, descriptor, value)
        }
    }

    override fun visitArray(name: String?): AnnotationVisitor {
        return TransformAnnotationVisitor(super.visitArray(name))
    }
}

const val TARGET_ANNOTATION_DESCRIPTOR = "Ljava/lang/annotation/Target;"
const val MODULE_TARGET_ENUM_VALUE = "MODULE"
const val ASM_LEVEL = Opcodes.ASM9
