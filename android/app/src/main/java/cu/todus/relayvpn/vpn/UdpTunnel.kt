package cu.todus.relayvpn.vpn

import cu.todus.relayvpn.AppLog
import cu.todus.relayvpn.RtcController
import java.io.ByteArrayOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

/**
 * Túnel UDP del TUN para el transporte RTC (WebRTC DataChannel).
 *
 * El rtcvpn-server solo diala TCP, así que aquí se divide el UDP del
 * dispositivo:
 *
 *  - **DNS (puerto 53)**: se resuelve por TCP DENTRO del túnel RTC
 *    (DNS-over-TCP con prefijo de 2 bytes), con la misma caché de 5 min del
 *    túnel anterior. Así la resolución de nombres también sale por el VPN.
 *  - **Resto de UDP (QUIC, NTP, juegos…)**: se reenvía DIRECTO por la red
 *    física mediante sockets `protect()`ados (NAT por flujo). El servidor RTC
 *    no transporta UDP; antes de descartarlo (rompería QUIC/NTP), se deja
 *    salir directo.
 *
 * La demultiplexación por destino (flowMap) y la caché DNS se conservan del
 * puerto original de movil_proxy.py.
 */
class UdpTunnel(private val engine: VpnEngine) {
    private val settings = engine.settings
    private val stats = engine.stats

    @Volatile private var stopped = false

    private class LocalFlow(val ip: ByteArray, val port: Int, @Volatile var lastSeen: Long)

    private class DirectFlow(
        val dstIp: ByteArray,
        val dstPort: Int,
        val socket: DatagramSocket,
    ) {
        @Volatile var lastSeen = System.currentTimeMillis()
    }

    private class CachedDns(val response: ByteArray, val expiresAt: Long)
    private val dnsCache = ConcurrentHashMap<String, CachedDns>()

    /** remote → sockets locales del dispositivo que escribieron a ese remoto. */
    private val flowMap = ConcurrentHashMap<String, MutableList<LocalFlow>>()
    /** dst → flujo directo (socket UDP protegido). */
    private val directFlows = ConcurrentHashMap<String, DirectFlow>()

    private val dnsInFlight = ConcurrentHashMap.newKeySet<String>()
    private var lastFlowSweep = 0L

    private val dnsExecutor = java.util.concurrent.ThreadPoolExecutor(
        2, 4, 30, java.util.concurrent.TimeUnit.SECONDS,
        java.util.concurrent.LinkedBlockingQueue<Runnable>(64),
    ) { r -> Thread(r, "dns-tcp") }

    // ---------------------------------------------------------------- ciclo de vida

    fun onDevicePacket(pkt: Ip.UdpPacket, buf: ByteArray) {
        if (stopped) return
        val data = pkt.payload(buf)

        if (pkt.dstPort == 53 && data.size > 12) {
            val cached = lookupDnsCache(data)
            if (cached != null) {
                stats.udpDatagramsOut.incrementAndGet()
                stats.udpDatagramsIn.incrementAndGet()
                engine.emitUdpPacket(pkt.ip.dst, pkt.dstPort, pkt.ip.src, pkt.srcPort, cached)
                return
            }
            // DNS por TCP dentro del túnel (asíncrono; se evita duplicar consultas).
            val qKey = extractDnsQuestionKey(data) ?: ""
            if (qKey.isNotEmpty() && dnsInFlight.add(qKey)) {
                stats.udpDatagramsOut.incrementAndGet()
                dnsExecutor.execute {
                    try {
                        resolveDnsOverTcp(pkt, data)
                    } finally {
                        dnsInFlight.remove(qKey)
                    }
                }
            }
            return
        }

        stats.udpDatagramsOut.incrementAndGet()
        forwardDirect(pkt, data)
    }

    fun tick() {
        if (stopped) return
        val now = System.currentTimeMillis()
        if (now - lastFlowSweep > 1_000) {
            lastFlowSweep = now
            val iter = flowMap.entries.iterator()
            while (iter.hasNext()) {
                val entry = iter.next()
                val list = entry.value
                synchronized(list) {
                    list.removeAll { now - it.lastSeen > 60_000 }
                }
                if (list.isEmpty()) iter.remove()
            }
            val dIter = directFlows.entries.iterator()
            while (dIter.hasNext()) {
                val e = dIter.next()
                if (now - e.value.lastSeen > 60_000) {
                    dIter.remove()
                    try { e.value.socket.close() } catch (ex: Exception) {}
                }
            }
            if (flowMap.size > 2048) flowMap.clear()
            if (directFlows.size > 512) {
                directFlows.values.forEach { try { it.socket.close() } catch (e: Exception) {} }
                directFlows.clear()
            }
        }
    }

