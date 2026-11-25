package cu.todus.relayvpn

import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.Semaphore
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * SOCKS5 local sobre el túnel WebRTC del rtcvpn-server (antes: relay de
 * objetos S3 de ToDus).
 *
 *  CONNECT → RtcController.openStream(host, port) → frame OPEN del servidor
 *  → OPENED/ERR → pipe bidireccional con frames DATA/CLOSE.
 *
 * Se conserva del puerto original (movil_proxy.py / APK Kotlin):
 *  - Semáforo de sesiones (`maxSessions`): rechazo inmediato en saturación.
 *  - Batching de subida TCP: los read() pequeños se acumulan durante
 *    `tcpBatchDelayMs` (o hasta `tcpBatchMaxBytes`) y se envían como un único
 *    frame DATA — SCTP agradece los mensajes grandes.
 *
 * UDP ASSOCIATE ya no se ofrece (el server RTC solo diala TCP): el tráfico
 * UDP del TUN lo gestiona UdpTunnel (DNS por TCP dentro del túnel + reenvío
 * directo del resto).
 */
class SocksServer(
    private val settings: RelaySettings,
    private val rtc: RtcController,
    private val stats: VpnStats,
) {
    private var server: ServerSocket? = null
    private var acceptThread: Thread? = null
    private val activeSessions = AtomicInteger(0)
    @Volatile var running = false
        private set

    private lateinit var pool: ThreadPoolExecutor

    private val sessionSemaphore = Semaphore(settings.maxSessions.coerceAtLeast(1), false)

    fun start() {
        val address = InetAddress.getByName(settings.socksHost)
        server = ServerSocket(settings.socksPort, settings.maxSessions.coerceAtLeast(16), address)
        val threads = settings.maxSessions.coerceAtLeast(2)
        pool = ThreadPoolExecutor(
            threads, threads, 30, TimeUnit.SECONDS,
            LinkedBlockingQueue<Runnable>(threads * 2),
        ) { r -> Thread(r, "socks-sesion-${threadCounter.incrementAndGet()}") }
        running = true
        AppLog.i(
            "[*] SOCKS5 ToDus RTC en ${settings.socksHost}:${settings.socksPort} | " +
                "maxSesiones=${settings.maxSessions} | batch=${settings.tcpBatchDelayMs}ms/${settings.tcpBatchMaxBytes}B"
        )
        acceptThread = thread(name = "socks-accept") { acceptLoop() }
    }

    fun stop() {
        running = false
        try {
            server?.close()
        } catch (e: IOException) {
            // ya cerrado
        }
        pool.shutdownNow()
    }

    private fun acceptLoop() {
        val listener = server ?: return
        while (running) {
            try {
                val client = listener.accept()
                try {
                    pool.execute { handleClient(client) }
                } catch (e: java.util.concurrent.RejectedExecutionException) {
                    stats.sessionsRejectedByLimit.incrementAndGet()
                    try { client.close() } catch (_: IOException) {}
                }
            } catch (e: IOException) {
                if (running) AppLog.w("[socks] accept: ${e.message}")
            }
        }
    }

    // ---------------------------------------------------------------- utilidades

    private fun readFully(input: InputStream, count: Int): ByteArray {
        val out = ByteArray(count)
        var read = 0
        while (read < count) {
            val n = input.read(out, read, count - read)
            if (n < 0) throw EOFException("el cliente cerró durante el saludo SOCKS5")
            read += n
        }
        return out
    }

    private fun readSocksAddress(input: InputStream, atyp: Int): String {
        when (atyp) {
            1 -> {
                val raw = readFully(input, 4)
                return raw.joinToString(".") { (it.toInt() and 0xFF).toString() }
            }
            3 -> {
                val size = readFully(input, 1)[0].toInt() and 0xFF
                if (size == 0) throw IOException("hostname SOCKS5 vacío")
                return String(readFully(input, size), Charsets.US_ASCII)
            }
            4 -> {
                val raw = readFully(input, 16)
                val groups = IntArray(8)
                for (i in 0 until 8) {
                    groups[i] = ((raw[i * 2].toInt() and 0xFF) shl 8) or (raw[i * 2 + 1].toInt() and 0xFF)
                }
                return formatIpv6(groups)
            }
        }
        throw IOException("ATYP SOCKS5 no soportado")
    }

    private fun formatIpv6(groups: IntArray): String {
        var bestStart = -1
        var bestLen = 0
        var runStart = -1
        for (i in groups.indices) {
            if (groups[i] == 0) {
                if (runStart < 0) runStart = i
                val len = i - runStart + 1
                if (len > bestLen) {
                    bestLen = len
                    bestStart = runStart
                }
            } else {
                runStart = -1
            }
        }
        if (bestLen < 2) return groups.joinToString(":") { String.format("%x", it) }
        val left = groups.copyOfRange(0, bestStart).joinToString(":") { String.format("%x", it) }
        val right = groups.copyOfRange(bestStart + bestLen, groups.size).joinToString(":") { String.format("%x", it) }
        return "$left::$right"
    }

    private fun replyFailure(output: OutputStream, code: Int) {
        output.write(byteArrayOf(0x05, code.toByte(), 0x00, 0x01, 0, 0, 0, 0, 0, 0))
    }

    private fun sleepQuiet(ms: Long) {
        try {
            Thread.sleep(ms)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    // ---------------------------------------------------------------- CONNECT (TCP)

    private fun handleClient(sock: Socket) {
        val sessionTag = "s${System.identityHashCode(sock) and 0xFFFF}"
        if (!sessionSemaphore.tryAcquire()) {
            stats.sessionsRejectedByLimit.incrementAndGet()
            try {
                sock.soTimeout = 3_000
                val output = sock.getOutputStream()
                val input = sock.getInputStream()
                try {
                    val greeting = readFully(input, 2)
                    if (greeting[0] == 0x05.toByte() && greeting[1] > 0) {
                        readFully(input, greeting[1].toInt())
                        output.write(byteArrayOf(0x05, 0x00))
                        readFully(input, 4)
                    }
                } catch (_: Exception) { /* sin tiempo */ }
                replyFailure(output, 1)
            } catch (_: Exception) { /* socket roto */ } finally {
                try { sock.close() } catch (_: IOException) {}
            }
            return
        }
        activeSessions.incrementAndGet()
        try {
            sock.soTimeout = 10_000
            sock.tcpNoDelay = true
            val input = sock.getInputStream()
            val output = sock.getOutputStream()

            val greeting = readFully(input, 2)
            if (greeting[0] != 0x05.toByte() || greeting[1] == 0x00.toByte()) return
            val methods = readFully(input, greeting[1].toInt())
            if (!methods.contains(0x00.toByte())) {
                output.write(byteArrayOf(0x05, 0xFF.toByte()))
                return
            }
            output.write(byteArrayOf(0x05, 0x00))

            val request = readFully(input, 4)
            val version = request[0].toInt() and 0xFF
            val command = request[1].toInt() and 0xFF
            val atyp = request[3].toInt() and 0xFF
            if (version != 5) return
            val requestedHost = readSocksAddress(input, atyp)
            val portBytes = readFully(input, 2)
            val requestedPort = ((portBytes[0].toInt() and 0xFF) shl 8) or (portBytes[1].toInt() and 0xFF)

            if (command == 3) {
                // UDP ASSOCIATE: no soportado por el server RTC (solo TCP).
                replyFailure(output, 1)
                return
            }
            if (command != 1) {
                replyFailure(output, 7)
                return
            }
            if (requestedPort !in 1..65535) {
                replyFailure(output, 1)
                return
            }

            stats.tcpSessionsTotal.incrementAndGet()
            AppLog.i("[+] CONNECT $requestedHost:$requestedPort [$sessionTag]")
            val stream = try {
                rtc.openStream(requestedHost, requestedPort, (settings.connectTimeout * 1000).toLong())
            } catch (e: RtcController.StreamException) {
                AppLog.w("[-] $requestedHost:$requestedPort → SOCKS ${e.socksReply} (${e.message}) [$sessionTag]")
                replyFailure(output, e.socksReply)
                return
            } catch (e: Exception) {
                AppLog.w("[-] $requestedHost:$requestedPort → ${e.message} [$sessionTag]")
                replyFailure(output, 1)
                return
            }
            stats.rtcStreamsOpened.incrementAndGet()
            stats.tcpSessionsActive.incrementAndGet()
            output.write(byteArrayOf(0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
            try {
                pipeClient(sock, stream, sessionTag)
            } finally {
                stats.tcpSessionsActive.decrementAndGet()
            }
        } catch (e: Exception) {
            AppLog.w("[cliente $sessionTag] ${e.message}")
        } finally {
            activeSessions.decrementAndGet()
            sessionSemaphore.release()
            try {
                sock.close()
            } catch (e: IOException) {
                // ignorar
            }
        }
    }

    /** Pipe bidireccional socket ↔ stream del túnel RTC (con batching de subida). */
    private fun pipeClient(sock: Socket, stream: RtcController.RtcStream, tag: String) {
        val stopped = AtomicBoolean(false)
        val uplinkDone = AtomicBoolean(false)
        val downlinkDone = AtomicBoolean(false)

        sock.soTimeout = 250

        val uplink = thread(name = "c2s-$tag", isDaemon = true) {
            try {
                val input = sock.getInputStream()
                val buffer = ByteArray(65536)
                // Batching: acumular reads pequeños y volcarlos como un DATA
                // único (menos frames SCTP, menos sobrecarga).
                val batch = ByteArrayOutputStream(settings.tcpBatchMaxBytes)
                var batchStartedAt = 0L
                val batchDeadlineMs = settings.tcpBatchDelayMs.toLong()
                val batchMaxBytes = settings.tcpBatchMaxBytes

                fun flushBatch(): Boolean {
                    if (batch.size() == 0) return true
                    val payload = batch.toByteArray()
                    batch.reset()
                    batchStartedAt = 0L
                    if (payload.size >= batchMaxBytes / 2) stats.tcpBatchesSent.incrementAndGet()
                    try {
                        stream.write(payload)
                    } catch (e: Exception) {
                        return false
                    }
                    return true
                }

                while (!stopped.get() && !stream.isClosed) {
                    val n = try {
                        input.read(buffer)
                    } catch (e: SocketTimeoutException) {
                        if (batch.size() > 0 &&
                            System.currentTimeMillis() - batchStartedAt >= batchDeadlineMs
                        ) {
                            if (!flushBatch()) break
                        }
                        continue
                    }
                    if (n < 0) {
                        flushBatch()
                        break
                    }
                    if (n == 0) continue
                    if (batch.size() == 0) batchStartedAt = System.currentTimeMillis()
                    batch.write(buffer, 0, n)
                    if (batch.size() >= batchMaxBytes ||
                        System.currentTimeMillis() - batchStartedAt >= batchDeadlineMs
                    ) {
                        if (!flushBatch()) break
                    }
                }
                flushBatch()
                // EOF del cliente: medio-cierre del stream del túnel.
                try { stream.close() } catch (e: Exception) {}
            } catch (e: Exception) {
                AppLog.w("[subida $tag] ${e.message}")
                stopped.set(true)
            } finally {
                uplinkDone.set(true)
            }
        }

        val downlink = thread(name = "s2c-$tag", isDaemon = true) {
            try {
                val output = sock.getOutputStream()
                while (!stopped.get() && !stream.isClosed) {
                    val chunk = stream.read(250) ?: break
                    if (chunk.isEmpty()) continue
                    output.write(chunk)
                }
            } catch (e: Exception) {
                AppLog.w("[descarga $tag] ${e.message}")
                stopped.set(true)
            } finally {
                downlinkDone.set(true)
            }
        }

        while (!stopped.get()) {
            if (uplinkDone.get() && downlinkDone.get()) break
            if (stream.isClosed && (uplinkDone.get() || downlinkDone.get())) {
                // El server cerró su lado: esperar brevemente al otro hilo y salir.
                sleepQuiet(300)
                break
            }
            sleepQuiet(100)
        }
        stopped.set(true)
        try { stream.close() } catch (e: Exception) {}
        try { sock.close() } catch (e: IOException) {}
        AppLog.d("[-] cerrada sesión $tag")
    }

    companion object {
        private val threadCounter = AtomicInteger(0)
    }
}
