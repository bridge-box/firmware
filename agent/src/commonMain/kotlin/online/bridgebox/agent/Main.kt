package online.bridgebox.agent

import kotlinx.coroutines.runBlocking

fun main(args: Array<String>) {
    val backendUrl = platformEnv("BACKEND_URL") ?: "http://localhost:8080"
    val api = ApiClient(backendUrl)
    val agent = Agent(api)

    val command = args.firstOrNull()

    when (command) {
        "register" -> runBlocking {
            agent.register()
        }

        "heartbeat" -> runBlocking {
            agent.heartbeat()
        }

        "status" -> runBlocking {
            val state = agent.status()
            println("Device: ${state.deviceId}")
            println("State:  ${state.state}")
            state.expiresAt?.let { println("Expires: $it") }
        }

        else -> {
            println("bb-agent v0.1.0 — BridgeBox Device Agent")
            println()
            println("Использование:")
            println("  bb-agent register   — зарегистрировать на бэкенде")
            println("  bb-agent heartbeat  — отправить heartbeat")
            println("  bb-agent status     — запросить статус")
            println()
            println("Переменные окружения:")
            println("  BACKEND_URL  — адрес бэкенда (по умолчанию http://localhost:8080)")
        }
    }

    api.close()
}

expect fun platformEnv(name: String): String?