    fun stop() {
        stopped = true
        dnsExecutor.shutdownNow()
        directFlows.values.forEach { try { it.socket.close() } catch (e: Exception) {} }
        directFlows.clear()
        flowMap.clear()
    }

    fun directFlowCount(): Int = directFlows.size

    // ---------------------------------------------------------------- DNS por TCP (dentro del túnel)

    private fun resolveDnsOverTcp(pkt: Ip.UdpPacket, query: ByteArray) {
        val dstIp = pkt.ip.dst
        val dnsHost = dstIp.joinToString(".") { (it.toInt() and 0xFF).toString() }
        var stream: RtcController.RtcStream? = null
        try {
            stats.dnsOverTcpQueries.incrementAndGet()
            stream = engine.rtc.openStream(dnsHost, 53, 8_000)
            // DNS sobre TCP: [len:2 BE][query]
            val framed = ByteArray(2 + query.size)
            framed[0] = ((query.size shr 8) and 0xFF).toByte()
            framed[1] = (query.size and 0xFF).toByte()
            System.arraycopy(query, 0, framed, 2, query.size)
            stream.write(framed)

            // Leer respuesta: [len:2 BE][response]
            val acc = ByteArrayOutputStream(512)
            var expected = -1
            val deadline = System.currentTimeMillis() + 8_000
            while (System.currentTimeMillis() < deadline) {
                val chunk = stream.read(500) ?: break
                if (chunk.isEmpty()) continue
                acc.write(chunk)
                if (expected < 0 && acc.size() >= 2) {
                    val b = acc.toByteArray()
                    expected = ((b[0].toInt() and 0xFF) shl 8) or (b[1].toInt() and 0xFF)
                }
                if (expected >= 0 && acc.size() >= 2 + expected) break
            }
            val framedResp = acc.toByteArray()
            if (expected != null && expected in 12..65535 && framedResp.size >= 2 + expected) {
                val response = framedResp.copyOfRange(2, 2 + expected)
                recordDnsCache(response)
                stats.udpDatagramsIn.incrementAndGet()
                val overhead = 28
                if (response.size <= Ip.MTU - overhead) {
                    engine.emitUdpPacket(dstIp, 53, pkt.ip.src, pkt.srcPort, response)
                }
            }
        } catch (e: Exception) {
            // No hay respuesta por TCP: probar reenvío directo como último recurso.
            AppLog.d("[dns] TCP falló (${e.message}); reenvío directo")
            forwardDirect(pkt, query)
        } finally {
            try { stream?.close() } catch (e: Exception) {}
        }
    }

    // ---------------------------------------------------------------- caché DNS

    private fun extractDnsQuestionKey(data: ByteArray): String? {
        if (data.size <= 12) return null
        var idx = 12
        while (idx < data.size) {
            val len = data[idx].toInt() and 0xFF
            if (len == 0) {
                idx++
                break
            }
            if ((len and 0xC0) == 0xC0) {
                idx += 2
                break
            }
            idx += 1 + len
        }
        idx += 4
        if (idx > data.size) return null
        val qbytes = data.copyOfRange(12, idx)
        return qbytes.joinToString("-") { (it.toInt() and 0xFF).toString() }
    }

    private fun lookupDnsCache(query: ByteArray): ByteArray? {
        val qKey = extractDnsQuestionKey(query) ?: return null
        val cached = dnsCache[qKey] ?: return null
        if (System.currentTimeMillis() > cached.expiresAt) {
            dnsCache.remove(qKey)
            return null
        }
        val out = cached.response.copyOf()
        out[0] = query[0]
        out[1] = query[1]
        return out
    }

    private fun recordDnsCache(response: ByteArray) {
        if (response.size <= 12) return
        val flags = ((response[2].toInt() and 0xFF) shl 8) or (response[3].toInt() and 0xFF)
        val qr = (flags and 0x8000) != 0
        val rcode = flags and 0x000F
        val ancount = ((response[6].toInt() and 0xFF) shl 8) or (response[7].toInt() and 0xFF)
        if (!qr || rcode != 0 || ancount <= 0) return
        val qKey = extractDnsQuestionKey(response) ?: return
        dnsCache[qKey] = CachedDns(response.copyOf(), System.currentTimeMillis() + 300_000L)
    }

