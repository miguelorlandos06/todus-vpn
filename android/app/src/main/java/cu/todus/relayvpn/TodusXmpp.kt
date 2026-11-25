package cu.todus.relayvpn

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import kotlin.concurrent.thread

/**
 * Cliente XMPP de toDus para la APK (señalización WebRTC).
 *
 * Puerto fiel del `XmppClient` de rtcvpn-server (todus.go):
 *  - TLS a im.todus.cu:1756 (cert LE no verificado, igual que el servidor).
 *  - Handshake con el dialecto toDus: stream 'jc'/'x1', SASL PLAIN <ah>, bind
 *    <b1> con resource md5(phone)_Android, presencia <p/>.
 *  - Envío: <m o='jid' t='c' i='id' xmlns='jc'>body</m>.
 *  - Recepción: bucle que extrae stanzas y reparte mensajes <m> e <iq>.
 *
 * Diferencia deliberada con el servidor Go: los timeouts de lectura NO cierran
 * la sesión (el servidor Go recicla la conexión en cada silencio de 60 s);
 * aquí el silencio se tolera y un latido cada 45 s mantiene viva la sesión
 * NAT/TCP, que es lo que necesita la APK para esperar un ANSWER o un
 * CHANNEL_FREE sin reconectarse a cada rato.
 */
