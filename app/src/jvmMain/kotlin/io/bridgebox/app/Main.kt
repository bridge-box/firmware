package io.bridgebox.app

import io.ktor.server.application.*
import io.ktor.server.engine.*
import io.ktor.server.netty.*
import io.ktor.server.plugins.contentnegotiation.*
import io.ktor.server.plugins.statuspages.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.http.*
//import io.ktor.serialization.kotlinx.json.*

fun main() {
    embeddedServer(Netty, port = 8080) {
        install(ContentNegotiation) {
//            json()
        }
        install(StatusPages) {
            exception<Throwable> { call, cause ->
                call.respondText(
                    text = "500: ${cause.localizedMessage}",
                    status = HttpStatusCode.InternalServerError
                )
            }
        }
        routing {
            get("/") {
//                call.respondText("BridgeBox is running on ${platformName()}")
            }
        }
    }.start(wait = true)
}
