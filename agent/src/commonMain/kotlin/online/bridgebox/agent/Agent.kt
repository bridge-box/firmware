package online.bridgebox.agent

class Agent(
    private val api: ApiClient,
) {
    suspend fun register(): RegisterResponse.Success {
        val boxId = readBoxId() ?: platformEnv("BOX_ID") ?: generateBoxId()
        val mac = readMacEth0() ?: platformEnv("MAC_ETH0") ?: error("Cannot read MAC address from eth0")

        println("=== BridgeBox Agent: регистрация ===")
        println("  BOX_ID:  $boxId")
        println("  MAC:     $mac")

        val response = api.register(RegisterRequest(deviceId = boxId, macEth0 = mac))
        writeFile("/etc/bridgebox/state", response.state.name.lowercase())

        println("  State:   ${response.state}")
        println("=== Регистрация завершена ===")
        return response
    }

    suspend fun heartbeat(): HeartbeatResponse {
        val boxId = readBoxId() ?: platformEnv("BOX_ID") ?: error("BOX_ID not set")

        val wlanConnected = readFile("/sys/class/net/wlan0/operstate") == "up"
        val bridgeUp = readFile("/sys/class/net/br0/operstate") == "up"
        val uptime = readFile("/proc/uptime")
            ?.split(".")
            ?.firstOrNull()
            ?.toLongOrNull()
            ?: 0L

        val request = HeartbeatRequest(
            deviceId = boxId,
            uptime = uptime,
            wlanConnected = wlanConnected,
            bridgeUp = bridgeUp,
        )

        val response = api.heartbeat(boxId, request)
        writeFile("/etc/bridgebox/state", response.state.name.lowercase())
        return response
    }

    suspend fun status(): DeviceStateResponse {
        val boxId = readBoxId() ?: platformEnv("BOX_ID") ?: error("BOX_ID not set")
        return api.getState(boxId)
    }

    private fun generateBoxId(): String {
        val mac = readMacEth0() ?: platformEnv("MAC_ETH0") ?: error("Cannot read MAC address from eth0")
        val hash = mac.encodeToByteArray()
            .fold(0L) { acc, b -> acc * 31 + b.toLong() }
            .let { kotlin.math.abs(it) }
            .toString(16)
            .uppercase()
            .padStart(6, '0')
            .take(6)
        val boxId = "BB-$hash"
        writeBoxId(boxId)
        println("  Сгенерирован BOX_ID: $boxId")
        return boxId
    }
}
