package online.bridgebox.agent

import io.ktor.client.*
import io.ktor.client.call.*
import io.ktor.client.plugins.contentnegotiation.*
import io.ktor.client.request.*
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.*
import kotlinx.serialization.json.Json

class ApiClient(
    private val baseUrl: String,
) {
    private val client = HttpClient {
        install(ContentNegotiation) {
            json(Json { ignoreUnknownKeys = true })
        }
    }

    suspend fun register(request: RegisterRequest): RegisterResponse.Success =
        client.post("$baseUrl/api/devices/register") {
            contentType(ContentType.Application.Json)
            setBody(request)
        }.body()

    suspend fun getState(deviceId: String): DeviceStateResponse =
        client.get("$baseUrl/api/devices/$deviceId/state").body()

    suspend fun heartbeat(deviceId: String, request: HeartbeatRequest): HeartbeatResponse =
        client.post("$baseUrl/api/devices/$deviceId/heartbeat") {
            contentType(ContentType.Application.Json)
            setBody(request)
        }.body()

    fun close() {
        client.close()
    }
}
