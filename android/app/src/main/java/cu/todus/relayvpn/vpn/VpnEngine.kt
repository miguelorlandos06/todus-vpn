package cu.todus.relayvpn.vpn

import android.net.VpnService
import android.os.ParcelFileDescriptor
import cu.todus.relayvpn.AppLog
import cu.todus.relayvpn.RelaySettings
import cu.todus.relayvpn.RtcController
import cu.todus.relayvpn.SocksServer
import cu.todus.relayvpn.VpnStats
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import kotlin.concurrent.thread

/**
 * Motor de la VPN: establece la interfaz TUN (VpnService.Builder), conecta el
 * túnel WebRTC contra rtcvpn-server y traduce todo el tráfico IP del
 * dispositivo hacia ese túnel:
 *
 *   apps -> TUN -> [pila TCP / DNS-TCP + UDP directo] -> SOCKS5 127.0.0.1:1080
 *        -> DataChannel WebRTC (TURN) -> rtcvpn-server -> Internet
 *
 * El tráfico de la propia app (XMPP, TURN, API del server) queda fuera de la
 * VPN (protect + paquete excluido), así que no hay bucle.
 */
class VpnEngine(
    private val service: VpnService,
    val settings: RelaySettings,
    val stats: VpnStats,
) {
    lateinit var rtc: RtcController
        private set

    /** RtcController si ya fue inicializado (para consultas de estado). */
    fun currentRtc(): RtcController? =
        if (this::rtc.isInitialized) rtc else null
    lateinit var socksServer: SocksServer
        private set
    lateinit var tcp: TcpStack
        private set
    lateinit var udp: UdpTunnel
        private set

    val socksHost: String = "127.0.0.1"
    val socksPort: Int get() = settings.socksPort

    /** Protege un socket TCP para que su tráfico no regrese por el TUN (bucle). */
    fun protect(socket: java.net.Socket): Boolean =
        try { service.protect(socket) } catch (e: Exception) { false }

    /** Protege un socket UDP (reenvío directo) para que no loop por el TUN. */
    fun protectUdp(socket: java.net.DatagramSocket): Boolean =
        try { service.protect(socket) } catch (e: Exception) { false }

    private var tun: ParcelFileDescriptor? = null
    private var tunInput: FileInputStream? = null
    private var tunOutput: FileOutputStream? = null
    private val writeLock = Any()

    @Volatile var running = false
        private set

    /** Callback fatal: el túnel RTC cayó después de estar activo. */
    @Volatile var onFatalCallback: ((String) -> Unit)? = null

    fun start() {
        // 1. Túnel WebRTC contra rtcvpn-server (auth + /connect + XMPP + TURN).
        //    Falla limpio aquí si no se puede establecer — sin TUN sin túnel.
        rtc = RtcController(service, settings, stats)
        rtc.onFatal = { reason -> onFatalCallback?.invoke(reason) }
        rtc.connect()

        // 2. SOCKS5 local sobre el DataChannel.
        socksServer = SocksServer(settings, rtc, stats)
        socksServer.start()

        val builder = service.Builder()
        builder.setSession("ToDus Relay VPN")
        builder.setMtu(Ip.MTU)
        builder.addAddress("10.111.112.113", 24)
        builder.addRoute("0.0.0.0", 0)
        if (settings.ipv6Enabled) {
            builder.addAddress("fd00:111:112:113::1", 64)
            builder.addRoute("::", 0)
        }
        var dnsAdded = 0
        for (dns in settings.remoteDns) {
            val ip = RelaySettings.parseIpForDns(dns) ?: continue
            if (ip.size == 16 && !settings.ipv6Enabled) continue
            builder.addDnsServer(dns)
            dnsAdded++
        }
        if (dnsAdded == 0) {
            builder.addDnsServer("8.8.8.8")
        }
        builder.setBlocking(true)
        builder.setMetered(false)
        // ─── Filtrado de apps + autoexclusión ───────────────────────────
        // IMPORTANTE: `addAllowedApplication` y `addDisallowedApplication`
        // son MUTUAMENTE EXCLUYENTES en el mismo Builder. Si se mezclan, el
        // sistema lanza UnsupportedOperationException ("addAllowed/
        // addDisallowedApplication already called") y establish() muere.
        // Por eso hay UNA sola rama: lista blanca (solo allowed) o modo por
        // defecto (solo disallowed para la propia app).
        if (settings.allowedApps.isNotEmpty()) {
            // Modo lista blanca: SOLO se usa addAllowedApplication. La propia
            // app de la VPN nunca se añade (ni hace falta: al no estar en la
            // lista, ya queda fuera del túnel y su tráfico a ToDus sale
            // directo, sin bucle).
            var added = 0
            for (pkg in settings.allowedApps) {
                if (pkg == service.packageName) continue
                try {
                    builder.addAllowedApplication(pkg)
                    added++
                } catch (e: android.content.pm.PackageManager.NameNotFoundException) {
                    AppLog.w("[vpn] app no instalada, se ignora: $pkg")
                } catch (e: Exception) {
                    // Cualquier rechazo del sistema no debe tumbar el arranque.
                    AppLog.w("[vpn] app rechazada por el sistema, se ignora: $pkg (${e.message})")
                }
            }
            AppLog.i("[vpn] filtrado de apps: solo $added " +
                "paquete(s) atraviesan la VPN (modo lista blanca)")
        } else {
            // Modo por defecto: enrutar todo el teléfono EXCEPTO nuestra
            // propia app (el tráfico hacia ToDus va directo, sin VPN).
            try {
                builder.addDisallowedApplication(service.packageName)
            } catch (e: android.content.pm.PackageManager.NameNotFoundException) {
                // paquete propio: no debería ocurrir
            }
            AppLog.i("[vpn] sin filtrado de apps: todo el tráfico del dispositivo (app propia excluida)")
        }

        val tunFd = try {
            builder.establish()
        } catch (e: Exception) {
            // No dejar el SOCKS5 local abierto si el TUN no se pudo crear.
            socksServer.stop()
            throw e
        } ?: run {
            socksServer.stop()
            throw IOException("No se pudo establecer la VPN (¿permiso revocado?)")
        }
        tun = tunFd
        tunInput = FileInputStream(tunFd.fileDescriptor)
        tunOutput = FileOutputStream(tunFd.fileDescriptor)

        tcp = TcpStack(this)
        udp = UdpTunnel(this)
        running = true
        stats.startedAt.set(System.currentTimeMillis())

        thread(name = "tun-reader", isDaemon = true) { readLoop() }
        thread(name = "tun-timer", isDaemon = true) { timerLoop() }
    }

    // ---------------------------------------------------------------- lectura del TUN

    private fun readLoop() {
        val buffer = ByteArray(65575)
        val input = tunInput ?: return
        while (running) {
            val n = try {
                input.read(buffer)
            } catch (e: IOException) {
                break
            }
            if (n <= 0) continue
            stats.bytesUp.addAndGet(n.toLong())
            try {
                handlePacket(buffer, n)
            } catch (e: Exception) {
                AppLog.w("[tun] paquete: ${e.message}")
            }
        }
    }

    private fun handlePacket(buf: ByteArray, n: Int) {
        val ip = Ip.parseIp(buf, n) ?: return
        when (ip.proto) {
            Ip.PROTO_TCP -> {
                val tcpPacket = Ip.parseTcp(ip, buf)
                if (tcpPacket != null) {
                    tcp.onTcp(tcpPacket, buf)
                }
            }
            Ip.PROTO_UDP -> {
                val udpPacket = Ip.parseUdp(ip, buf)
                if (udpPacket != null) {
                    udp.onDevicePacket(udpPacket, buf)
                }
            }
            else -> stats.otherProtoDropped.incrementAndGet()
        }
    }

    // ---------------------------------------------------------------- escritura al TUN

    fun sendTcpSegment(
        ipv6: Boolean, srcIp: ByteArray, dstIp: ByteArray,
        sport: Int, dport: Int, seq: Long, ack: Long,
        flags: Int, window: Int, options: ByteArray?, payload: ByteArray?,
    ) {
        val packet = Ip.buildTcpPacket(ipv6, srcIp, dstIp, sport, dport, seq, ack, flags, window, options, payload)
        writePacket(packet)
    }

    fun emitUdpPacket(srcIp: ByteArray, srcPort: Int, dstIp: ByteArray, dstPort: Int, payload: ByteArray) {
        val packet = Ip.buildUdpPacket(srcIp.size == 16, srcIp, dstIp, srcPort, dstPort, payload)
        writePacket(packet)
    }

    /** RST para segmentos que no pertenecen a ninguna sesión. */
    fun sendRstFor(pkt: Ip.TcpPacket) {
        val seq = if (pkt.ackFlag) pkt.ack else 0L
        // FIX: SYN y FIN consumen un número de secuencia además del payload.
        // Sin este ajuste, el RST respondido a un SYN lleva ACK=seq en vez de
        // seq+1, y los stacks estrictos lo descartan → la sesión huérfana
        // permanece media-abierta hasta timeout.
        val ack = (pkt.seq + pkt.payloadLen +
            (if (pkt.syn) 1 else 0) + (if (pkt.fin) 1 else 0)) and 0xFFFFFFFFL
        val packet = Ip.buildTcpPacket(
            pkt.ip.ipv6, pkt.ip.dst, pkt.ip.src, pkt.dstPort, pkt.srcPort,
            seq, ack, Ip.RST or Ip.ACK, 0, null, null,
        )
        writePacket(packet)
    }

    fun writePacket(packet: ByteArray) {
        if (!running) return
        stats.bytesDown.addAndGet(packet.size.toLong())
        synchronized(writeLock) {
            try {
                tunOutput?.write(packet, 0, packet.size)
            } catch (e: IOException) {
                // TUN cerrado al detener la VPN.
            }
        }
    }

    // ---------------------------------------------------------------- temporizador

    private fun timerLoop() {
        while (running) {
            try {
                Thread.sleep(100)
            } catch (e: InterruptedException) {
                break
            }
            try {
                tcp.tick()
                udp.tick()
            } catch (e: Exception) {
                AppLog.w("[tun] temporizador: ${e.message}")
            }
        }
    }

    // ---------------------------------------------------------------- parada

    fun stop() {
        if (!running) {
            closeQuietly()
            try { rtcStop() } catch (e: Exception) {}
            return
        }
        running = false
        try {
            tcp.closeAll()
        } catch (e: Exception) {
            // ignorar
        }
        try {
            udp.stop()
        } catch (e: Exception) {
            // ignorar
        }
        try {
            socksServer.stop()
        } catch (e: Exception) {
            // ignorar
        }
        try {
            rtcStop()
        } catch (e: Exception) {
            // ignorar
        }
        closeQuietly()
        AppLog.i("[*] VPN detenida")
    }

    private fun rtcStop() {
        if (this::rtc.isInitialized) {
            rtc.onFatal = null
            rtc.stop()
        }
    }

    private fun closeQuietly() {
        try {
            tunInput?.close()
        } catch (e: IOException) {
            // ignorar
        }
        try {
            tunOutput?.close()
        } catch (e: IOException) {
            // ignorar
        }
        try {
            tun?.close()
        } catch (e: IOException) {
            // ignorar
        }
        tunInput = null
        tunOutput = null
        tun = null
    }
}
