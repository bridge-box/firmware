package online.bridgebox.agent

import kotlinx.serialization.Serializable

@Serializable
enum class DeviceState {
    SETUP, UNCLAIMED, CLAIMED, ACTIVE, BYPASS
}

@Serializable
data class RegisterRequest(
    val deviceId: String,
    val macEth0: String,
)

@Serializable
sealed interface RegisterResponse {
    @Serializable
    data class Success(
        val deviceId: String,
        val state: DeviceState,
    ) : RegisterResponse

    @Serializable
    data class SuccessWithAuth(
        val deviceId: String,
        val state: DeviceState,
        val tailscaleAuthKey: String,
    ) : RegisterResponse
}

@Serializable
data class DeviceStateResponse(
    val deviceId: String,
    val state: DeviceState,
    val expiresAt: String,
    val graceHours: Int,
)

@Serializable
data class HeartbeatRequest(
    val deviceId: String,
    val uptime: Long,
    val wlanConnected: Boolean,
    val bridgeUp: Boolean,
)

@Serializable
data class HeartbeatResponse(
    val state: DeviceState,
)

@Serializable
data class ErrorResponse(
    val error: String,
)
