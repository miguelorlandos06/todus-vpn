package cu.todus.relayvpn

import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Contadores en vivo del servicio (equivalentes a la salida de consola del script).
 *
 * Ampliado con métricas de resiliencia (backoff, circuito, semáforo HTTP) para
 * poder observar el efecto de las optimizaciones desde la UI.
 */
class VpnStats {
    val startedAt = AtomicLong(0)
    val bytesUp = AtomicLong(0)      // teléfono -> TUN (subida del dispositivo)
    val bytesDown = AtomicLong(0)    // TUN -> teléfono (bajada hacia el dispositivo)
    val tcpSessionsActive = AtomicInteger(0)
    val tcpSessionsTotal = AtomicInteger(0)
    val udpDatagramsOut = AtomicLong(0)
    val udpDatagramsIn = AtomicLong(0)
    val tcpSegmentsDropped = AtomicLong(0)
    val udpOversizeDropped = AtomicLong(0)
    val storeGetOk = AtomicLong(0)
    val storePutOk = AtomicLong(0)
    val storeGetFail = AtomicLong(0)
    val storePutFail = AtomicLong(0)
    val storeDeleteOk = AtomicLong(0)
    val otherProtoDropped = AtomicLong(0)

    // ─── Resiliencia (nuevos) ────────────────────────────────────────────────
    val backoffEvents = AtomicLong(0)        // veces que se aplicó backoff
    val circuitOpenCount = AtomicLong(0)     // veces que el circuito se abrió
    val httpSemaphoreWait = AtomicLong(0)    // veces que un PUT/GET tuvo que esperar al semáforo
    val tcpBatchesSent = AtomicLong(0)       // bloques TCP coalescidos enviados
    val tcpFramesCoalesced = AtomicLong(0)   // frames individuales absorbidos por un batch
    val sessionsRejectedByLimit = AtomicLong(0) // sesiones rechazadas por el semáforo de concurrencia

    // ─── RTC / WebRTC (transporte nuevo) ─────────────────────────────────────
    val rtcConnectedAt = AtomicLong(0)       // momento en que el DataChannel abrió
    val rtcFramesUp = AtomicLong(0)          // frames DATA enviados al server
    val rtcFramesDown = AtomicLong(0)        // frames DATA recibidos del server
    val rtcStreamsOpened = AtomicLong(0)     // streams TCP creados sobre el DC
    val dnsOverTcpQueries = AtomicLong(0)    // consultas DNS resueltas por TCP dentro del túnel
    val udpDirectFlows = AtomicInteger(0)    // flujos UDP reenviados directos (fuera del túnel)

    fun uptimeMillis(): Long {
        val start = startedAt.get()
        return if (start == 0L) 0L else System.currentTimeMillis() - start
    }
}