class TodusXmpp(
    val phone: String,
    private val token: String,
) {
    companion object {
        const val HOST = "im.todus.cu"
        const val PORT = 1756
        const val TURN_JID = "tturn@im.todus.cu"

        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val READ_TIMEOUT_MS = 30_000
        private const val HEARTBEAT_MS = 45_000L

        private val RNG = SecureRandom()
        private const val ID_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

        fun randomId(n: Int): String {
            val sb = StringBuilder(n)
            for (i in 0 until n) sb.append(ID_CHARS[RNG.nextInt(ID_CHARS.length)])
            return sb.toString()
        }

        fun escapeXml(s: String): String = s
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("'", "&apos;")
            .replace("\"", "&quot;")

        fun unescapeXml(s: String): String = s
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&apos;", "'")
            .replace("&quot;", "\"")
    }

    val jid: String get() = "$phone@im.todus.cu"

    private var sock: SSLSocket? = null
    private var out: BufferedOutputStream? = null

    /** Cuerpos de <m> entrantes. */
    val messages = LinkedBlockingQueue<String>(512)
    /** Respuestas <iq> crudas. */
    val iqResponses = LinkedBlockingQueue<String>(64)

    @Volatile var closed = false
        private set

    private val writeLock = Any()

    /** Conecta + handshake completo. Lanza si algo falla. */
    fun connect() {
        check(!closed) { "cliente cerrado" }
        val factory = trustAllFactory()
        val raw = Socket()
        raw.connect(InetSocketAddress(HOST, PORT), CONNECT_TIMEOUT_MS)
        raw.soTimeout = READ_TIMEOUT_MS
        val tls = factory.createSocket(raw, HOST, PORT, true) as SSLSocket
        tls.startHandshake()
        sock = tls
        out = BufferedOutputStream(tls.getOutputStream())

        // 1. Stream open
        writeRaw("<stream:stream xmlns='jc' o='im.todus.cu' xmlns:stream='x1' v='1.0'>")
        readUntil("<stream:features>")

        // 2. SASL PLAIN: \0 phone \0 token
        val auth = byteArrayOf(0) + phone.toByteArray() + byteArrayOf(0) + token.toByteArray()
        val b64 = android.util.Base64.encodeToString(auth, android.util.Base64.NO_WRAP)
        writeRaw("<ah xmlns='ah:ns' e='PLAIN'>$b64</ah>")
        val resp = readUntilAny("<ok", "<not-authorized", "<failure")
        if (resp.contains("<not-authorized") || resp.contains("<failure")) {
            tls.close()
            throw IllegalStateException("XMPP: token rechazado por im.todus.cu")
        }

        // 3. Stream restart
        writeRaw("<stream:stream xmlns='jc' o='im.todus.cu' xmlns:stream='x1' v='1.0'>")
        readUntil("<stream:features>")

        // 4. Bind
        val resource = TodusAuth.md5Hex(phone) + "_Android"
        writeRaw("<iq i='${randomId(12)}' t='set'><b1 xmlns='x4'><re>$resource</re></b1></iq>")
        readUntil("</iq>")

        // 5. Presence
        writeRaw("<p/>")
        flush()

        // Reader + heartbeat
        thread(name = "xmpp-reader", isDaemon = true) { readLoop() }
        thread(name = "xmpp-heartbeat", isDaemon = true) { heartbeatLoop() }
        AppLog.i("[xmpp] sesión iniciada como $jid")
    }

    // ---------------------------------------------------------------- API

    /** Envía un mensaje <m> al JID indicado. */
    fun sendMessage(toJid: String, body: String) {
        writeRaw("<m o='$toJid' t='c' i='${randomId(16)}' xmlns='jc'>${escapeXml(body)}</m>")
    }

    /** Envía un IQ y espera su respuesta por id (timeout 15 s). */
    fun sendIq(to: String, payload: String, timeoutSec: Long = 15): String {
        val id = randomId(12)
        writeRaw("<iq i='$id' t='get' o='$to'>$payload</iq>")
        val deadline = System.currentTimeMillis() + timeoutSec * 1000
        while (System.currentTimeMillis() < deadline) {
            val resp = iqResponses.poll(1, TimeUnit.SECONDS) ?: continue
            if (resp.contains(id)) return resp
            // respuesta ajena: devolverla a la cola para no perderla
            iqResponses.offer(resp)
        }
        throw IllegalStateException("IQ timeout esperando respuesta de $to")
    }

    /** Espera el siguiente <m> entrante con timeout. null si expira. */
    fun recvMessage(timeoutMs: Long): String? =
        messages.poll(timeoutMs, TimeUnit.MILLISECONDS)

    fun close() {
        closed = true
        try { sock?.close() } catch (e: Exception) {}
    }

    // ---------------------------------------------------------------- bucles

    private fun readLoop() {
        val input = try {
            sock?.getInputStream() ?: return
        } catch (e: Exception) { return }
        val buffered = BufferedInputStream(input)
        val accum = ByteArrayOutputStream(4096)
        val buf = ByteArray(8192)
        while (!closed) {
            val n = try {
                buffered.read(buf)
            } catch (e: Exception) {
                // Timeout de lectura: NO es error — seguir esperando.
                if (isReadTimeout(e)) continue
                break
            }
            if (n < 0) break
            if (n == 0) continue
            accum.write(buf, 0, n)
            // Procesar todas las stanzas completas acumuladas.
            while (true) {
                val (stanza, rest) = extractStanza(accum.toString("UTF-8")) ?: break
                accum.reset()
                accum.write(rest.toByteArray(Charsets.UTF_8))
                if (stanza.isNotEmpty()) dispatchStanza(stanza)
            }
            // El acumulador puede crecer con basura sin stanza: recortar.
            if (accum.size() > 1 shl 20) accum.reset()
        }
        if (!closed) AppLog.w("[xmpp] lector terminó (${jid})")
        closed = true
    }

    private fun isReadTimeout(e: Exception): Boolean {
        var cause: Throwable? = e
        while (cause != null) {
            if (cause is java.net.SocketTimeoutException) return true
            cause = cause.cause
        }
        return false
    }

    private fun heartbeatLoop() {
        while (!closed) {
            Thread.sleep(HEARTBEAT_MS)
            if (closed) return
            try {
                writeRaw(" ")
            } catch (e: Exception) {
                closed = true
                return
            }
        }
    }

    private fun dispatchStanza(stanza: String) {
        if (stanza.startsWith("<m ") || stanza.startsWith("<m>")) {
            val start = stanza.indexOf('>')
            val end = stanza.lastIndexOf("</m>")
            if (start >= 0 && end > start) {
                val body = unescapeXml(stanza.substring(start + 1, end))
                if (!messages.offer(body)) AppLog.w("[xmpp] cola de mensajes llena, descartando")
            }
        } else if (stanza.startsWith("<iq ") || stanza.startsWith("<iq>")) {
            if (!iqResponses.offer(stanza)) AppLog.w("[xmpp] cola de IQ llena, descartando")
        }
    }

    // ---------------------------------------------------------------- io

    private fun writeRaw(s: String) {
        val o = out ?: throw IllegalStateException("XMPP sin conexión")
        synchronized(writeLock) {
            o.write(s.toByteArray(Charsets.UTF_8))
            o.flush()
        }
    }

    private fun flush() {
        synchronized(writeLock) { out?.flush() }
    }

    /** Lee hasta encontrar `terminator` (acumulando). Timeout de socket por read. */
    private fun readUntil(terminator: String): String {
        val input = sock?.getInputStream() ?: throw IllegalStateException("XMPP sin conexión")
        val buffered = BufferedInputStream(input)
        val sb = StringBuilder()
        val deadline = System.currentTimeMillis() + 15_000
        while (System.currentTimeMillis() < deadline) {
            val b = try {
                buffered.read()
            } catch (e: Exception) {
                if (isReadTimeout(e)) continue
                throw e
            }
            if (b < 0) throw IllegalStateException("XMPP cerrado durante handshake")
            sb.append(b.toChar())
            if (sb.contains(terminator)) return sb.toString()
        }
        throw IllegalStateException("XMPP timeout esperando '$terminator'")
    }

    private fun readUntilAny(vararg terminators: String): String {
        val input = sock?.getInputStream() ?: throw IllegalStateException("XMPP sin conexión")
        val buffered = BufferedInputStream(input)
        val sb = StringBuilder()
        val deadline = System.currentTimeMillis() + 15_000
        while (System.currentTimeMillis() < deadline) {
            val b = try {
                buffered.read()
            } catch (e: Exception) {
                if (isReadTimeout(e)) continue
                throw e
            }
            if (b < 0) throw IllegalStateException("XMPP cerrado durante handshake")
            sb.append(b.toChar())
            for (t in terminators) if (sb.contains(t)) return sb.toString()
        }
        throw IllegalStateException("XMPP timeout esperando ${terminators.joinToString("/")}")
    }

    /**
     * Extrae la primera stanza XML completa de s. Devuelve (stanza, resto) o
     * null si no hay ninguna completa. Puerto de extractStanza del servidor Go.
     */
    private fun extractStanza(s: String): Pair<String, String>? {
        val start = s.indexOf('<')
        if (start < 0) return null
        val after = s.substring(start)
        val selfClosing = after.indexOf("/>")
        val firstGt = after.indexOf('>')
        if (selfClosing >= 0 && (firstGt < 0 || selfClosing < firstGt)) {
            val total = selfClosing + 2
            return after.substring(0, total) to (s.substring(0, start) + after.substring(total))
        }
        val closeOpen = after.indexOf('>')
        if (closeOpen < 0) return null
        var tagName = after.substring(1, closeOpen)
        val sp = tagName.indexOfFirst { it == ' ' || it == '\t' }
        if (sp >= 0) tagName = tagName.substring(0, sp)
        tagName = tagName.trimEnd('/')
        val closeTag = "</$tagName>"
        val end = after.indexOf(closeTag)
        if (end < 0) return null
        val total = end + closeTag.length
        return after.substring(0, total) to (s.substring(0, start) + after.substring(total))
    }

    private fun trustAllFactory(): javax.net.ssl.SSLSocketFactory {
        val tm = arrayOf<TrustManager>(object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {}
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {}
            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        })
        val ctx = SSLContext.getInstance("TLS")
        ctx.init(null, tm, SecureRandom())
        return ctx.socketFactory
    }
}
