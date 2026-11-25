package cu.todus.relayvpn

import android.content.Context
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import org.webrtc.DataChannel
import org.webrtc.MediaConstraints
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.SdpObserver
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Controlador del túnel WebRTC contra rtcvpn-server.
 *
 * Flujo completo (cliente = oferente, igual que espera el servidor):
 *  1. Descubre la URL del servidor RTC (ajuste manual o auto-descubrimiento
 *     vía GitHub raw: server-ip.json que publica el workflow del servidor).
 *  2. POST /connect {"apk_phone": "53XXXXXXXX"} → teléfono del pool asignado
 *     + JID + credenciales TURN. Si todos ocupados → lista de espera y se
 *     espera la notificación XMPP "CHANNEL_FREE:<phone>".
 *  3. XMPP propio (im.todus.cu:1756) con el JWT de toDus.
 *  4. PeerConnection con iceTransportPolicy=RELAY (solo TURN, como el server)
 *     + DataChannel "todus-vpn" + OFFER con candidatos (gathering completo,
 *     sin trickle: el servidor espera el SDP final en un solo mensaje).
 *  5. Envía "OFFER:<sdp>" al JID del server por XMPP y espera "ANSWER:<sdp>".
 *  6. DataChannel abierto → túnel listo; el SOCKS5 local abre streams con el
 *     protocolo de frames del servidor:
 *     [tipo:1][stream_id:4 BE][len:2 BE][payload]
 *     OPEN(host:port) / OPENED / DATA / CLOSE / ERR / PING / PONG.
 */
