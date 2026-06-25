import org.gradle.api.tasks.testing.logging.TestExceptionFormat
import org.gradle.api.tasks.testing.logging.TestLogEvent

plugins {
    id("io.papermc.paperweight.patcher") version "2.0.0-beta.21"
}

paperweight {
    upstreams.paper {
        ref = providers.gradleProperty("paperRef")

        patchFile {
            path = "paper-server/build.gradle.kts"
            outputFile = file("coderyo-server/build.gradle.kts")
            patchFile = file("coderyo-server/build.gradle.kts.patch")
        }
        patchFile {
            path = "paper-api/build.gradle.kts"
            outputFile = file("coderyo-api/build.gradle.kts")
            patchFile = file("coderyo-api/build.gradle.kts.patch")
        }
        patchDir("paperApi") {
            upstreamPath = "paper-api"
            excludes = setOf("build.gradle.kts")
            patchesDir = file("coderyo-api/paper-patches")
            outputDir = file("paper-api")
        }
    }
}

val paperMavenPublicUrl = "https://repo.papermc.io/repository/maven-public/"

subprojects {
    apply(plugin = "java-library")
    apply(plugin = "maven-publish")

    extensions.configure<JavaPluginExtension> {
        toolchain {
            languageVersion = JavaLanguageVersion.of(25)
        }
    }

    repositories {
        mavenCentral()
        maven(paperMavenPublicUrl)
    }

    tasks.withType<AbstractArchiveTask>().configureEach {
        isPreserveFileTimestamps = false
        isReproducibleFileOrder = true
    }
    tasks.withType<JavaCompile> {
        options.encoding = Charsets.UTF_8.name()
        options.release = 25
        options.isFork = true
    }
    tasks.withType<Javadoc> {
        options.encoding = Charsets.UTF_8.name()
        // coderyoMC API docs tooling (issue #3): brand + tune the Javadoc build so
        // it produces a PaperMC-style, publishable HTML reference for coderyo-api.
        // This composes with the upstream paper-api Javadoc config (links, overview,
        // custom tags) that materializes into coderyo-api/build.gradle.kts.
        val stdOptions = options as StandardJavadocDocletOptions
        val apiVersion = providers.gradleProperty("apiVersion").orNull ?: project.version.toString()
        stdOptions.docTitle = "coderyoMC API $apiVersion"
        stdOptions.windowTitle = "coderyoMC API $apiVersion"
        stdOptions.encoding = Charsets.UTF_8.name()
        stdOptions.charSet = Charsets.UTF_8.name()
        stdOptions.docEncoding = Charsets.UTF_8.name()
        // JDK 25 platform API external links (resolve java.* references against
        // the JDK 25 docs). Mirrors how upstream links its other deps.
        stdOptions.links("https://docs.oracle.com/en/java/javase/25/docs/api/")
        stdOptions.addBooleanOption("Xdoclint:none", true)
        // Keep the log readable in CI; the build is large.
        stdOptions.quiet()
        // Upstream alpha sources can carry doclint-tripping javadoc; do not let a
        // single bad comment fail the whole docs build. The Gradle Javadoc task
        // still fails on real javadoc-tool errors (e.g. classpath problems).
        isFailOnError = false
    }
    tasks.withType<ProcessResources> {
        filteringCharset = Charsets.UTF_8.name()
    }
    tasks.withType<Test> {
        testLogging {
            showStackTraces = true
            exceptionFormat = TestExceptionFormat.FULL
            events(TestLogEvent.STANDARD_OUT)
        }
    }

    extensions.configure<PublishingExtension> {
        repositories {
            /*
            maven("https://repo.papermc.io/repository/maven-snapshots/") {
                name = "paperSnapshots"
                credentials(PasswordCredentials::class)
            }
             */
        }
    }
}
