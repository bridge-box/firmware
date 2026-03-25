import org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeTarget

plugins {
    kotlin("multiplatform") version "2.1.0"
    kotlin("plugin.serialization") version "2.1.0"
}

group = "online.bridgebox"
version = "0.1.0"

repositories {
    mavenCentral()
}

val ktorVersion = "3.1.0"

kotlin {

    fun KotlinNativeTarget.agentBinary() {
        binaries {
            executable("bb-agent") {
                entryPoint = "online.bridgebox.agent.main"
            }
        }
    }

    linuxX64 {
        agentBinary()
    }

    linuxArm64 {
        agentBinary()
    }

    sourceSets {
        commonMain {
            dependencies {
                implementation("io.ktor:ktor-client-core:$ktorVersion")
                implementation("io.ktor:ktor-client-content-negotiation:$ktorVersion")
                implementation("io.ktor:ktor-serialization-kotlinx-json:$ktorVersion")
                implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
            }
        }

        linuxMain {
            dependencies {
                implementation("io.ktor:ktor-client-curl:$ktorVersion")
            }
        }
    }
}

// https://youtrack.jetbrains.com/issue/KT-64508
kotlin.targets.withType<KotlinNativeTarget> {
    binaries.all {
        freeCompilerArgs += "-Xdisable-phases=RemoveRedundantCallsToStaticInitializersPhase"
    }
}