    // ---------------------------------------------------------------- UDP directo

    private fun forwardDirect(pkt: Ip.UdpPacket, data: ByteArray) {
        if (data.size > settings.udpMaxPacketSize) {
            stats.udpOversizeDropped.incrementAndGet()
            return
        }
        val dstIp = pkt.ip.dst
        val dstPort = pkt.dstPort
        if (dstIp.size != 4) return // solo IPv4 directo por ahora
        val key = flowKey(dstIp, dstPort)
        val now = System.currentTimeMillis()
        val flow = directFlows[key] ?: createDirectFlow(key, dstIp, dstPort, now) ?: return
        flow.lastSeen = now
        try {
            val dst = InetAddress.getByAddress(dstIp)
            flow.socket.send(DatagramPacket(data, data.size, dst, dstPort))
            upsertFlow(dstIp, dstPort, pkt.ip.src, pkt.srcPort)
        } catch (e: Exception) {
            AppLog.d("[udp] directo a $key: ${e.message}")
        }
    }

    private fun createDirectFlow(key: String, dstIp: ByteArray, dstPort: Int, now: Long): DirectFlow? {
        return try {
            val socket = DatagramSocket(InetSocketAddress(0))
            socket.soTimeout = 1_500
            if (!engine.protectUdp(socket)) {
                AppLog.w("[udp] no se pudo proteger el socket directo; cerrado")
                socket.close()
                return null
            }
            val flow = DirectFlow(dstIp, dstPort, socket)
            directFlows[key] = flow
            stats.udpDirectFlows.set(directFlows.size)
            val dst = InetAddress.getByAddress(dstIp)
            thread(name = "udp-direct-$key", isDaemon = true) { directReceiveLoop(flow, dst, dstPort) }
            flow
        } catch (e: Exception) {
            AppLog.w("[udp] flujo directo $key: ${e.message}")
            null
        }
    }

    private fun directReceiveLoop(flow: DirectFlow, dst: InetAddress, dstPort: Int) {
        val buffer = ByteArray(65535)
        val packet = DatagramPacket(buffer, buffer.size)
        while (!stopped) {
            try {
                packet.length = buffer.size
                flow.socket.receive(packet)
            } catch (e: java.net.SocketTimeoutException) {
                // Cerrar despacio: si el flujo fue barrido por tick, salir.
                if (directFlows[flowKey(flow.dstIp, flow.dstPort)] !== flow) break
                continue
            } catch (e: Exception) {
                break
            }
            if (packet.length <= 0) continue
            if (packet.port != dstPort) continue
            val payload = buffer.copyOfRange(0, packet.length)
            stats.udpDatagramsIn.incrementAndGet()
            val key = flowKey(flow.dstIp, flow.dstPort)
            val list = flowMap[key] ?: continue
            val now = System.currentTimeMillis()
            synchronized(list) {
                for (lf in list) {
                    lf.lastSeen = now
                    val overhead = if (lf.ip.size == 16) 48 else 28
                    if (payload.size > Ip.MTU - overhead) {
                        stats.udpOversizeDropped.incrementAndGet()
                        continue
                    }
                    engine.emitUdpPacket(flow.dstIp, flow.dstPort, lf.ip, lf.port, payload)
                }
            }
            flow.lastSeen = now
        }
    }

    private fun upsertFlow(dstIp: ByteArray, dstPort: Int, srcIp: ByteArray, srcPort: Int) {
        val key = flowKey(dstIp, dstPort)
        val now = System.currentTimeMillis()
        val list = flowMap.computeIfAbsent(key) { ArrayList(4) }
        synchronized(list) {
            var found: LocalFlow? = null
            for (flow in list) {
                if (flow.port == srcPort && flow.ip.contentEquals(srcIp)) {
                    found = flow
                    break
                }
            }
            if (found != null) {
                found.lastSeen = now
            } else {
                if (list.size >= 8) {
                    var oldestIdx = 0
                    var oldestTime = list[0].lastSeen
                    for (i in 1 until list.size) {
                        if (list[i].lastSeen < oldestTime) {
                            oldestTime = list[i].lastSeen
                            oldestIdx = i
                        }
                    }
                    list.removeAt(oldestIdx)
                }
                list.add(LocalFlow(srcIp, srcPort, now))
            }
        }
    }

    private fun flowKey(ip: ByteArray, port: Int): String =
        ip.joinToString("-") { (it.toInt() and 0xFF).toString() } + ":" + port
}
