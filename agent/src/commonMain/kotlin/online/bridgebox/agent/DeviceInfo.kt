package online.bridgebox.agent

/**
 * Платформо-зависимое получение информации об устройстве.
 */
expect fun readBoxId(): String?
expect fun readMacEth0(): String?
expect fun writeBoxId(boxId: String)
expect fun readFile(path: String): String?
expect fun writeFile(path: String, content: String)
