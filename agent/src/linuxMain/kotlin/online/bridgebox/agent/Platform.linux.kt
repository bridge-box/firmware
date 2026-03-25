package online.bridgebox.agent

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.toKString

@OptIn(ExperimentalForeignApi::class)
actual fun platformEnv(name: String): String? =
    platform.posix.getenv(name)?.toKString()
