package online.bridgebox.agent

import kotlinx.cinterop.*
import platform.posix.*

private const val BOX_ID_PATH = "/etc/bridgebox/box-id"
private const val MAC_ETH0_PATH = "/sys/class/net/eth0/address"

@OptIn(ExperimentalForeignApi::class)
actual fun readFile(path: String): String? {
    val file = fopen(path, "r") ?: return null
    try {
        val buffer = ByteArray(4096)
        val result = StringBuilder()
        buffer.usePinned { pinned ->
            while (true) {
                val bytesRead = fread(pinned.addressOf(0), 1u, buffer.size.toULong(), file)
                if (bytesRead == 0UL) break
                result.append(buffer.decodeToString(0, bytesRead.toInt()))
            }
        }
        return result.toString().trim().ifEmpty { null }
    } finally {
        fclose(file)
    }
}

@OptIn(ExperimentalForeignApi::class)
actual fun writeFile(path: String, content: String) {
    val file = fopen(path, "w") ?: return
    fputs(content, file)
    fclose(file)
}

actual fun readBoxId(): String? = readFile(BOX_ID_PATH)

actual fun readMacEth0(): String? = readFile(MAC_ETH0_PATH)

actual fun writeBoxId(boxId: String) = writeFile(BOX_ID_PATH, boxId)