class RtcController(
    private val context: Context,
    val settings: RelaySettings,
    val stats: VpnStats,
) {
    companion object {
        // Frame types — idénticos a tunnel_protocol.go del servidor.
        const val FRAME_OPEN: Byte = 0
        const val FRAME_DATA: Byte = 1
        const val FRAME_CLOSE: Byte = 2
        const val FRAME_ERR: Byte = 3
        const val FRAME_OPENED: Byte = 4
        const val FRAME_PING: Byte = 5
        const val FRAME_PONG: Byte = 6
        const val CTRL_STREAM_ID = 0
        const val MAX_PAYLOAD = 16384
        private const val HEADER_LEN = 7

        // Códigos de error del servidor → respuesta SOCKS5.
        const val ERR_GENERAL: Byte = 1
        const val ERR_HOST_UNREACHABLE: Byte = 2
        const val ERR_CONN_REFUSED: Byte = 3
        const val ERR_CONN_TIMEOUT: Byte = 4

        const val DISCOVERY_URL =
            "https://raw.githubusercontent.com/miguelorlandos06/rtcvpn-server/server-ip/server-ip.json"

        /** URL del servidor (manual o descubierta) base sin barra final. */
        fun normalizeServerUrl(raw: String): String {
            var u = raw.trim()
            if (u.isEmpty()) return ""
            if (!u.startsWith("http://") && !u.startsWith("https://")) u = "http://$u"
            while (u.endsWith("/")) u = u.dropLast(1)
            return u
        }
    }

    // ---------------------------------------------------------------- estado UI

    @Volatile var phase: String = "inactivo"
        private set
    @Volatile var phaseDetail: String = ""
        private set
    @Volatile var serverUrl: String = ""
        private set
    @Volatile var serverPhone: String = ""
        private set
    @Volatile var waitlistPosition: Int = 0
        private set

    var onFatal: ((String) -> Unit)? = null

    @Volatile var running = false
        private set

    // ---------------------------------------------------------------- piezas

    private var account: TodusAuth.Account? = null
    private var xmpp: TodusXmpp? = null
    private var pc: PeerConnection? = null
    private var dc: DataChannel? = null
    private var factory: PeerConnectionFactory? = null
    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .writeTimeout(20, TimeUnit.SECONDS)
        .build()

    private val streams = ConcurrentHashMap<Int, RtcStream>()
    private val nextSid = AtomicInteger(1)

    @Volatile private var lastPong = 0L
    private var pingThread: Thread? = null
    @Volatile private var closedReason: String? = null

    // ---------------------------------------------------------------- conexión

    /**
     * Conecta el túnel completo (bloqueante). Lanza excepción con mensaje
     * humano si algo falla de forma fatal.
     */
    fun connect() {
        check(!running) { "túnel ya conectado" }
        closedReason = null
        try {
            setPhase("autenticando", "cuenta toDus")
            var acct = TodusAuth.load(context)
                ?: throw IllegalStateException("No hay cuenta toDus: inicia sesión primero")
            if (!acct.jwtValid()) {
                acct = TodusAuth.revalidate(context, acct, http)
            }
            account = acct

            setPhase("descubriendo", "servidor RTC")
            serverUrl = resolveServerUrl()

            setPhase("xmpp", "sesión XMPP ${acct.phone}")
            val x = TodusXmpp(acct.phone, acct.jwt)
            x.connect()
            xmpp = x

            // ── /connect: pedir canal ────────────────────────────────────
            var connectResp: ConnectResp? = null
            var waitPos = 0
            while (true) {
                setPhase("solicitando", "canal al pool del servidor")
                val json = httpPost("$serverUrl/connect", JSONObject().put("apk_phone", acct.phone))
                if (json.optString("error") == "all_busy") {
                    waitPos = json.optInt("waitlist_position", 0)
                    waitlistPosition = waitPos
                    setPhase("esperando-canal", "posición $waitPos en lista de espera")
                    AppLog.i("[rtc] todos los canales ocupados; esperando (posición $waitPos)")
                    // Esperar CHANNEL_FREE vía XMPP (hasta 10 min; luego reintentar).
                    val freed = waitForChannelFree(x, 10 * 60_000L)
                    if (!freed) continue
                    continue
                }
                if (!json.has("server_phone")) {
                    throw IllegalStateException("Respuesta inesperada de /connect: $json")
                }
                connectResp = parseConnectResp(json)
                break
            }
            waitlistPosition = 0
            val c = connectResp ?: throw IllegalStateException("/connect no asignó canal")
            serverPhone = c.serverPhone
            setPhase("negociando", "WebRTC con ${c.serverPhone}")

            // ── WebRTC: oferente con TURN forzado ────────────────────────
            setupWebRtc(c)
            val offerSdp = createOfferWithCandidates()
            x.sendMessage(c.serverJid, "OFFER:$offerSdp")
            AppLog.i("[rtc] OFFER enviado (${offerSdp.length} chars) a ${c.serverJid}")

            val answerSdp = waitForAnswer(x, c.serverJid, 45_000)
            applyAnswer(answerSdp)

            if (!waitDataChannelOpen(30_000)) {
                throw IllegalStateException("El DataChannel no abrió tras el ANSWER")
            }

            running = true
            lastPong = System.currentTimeMillis()
            startPingLoop()
            // Aviso opcional al server (lo registra en su log).
            x.sendMessage(c.serverJid, "READY")
            setPhase("conectado", "vía ${c.serverPhone}")
            stats.rtcConnectedAt.set(System.currentTimeMillis())
            AppLog.i("[rtc] túnel activo con ${c.serverPhone} (TURN relay)")
        } catch (e: Exception) {
            cleanupQuietly()
            throw e
        }
    }

    private fun setPhase(p: String, detail: String) {
        phase = p
        phaseDetail = detail
        AppLog.d("[rtc] fase: $p ($detail)")
    }

    /** URL del server: ajuste manual o auto-descubrimiento (3 intentos). */
    private fun resolveServerUrl(): String {
        val manual = normalizeServerUrl(settings.rtcServer)
        if (manual.isNotEmpty()) {
            AppLog.i("[rtc] servidor manual: $manual")
            return manual
        }
        var lastErr: Exception? = null
        for (attempt in 1..3) {
            try {
                val req = Request.Builder().url(DISCOVERY_URL).get().build()
                http.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) throw IllegalStateException("HTTP ${resp.code} en discovery")
                    val body = resp.body?.string() ?: ""
                    val json = JSONObject(body)
                    val ip = json.optString("ip", "")
                    val port = json.optInt("port", 8080)
                    if (ip.isEmpty()) throw IllegalStateException("discovery sin ip")
                    val url = "http://$ip:$port"
                    AppLog.i("[rtc] servidor descubierto: $url (actualizado ${json.optString("updated", "")})")
                    return url
                }
            } catch (e: Exception) {
                lastErr = e
                AppLog.w("[rtc] discovery intento $attempt falló: ${e.message}")
                Thread.sleep(2000L * attempt)
            }
        }
        throw IllegalStateException("No se pudo descubrir el servidor RTC (${lastErr?.message}). " +
            "Configura su dirección en Ajustes.")
    }

    private fun httpPost(url: String, body: JSONObject): JSONObject {
        val req = Request.Builder()
            .url(url)
            .post(body.toString().toRequestBody("application/json; charset=utf-8".toMediaType()))
            .build()
        http.newCall(req).execute().use { resp ->
            val raw = resp.body?.string() ?: ""
            if (!resp.isSuccessful) throw IllegalStateException("HTTP ${resp.code} en $url")
            return if (raw.isEmpty()) JSONObject() else JSONObject(raw)
        }
    }

    private data class ConnectResp(
        val serverPhone: String,
        val serverJid: String,
        val turnUris: List<String>,
        val turnUser: String,
        val turnPass: String,
    )

    private fun parseConnectResp(json: JSONObject): ConnectResp {
        val turn = json.optJSONObject("turn") ?: throw IllegalStateException("/connect sin TURN creds")
        return ConnectResp(
            serverPhone = json.optString("server_phone"),
            serverJid = json.optString("server_jid"),
            turnUris = turn.optJSONArray("uris")?.let { arr ->
                (0 until arr.length()).map { arr.optString(it) }
            } ?: emptyList(),
            turnUser = turn.optString("username"),
            turnPass = turn.optString("password"),
        )
    }

    /** Espera un CHANNEL_FREE del pool (mensaje XMPP desde cualquier JID del pool). */
    private fun waitForChannelFree(x: TodusXmpp, timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline && !x.closed) {
            val msg = x.recvMessage(1000) ?: continue
            when {
                msg.startsWith("CHANNEL_FREE:") -> {
                    val free = msg.removePrefix("CHANNEL_FREE:")
                    AppLog.i("[rtc] canal liberado: $free")
                    return true
                }
                msg.startsWith("ANSWER:") -> { /* answer viejo: ignorar */ }
                else -> AppLog.d("[xmpp] msg: ${msg.take(80)}")
            }
        }
        return false
    }

    // ---------------------------------------------------------------- WebRTC

    private fun setupWebRtc(c: ConnectResp) {
        if (factory == null) {
            PeerConnectionFactory.initialize(
                PeerConnectionFactory.InitializationOptions.builder(context)
                    .setEnableInternalTracer(false)
                    .createInitializationOptions()
            )
            factory = PeerConnectionFactory.builder().createPeerConnectionFactory()
        }
        val f = factory ?: throw IllegalStateException("PeerConnectionFactory no disponible")

        val iceServers = c.turnUris.map { uri ->
            PeerConnection.IceServer.builder(uri)
                .setUsername(c.turnUser)
                .setPassword(c.turnPass)
                .createIceServer()
        }
        if (iceServers.isEmpty()) throw IllegalStateException("el server no devolvió URIs TURN")

        val config = PeerConnection.RTCConfiguration(iceServers).apply {
            iceTransportsType = PeerConnection.IceTransportsType.RELAY // TURN forzado
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
            rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_ONCE
        }

        val gatheringDone = CountDownLatch(1)
        var gatheringComplete = false

        val observer = object : PeerConnection.Observer {
            override fun onIceCandidate(candidate: org.webrtc.IceCandidate) {}
            override fun onIceCandidatesRemoved(candidates: Array<out org.webrtc.IceCandidate>) {}
            override fun onSignalingChange(newState: PeerConnection.SignalingState) {}
            override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState) {
                AppLog.d("[rtc] ICE: $newState")
                if (newState == PeerConnection.IceConnectionState.FAILED) {
                    failTunnel("conexión ICE FALLIDA (TURN)")
                }
            }
            override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) {
                AppLog.d("[rtc] PC: $newState")
                if (newState == PeerConnection.PeerConnectionState.FAILED) {
                    failTunnel("PeerConnection FALLIDA")
                }
            }
            override fun onIceConnectionReceivingChange(receiving: Boolean) {}
            override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) {
                if (state == PeerConnection.IceGatheringState.COMPLETE) {
                    gatheringComplete = true
                    gatheringDone.countDown()
                }
            }
            override fun onAddStream(stream: org.webrtc.MediaStream) {}
            override fun onRemoveStream(stream: org.webrtc.MediaStream) {}
            override fun onDataChannel(channel: DataChannel) {}
            override fun onRenegotiationNeeded() {}
        }

        val newPc = f.createPeerConnection(config, observer)
            ?: throw IllegalStateException("no se pudo crear la PeerConnection")
        pc = newPc

        val channel = newPc.createDataChannel(
            "todus-vpn",
            DataChannel.Init().apply { ordered = true },
        ) ?: throw IllegalStateException("no se pudo crear el DataChannel")
        dc = channel
        dcOpenLatch = CountDownLatch(1)
        channel.registerObserver(object : DataChannel.Observer {
            override fun onBufferedAmountChange(amount: Long) {}
            override fun onStateChange() {
                AppLog.i("[rtc] DataChannel: ${channel.state()}")
                when (channel.state()) {
                    DataChannel.State.OPEN -> dcOpenLatch.countDown()
                    DataChannel.State.CLOSED -> failTunnel("DataChannel cerrado")
                    else -> {}
                }
            }
            override fun onMessage(buffer: DataChannel.Buffer) { handleDcMessage(buffer) }
        })
        // El latch de gathering del intento actual (lo usa createOfferWithCandidates).
        currentGatheringLatch = gatheringDone
    }

    private var dcOpenLatch = CountDownLatch(0)
    @Volatile private var currentGatheringLatch: CountDownLatch? = null

    /**
     * Crea el offer y espera a que el gathering de candidatos ICE termine
     * (vanilla ICE): el servidor no hace trickle, así que el OFFER debe llevar
     * todos los candidatos dentro del SDP.
     */
    private fun createOfferWithCandidates(): String {
        val currentPc = pc ?: throw IllegalStateException("sin PeerConnection")
        val offerReady = CountDownLatch(1)
        var offerSdp: String? = null
        var offerError: Exception? = null

        currentPc.createOffer(object : SdpObserver {
            override fun onCreateSuccess(desc: org.webrtc.SessionDescription) {
                currentPc.setLocalDescription(object : SdpObserver {
                    override fun onSetSuccess() {
                        offerSdp = desc.description ?: ""
                        offerReady.countDown()
                    }
                    override fun onSetFailure(error: String?) {
                        offerError = IllegalStateException("setLocalDescription: $error")
                        offerReady.countDown()
                    }
                    override fun onCreateSuccess(desc: org.webrtc.SessionDescription) {}
                    override fun onCreateFailure(error: String?) {}
                }, desc)
            }
            override fun onCreateFailure(error: String?) {
                offerError = IllegalStateException("createOffer: $error")
                offerReady.countDown()
            }
            override fun onSetSuccess() {}
            override fun onSetFailure(error: String?) {}
        }, MediaConstraints())

        if (!offerReady.await(15, TimeUnit.SECONDS)) {
            throw IllegalStateException("timeout creando el OFFER WebRTC")
        }
        offerError?.let { throw it }

        // Esperar gathering COMPLETE (hasta 10 s) para que localDescription
        // incluya los candidatos relay (vanilla ICE, sin trickle).
        val base = offerSdp ?: throw IllegalStateException("offer vacío")
        val latch = currentGatheringLatch
        if (latch == null || !latch.await(10, TimeUnit.SECONDS)) {
            AppLog.w("[rtc] gathering ICE incompleto tras 10 s; enviando lo que haya")
        }
        val local = currentPc.localDescription?.description ?: base
        val final = compactSdp(if (local.contains("a=candidate")) local else base)
        if (!final.contains("a=candidate")) {
            AppLog.w("[rtc] OFFER sin candidatos ICE: revisa la conectividad TURN")
        }
        return final
    }

    private fun applyAnswer(answerSdp: String) {
        val currentPc = pc ?: throw IllegalStateException("sin PeerConnection")
        val applied = CountDownLatch(1)
        var err: Exception? = null
        currentPc.setRemoteDescription(object : SdpObserver {
            override fun onSetSuccess() { applied.countDown() }
            override fun onSetFailure(error: String?) {
                err = IllegalStateException("setRemoteDescription(ANSWER): $error")
                applied.countDown()
            }
            override fun onCreateSuccess(desc: org.webrtc.SessionDescription) {}
            override fun onCreateFailure(error: String?) {}
        }, org.webrtc.SessionDescription(org.webrtc.SessionDescription.Type.ANSWER, answerSdp))
        if (!applied.await(10, TimeUnit.SECONDS)) throw IllegalStateException("timeout aplicando ANSWER")
        err?.let { throw it }
    }

    private fun waitForAnswer(x: TodusXmpp, serverJid: String, timeoutMs: Long): String {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val msg = x.recvMessage(1000) ?: continue
            when {
                msg.startsWith("ANSWER:") -> {
                    val sdp = msg.removePrefix("ANSWER:")
                    if (sdp.length < 40) {
                        AppLog.w("[rtc] ANSWER sospechosamente corto (${sdp.length})")
                    }
                    return sdp
                }
                msg.startsWith("CHANNEL_FREE:") -> { /* ignorar durante negociación */ }
                else -> AppLog.d("[xmpp] durante negociación: ${msg.take(60)}")
            }
        }
        throw IllegalStateException("timeout esperando el ANSWER del servidor")
    }

    private fun waitDataChannelOpen(timeoutMs: Long): Boolean {
        if (dc?.state() == DataChannel.State.OPEN) return true
        return dcOpenLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
    }

    /**
     * Reduce el SDP a lo imprescindible para un DataChannel (m=application),
     * evita límites de tamaño del cuerpo XMPP en toDus y attributes que pion
     * no necesita. NO altera cripto ni candidatos.
     */
    private fun compactSdp(sdp: String): String {
        val keep = listOf(
            "v=", "o=", "s=", "t=", "c=", "m=",
            "a=group", "a=ice-ufrag", "a=ice-pwd", "a=ice-options",
            "a=fingerprint", "a=setup", "a=mid", "a=sctp-port",
            "a=max-message-size", "a=candidate", "a=end-of-candidates",
        )
        val out = StringBuilder(sdp.length)
        for (line in sdp.lines()) {
            val l = line.trim().trimEnd('\r')
            if (l.isEmpty()) continue
            if (keep.any { l.startsWith(it) }) out.append(l).append("\r\n")
        }
        val result = out.toString()
        return if (result.contains("m=application")) result else sdp
    }

    // ---------------------------------------------------------------- frames

    private fun handleDcMessage(buffer: DataChannel.Buffer) {
        if (!buffer.binary) return
        val data = ByteArray(buffer.data.remaining())
        buffer.data.get(data)
        var off = 0
        while (off + HEADER_LEN <= data.size) {
            val ftype = data[off]
            val sid = ((data[off + 1].toInt() and 0xFF) shl 24) or
                ((data[off + 2].toInt() and 0xFF) shl 16) or
                ((data[off + 3].toInt() and 0xFF) shl 8) or
                (data[off + 4].toInt() and 0xFF)
            val plen = ((data[off + 5].toInt() and 0xFF) shl 8) or
                (data[off + 6].toInt() and 0xFF)
            if (off + HEADER_LEN + plen > data.size) break
            val payload = if (plen > 0) data.copyOfRange(off + HEADER_LEN, off + HEADER_LEN + plen) else ByteArray(0)
            off += HEADER_LEN + plen
            dispatchFrame(ftype, sid, payload)
        }
    }

    private fun dispatchFrame(ftype: Byte, sid: Int, payload: ByteArray) {
        when (ftype) {
            FRAME_OPENED -> streams[sid]?.onOpened()
            FRAME_DATA -> streams[sid]?.onData(payload)
            FRAME_CLOSE -> streams[sid]?.onClosed()
            FRAME_ERR -> {
                val code = if (payload.isNotEmpty()) payload[0] else ERR_GENERAL
                val msg = if (payload.size > 1) String(payload, 1, payload.size - 1, Charsets.UTF_8) else ""
                streams[sid]?.onRemoteError(code, msg)
            }
            FRAME_PONG -> lastPong = System.currentTimeMillis()
            else -> AppLog.d("[rtc] frame desconocido tipo=$ftype sid=$sid")
        }
    }

    /** Envía un frame al DataChannel respetando la contrapresión del buffer. */
    fun sendFrame(ftype: Byte, sid: Int, payload: ByteArray = ByteArray(0)) {
        val channel = dc ?: return
        val n = payload.size.coerceAtMost(0xFFFF)
        val frame = ByteArray(HEADER_LEN + n)
        frame[0] = ftype
        frame[1] = ((sid ushr 24) and 0xFF).toByte()
        frame[2] = ((sid ushr 16) and 0xFF).toByte()
        frame[3] = ((sid ushr 8) and 0xFF).toByte()
        frame[4] = (sid and 0xFF).toByte()
        frame[5] = ((n shr 8) and 0xFF).toByte()
        frame[6] = (n and 0xFF).toByte()
        if (n > 0) System.arraycopy(payload, 0, frame, HEADER_LEN, n)

        // Contrapresión: si el buffer SCTP crece demasiado, esperar un poco.
        val deadline = System.currentTimeMillis() + 10_000
        while (channel.bufferedAmount() > 4 shl 20) {
            if (System.currentTimeMillis() > deadline) {
                AppLog.w("[rtc] buffer SCTP saturado; cerrando túnel")
                failTunnel("buffer del DataChannel saturado")
                return
            }
            Thread.sleep(10)
        }
        channel.send(DataChannel.Buffer(ByteBuffer.wrap(frame), true))
    }

    private fun startPingLoop() {
        pingThread = Thread {
            while (running) {
                Thread.sleep(20_000)
                if (!running) break
                try {
                    sendFrame(FRAME_PING, CTRL_STREAM_ID)
                } catch (e: Exception) {
                    failTunnel("ping falló: ${e.message}")
                    break
                }
                if (System.currentTimeMillis() - lastPong > 75_000) {
                    failTunnel("sin PONG del servidor > 75 s")
                    break
                }
            }
        }.apply { name = "rtc-ping"; isDaemon = true; start() }
    }

    private fun failTunnel(reason: String) {
        if (closedReason != null) return
        closedReason = reason
        AppLog.e("[rtc] túnel caído: $reason")
        for (s in streams.values) s.onClosed()
        running = false
        onFatal?.invoke(reason)
    }

    // ---------------------------------------------------------------- API SOCKS

    /**
     * Abre un stream TCP del túnel (bloqueante). Lanza StreamException con el
     * código SOCKS5 correspondiente si el server rechaza la conexión.
     */
    fun openStream(host: String, port: Int, timeoutMs: Long = 15_000): RtcStream {
        check(running) { "túnel no activo" }
        val sid = nextSid.getAndIncrement()
        val stream = RtcStream(this, sid, stats)
        streams[sid] = stream
        sendFrame(FRAME_OPEN, sid, "$host:$port".toByteArray(Charsets.UTF_8))
        if (!stream.awaitOpen(timeoutMs)) {
            streams.remove(sid)
            val err = stream.openError
            throw StreamException(
                socksCode(err?.first ?: ERR_GENERAL),
                err?.second ?: "timeout abriendo $host:$port",
            )
        }
        return stream
    }

    fun closeStream(sid: Int) {
        val s = streams.remove(sid) ?: return
        try { sendFrame(FRAME_CLOSE, sid) } catch (e: Exception) {}
        s.onClosed()
    }

    fun removeStream(sid: Int) { streams.remove(sid) }

    fun socksCode(errCode: Byte): Int = when (errCode) {
        ERR_HOST_UNREACHABLE -> 4
        ERR_CONN_REFUSED -> 5
        ERR_CONN_TIMEOUT -> 8
        else -> 1
    }

    class StreamException(val socksReply: Int, message: String) : Exception(message)

    // ---------------------------------------------------------------- parada

    fun stop() {
        if (!running) { cleanupQuietly(); return }
        val reason = "detenido por el usuario"
        closedReason = reason
        running = false
        for (s in streams.values) s.onClosed()
        streams.clear()
        // Avisar al server que libere el teléfono del pool.
        val acct = account
        val jid = serverPhone.let { if (it.isNotEmpty()) "$it@im.todus.cu" else "" }
        try {
            if (jid.isNotEmpty()) xmpp?.sendMessage(jid, "CLOSED")
        } catch (e: Exception) {}
        try {
            if (serverPhone.isNotEmpty() && serverUrl.isNotEmpty()) {
                httpPost("$serverUrl/disconnect", JSONObject().put("server_phone", serverPhone))
            }
        } catch (e: Exception) {
            AppLog.w("[rtc] /disconnect falló: ${e.message}")
        }
        cleanupQuietly()
        phase = "inactivo"
        phaseDetail = ""
        serverPhone = ""
    }

    private fun cleanupQuietly() {
        running = false
        try { dc?.close() } catch (e: Exception) {}
        dc = null
        try { pc?.close() } catch (e: Exception) {}
        pc = null
        try { xmpp?.close() } catch (e: Exception) {}
        xmpp = null
        for (s in streams.values) s.onClosed()
        streams.clear()
    }

    /**
     * Stream del túnel: un flujo TCP bidireccional identificado por sid.
     * Bajada: cola de payloads (el hilo SOCKS los drena). Subida: frames DATA
     * troceados en MAX_PAYLOAD.
     */
    class RtcStream(
        private val controller: RtcController,
        val sid: Int,
        private val stats: VpnStats,
    ) {
        private val openLatch = CountDownLatch(1)
        @Volatile var openError: Pair<Byte, String>? = null
            private set
        private val downlink = LinkedBlockingQueue<ByteArray>(256)
        @Volatile private var closed = false

        private val POISON = ByteArray(0)

        fun awaitOpen(timeoutMs: Long): Boolean = openLatch.await(timeoutMs, TimeUnit.MILLISECONDS)

        fun onOpened() {
            openError = null
            openLatch.countDown()
        }

        fun onRemoteError(code: Byte, msg: String) {
            openError = code to msg
            openLatch.countDown()
            onClosed()
        }

        fun onData(payload: ByteArray) {
            if (closed || payload.isEmpty()) return
            stats.rtcFramesDown.incrementAndGet()
            if (!downlink.offer(payload)) {
                stats.udpOversizeDropped.incrementAndGet() // contador genérico de saturación
            }
        }

        fun onClosed() {
            if (closed) return
            closed = true
            openLatch.countDown()
            downlink.offer(POISON)
            controller.removeStream(sid)
        }

        /** Subida: divide en chunks <= MAX_PAYLOAD y envía frames DATA. */
        fun write(data: ByteArray, offset: Int = 0, length: Int = data.size - offset) {
            if (closed || length <= 0) return
            var start = offset
            val end = offset + length
            while (start < end) {
                val len = (end - start).coerceAtMost(MAX_PAYLOAD)
                val chunk = data.copyOfRange(start, start + len)
                controller.sendFrame(FRAME_DATA, sid, chunk)
                stats.rtcFramesUp.incrementAndGet()
                start += len
            }
        }

        /** Bajada: siguiente payload recibido o null si cerrado/timeout. */
        fun read(timeoutMs: Long): ByteArray? {
            if (closed) return null
            val chunk = downlink.poll(timeoutMs, TimeUnit.MILLISECONDS) ?: return null
            return if (chunk === POISON) null else chunk
        }

        fun close() {
            controller.closeStream(sid)
        }

        val isClosed: Boolean get() = closed
    }
}
