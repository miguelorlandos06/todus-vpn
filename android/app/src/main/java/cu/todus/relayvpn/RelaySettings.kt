package cu.todus.relayvpn

import android.content.Context
import android.content.SharedPreferences

/**
 * Configuración del túnel relay.
 *
 * Originalmente todos los parámetros estaban hardcodeados para "ultra rendimiento"
 * (poll a 10 ms, 256 sesiones, lotes UDP de 1 ms…). En redes inestables con rate
 * limit eso producía tormentas de peticiones, bucles de reconexión y saturación
 * de la API ToDus. Esta versión:
 *
 *  - Parte de valores por defecto estables (priorizan batería y estabilidad).
 *  - Persiste los parámetros ajustables en SharedPreferences para que la UI Flutter
 *    pueda modificarlos sin recompilar.
 *  - Expone controles de resiliencia: backoff, semáforo HTTP, batching TCP.
 *  - Permite filtrar apps (addAllowedApplication) en lugar de enrutar todo el
 *    teléfono.
 */
data class RelaySettings(
    val baseUrl: String,                 // (legacy relay S3; no se usa en RTC)
    val rtcServer: String,               // URL manual del rtcvpn-server (vacío = auto-descubrimiento)
    val hostHeader: String?,             // TODUS_HOST_HEADER (legacy)
    val sharedSecret: ByteArray,          // PROXY_SHARED_SECRET (legacy)
    val verifyTls: Boolean,               // TODUS_VERIFY_TLS (legacy)
    val socksHost: String,                // SOCKS_HOST
    val socksPort: Int,                   // SOCKS_PORT
    val pollInterval: Double,             // POLL_INTERVAL (s)
    val chunkSize: Int,                   // CHUNK_SIZE
    val windowSize: Int,                  // WINDOW_SIZE
    val ackEvery: Int,                    // ACK_EVERY
    val httpTimeout: Double,              // HTTP_TIMEOUT (s)
    val httpRetries: Int,                 // HTTP_RETRIES
    val connectTimeout: Double,           // CONNECT_TIMEOUT (s)
    val queuePollInterval: Double,        // QUEUE_POLL_INTERVAL (s)
    val maxSessions: Int,                 // MAX_SESSIONS
    val udpBatchCount: Int,               // UDP_BATCH_COUNT
    val udpBatchDelayMs: Int,             // UDP_BATCH_DELAY_MS
    val udpBatchMaxBytes: Int,            // UDP_BATCH_MAX_BYTES
    val udpIdleTimeout: Double,           // UDP_IDLE_TIMEOUT (s)
    val udpMaxFlows: Int,                 // UDP_MAX_FLOWS
    val udpMaxPacketSize: Int,            // UDP_MAX_PACKET_SIZE
    val udpPollInterval: Double,          // UDP_POLL_INTERVAL (s)
    val udpUploadWorkers: Int,            // UDP_UPLOAD_WORKERS
    val deleteAfterRead: Boolean,         // TODUS_DELETE_AFTER_READ
    val encryptionEnabled: Boolean,       // ENCRYPTION_ENABLED (sobre TDS3 + AES-GCM)
    val remoteDns: List<String>,          // DNS remotas
    val ipv6Enabled: Boolean,             // capturar ::/0
    // --- Estabilidad / resiliencia (nuevos) ---
    val maxConcurrentHttp: Int,           // tope de PUT/GET simultáneos (semáforo)
    val backoffInitialMs: Long,           // primer espera tras fallo (ms)
    val backoffMaxMs: Long,               // tope superior del backoff (ms)
    val backoffFactor: Double,            // multiplicador exponencial (2.0 = 1s,2s,4s…)
    val backoffJitterMs: Long,            // jitter aleatorio añadido (ms)
    val circuitFailThreshold: Int,        // fallos consecutivos que abren el circuito
    val circuitOpenMs: Long,              // tiempo con el circuito abierto (ms)
    val tcpBatchDelayMs: Int,             // agrupar TCP durante N ms antes de PUT
    val tcpBatchMaxBytes: Int,            // tamaño máx del bloque TCP acumulado
    val allowedApps: List<String>,        // si no vacía, solo estas apps pasan por la VPN
) {
    companion object {
        private const val PREFS = "relay_settings"

        class SettingsException(message: String) : Exception(message)

        // Clave compartida sincronizada con la VPS (rotada en v1.4 junto con el
        // cambio de bucket/prefijo; configurable en Ajustes → «Conexión y seguridad»).
        const val DEFAULT_SECRET_HEX = "5a3ec890b66067c19a187bb7e117c0f11dd8b3e166bab00d9d96117479b52b24"
        // Bucket/prefijo NUEVO del buzón (antes …/public/dk/proxy_lab).
        const val DEFAULT_BASE_URL = "https://s3.todus.cu/stickers/tr/proxy"
        const val DEFAULT_HOST_HEADER = "status.todus.cu"
        const val DEFAULT_VERIFY_TLS = false
        const val DEFAULT_SOCKS_PORT = 1080
        const val DEFAULT_DNS = "8.8.8.8, 1.1.1.1"
        const val DEFAULT_IPV6 = false

        // ────────────────────────────────────────────────────────────────
        //  Valores por defecto orientados a ESTABILIDAD (no a velocidad).
        //  Antes: POLL=10ms, MAX_SESSIONS=256, UDP_POLL=10ms.
        //  Ahora: POLL=1s, MAX_SESSIONS=10, UDP_POLL=100ms, BATCH_DELAY=50ms.
        // ────────────────────────────────────────────────────────────────
        const val DEFAULT_CHUNK_SIZE = 524288           // 512 KiB (antes 1 MiB)
        const val DEFAULT_WINDOW_SIZE = 16               // 16 bloques en vuelo (antes 32)
        const val DEFAULT_ACK_EVERY = 4
        const val DEFAULT_POLL_INTERVAL = 1.0             // 1 s (antes 0.01 = 10 ms)
        const val DEFAULT_HTTP_TIMEOUT = 20.0
        const val DEFAULT_HTTP_RETRIES = 4                // más reintentos con backoff
        const val DEFAULT_CONNECT_TIMEOUT = 25.0
        const val DEFAULT_QUEUE_POLL_INTERVAL = 0.5       // 500 ms (antes 50 ms)
        const val DEFAULT_MAX_SESSIONS = 10              // tope de sesiones simultáneas
        const val DEFAULT_UDP_BATCH_COUNT = 64
        const val DEFAULT_UDP_BATCH_DELAY_MS = 50         // 50 ms (antes 1 ms)
        const val DEFAULT_UDP_BATCH_MAX_BYTES = 131072    // 128 KiB
        const val DEFAULT_UDP_IDLE_TIMEOUT = 180.0
        const val DEFAULT_UDP_MAX_FLOWS = 128             // antes 512
        const val DEFAULT_UDP_MAX_PACKET_SIZE = 65507
        const val DEFAULT_UDP_POLL_INTERVAL = 0.1         // 100 ms (antes 10 ms)
        const val DEFAULT_UDP_UPLOAD_WORKERS = 4          // antes 8
        const val DEFAULT_DELETE_AFTER_READ = false
        const val DEFAULT_ENCRYPTION_ENABLED = true   // TDS3 + AES-GCM (igual que servidor Go)

        // Resiliencia (nuevos).
        const val DEFAULT_MAX_CONCURRENT_HTTP = 8
        const val DEFAULT_BACKOFF_INITIAL_MS = 1000L      // 1 s
        const val DEFAULT_BACKOFF_MAX_MS = 30000L         // 30 s
        const val DEFAULT_BACKOFF_FACTOR = 2.0
        const val DEFAULT_BACKOFF_JITTER_MS = 250L
        const val DEFAULT_CIRCUIT_FAIL_THRESHOLD = 8
        const val DEFAULT_CIRCUIT_OPEN_MS = 15000L
        const val DEFAULT_TCP_BATCH_DELAY_MS = 50
        const val DEFAULT_TCP_BATCH_MAX_BYTES = 65536     // 64 KiB

        // Claves en SharedPreferences (públicas para que la UI las lea/escriba).
        const val KEY_POLL_INTERVAL = "poll_interval"
        const val KEY_CHUNK_SIZE = "chunk_size"
        const val KEY_MAX_SESSIONS = "max_sessions"
        const val KEY_WINDOW_SIZE = "window_size"
        const val KEY_ACK_EVERY = "ack_every"
        const val KEY_HTTP_RETRIES = "http_retries"
        const val KEY_HTTP_TIMEOUT = "http_timeout"
        const val KEY_CONNECT_TIMEOUT = "connect_timeout"
        const val KEY_QUEUE_POLL_INTERVAL = "queue_poll_interval"
        const val KEY_UDP_BATCH_COUNT = "udp_batch_count"
        const val KEY_UDP_BATCH_DELAY_MS = "udp_batch_delay_ms"
        const val KEY_UDP_BATCH_MAX_BYTES = "udp_batch_max_bytes"
        const val KEY_UDP_IDLE_TIMEOUT = "udp_idle_timeout"
        const val KEY_UDP_MAX_FLOWS = "udp_max_flows"
        const val KEY_UDP_POLL_INTERVAL = "udp_poll_interval"
        const val KEY_UDP_UPLOAD_WORKERS = "udp_upload_workers"
        const val KEY_DELETE_AFTER_READ = "delete_after_read"
        const val KEY_ENCRYPTION_ENABLED = "encryption_enabled"
        const val KEY_MAX_CONCURRENT_HTTP = "max_concurrent_http"
        const val KEY_BACKOFF_INITIAL_MS = "backoff_initial_ms"
        const val KEY_BACKOFF_MAX_MS = "backoff_max_ms"
        const val KEY_BACKOFF_FACTOR = "backoff_factor"
        const val KEY_BACKOFF_JITTER_MS = "backoff_jitter_ms"
        const val KEY_CIRCUIT_FAIL_THRESHOLD = "circuit_fail_threshold"
        const val KEY_CIRCUIT_OPEN_MS = "circuit_open_ms"
        const val KEY_TCP_BATCH_DELAY_MS = "tcp_batch_delay_ms"
        const val KEY_TCP_BATCH_MAX_BYTES = "tcp_batch_max_bytes"
        const val KEY_ALLOWED_APPS = "allowed_apps"
        const val KEY_IPV6 = "ipv6_enabled"
        // Conexión y seguridad (nuevos en v1.4).
        const val KEY_RELAY_SECRET = "relay_secret"
        const val KEY_BASE_URL = "base_url"
        // Servidor RTC (WebRTC). Vacío = auto-descubrimiento vía GitHub raw.
        const val KEY_RTC_SERVER = "rtc_server"

        private val HEX64 = Regex("^[0-9a-fA-F]{64}$")

        // Claves que fromPrefs lee como Long (milisegundos). El MethodChannel
        // entrega los números pequeños de Dart como java.lang.Integer, así que
        // estas claves deben NORMALIZARSE a Long al guardar y al leer (si no,
        // aparece el ClassCastException «Integer cannot be cast to Long» al
        // arrancar la VPN).
        private val LONG_KEYS = setOf(
            KEY_BACKOFF_INITIAL_MS,
            KEY_BACKOFF_MAX_MS,
            KEY_BACKOFF_JITTER_MS,
            KEY_CIRCUIT_OPEN_MS,
        )

        /**
         * Lectura tolerante de un Long en SharedPreferences: acepta valores
         * legados almacenados como Int por una versión anterior (el MethodChannel
         * nunca entrega Int pequeños como Long) y regraba el valor normalizado
         * a Long para que el problema no se repita en el siguiente arranque.
         */
        private fun getLongCompat(p: SharedPreferences, key: String, def: Long): Long =
            try {
                p.getLong(key, def)
            } catch (e: ClassCastException) {
                val asInt = try {
                    p.getInt(key, def.toInt())
                } catch (e: ClassCastException) {
                    def.toInt()
                }
                asInt.toLong().also { p.edit().putLong(key, it).apply() }
            }

        fun prefs(context: Context): SharedPreferences =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        /**
         * Valida que una cadena sea una IP (v4 o v6) para usarla como DNS del
         * TUN. Devuelve sus bytes o null. (Antes RelayProtocol.parseIpAddress.)
         */
        fun parseIpForDns(s: String): ByteArray? {
            return try {
                val addr = java.net.InetAddress.getByName(s)
                if (addr.hostAddress == s || s.contains(":")) addr.address else null
            } catch (e: Exception) {
                null
            }
        }

        /**
         * Convierte la clave escrita por el usuario en los bytes del HMAC:
         *  - 64 caracteres hexadecimales → se usan tal cual (32 bytes).
         *  - Cualquier otra frase → SHA-256 de la frase (32 bytes), con la MISMA
         *    regla que implementan los servidores FastAPI y Go, de modo que
         *    «misma frase en ambos lados» = «misma clave».
         *  - Vacío → clave interna por defecto de la app.
         */
        fun resolveSecret(input: String?): ByteArray {
            val value = input?.trim() ?: ""
            if (value.isEmpty()) return hexToBytes(DEFAULT_SECRET_HEX)
            if (HEX64.matches(value)) return hexToBytes(value)
            val digest = java.security.MessageDigest
                .getInstance("SHA-256")
                .digest(value.toByteArray(Charsets.UTF_8))
            return digest
        }

        fun bytesToHex(bytes: ByteArray): String =
            bytes.joinToString("") { String.format("%02x", it) }

        /**
         * Lee la configuración ajustable desde SharedPreferences; el Host y el
         * resto de parámetros de red siguen por defecto (secreto y URL del buzón
         * ahora se pueden sobreescribir desde la UI).
         */
        fun fromPrefs(context: Context): RelaySettings {
            val p = prefs(context)
            val secret = resolveSecret(p.getString(KEY_RELAY_SECRET, ""))
            val allowedAppsRaw = p.getString(KEY_ALLOWED_APPS, "") ?: ""
            val allowedApps = allowedAppsRaw.split("\n").map { it.trim() }.filter { it.isNotEmpty() }
            return RelaySettings(
                baseUrl = p.getString(KEY_BASE_URL, "")?.trim().takeUnless { it.isNullOrEmpty() }
                    ?: DEFAULT_BASE_URL,
                rtcServer = p.getString(KEY_RTC_SERVER, "")?.trim() ?: "",
                hostHeader = DEFAULT_HOST_HEADER,
                sharedSecret = secret,
                verifyTls = DEFAULT_VERIFY_TLS,
                socksHost = "127.0.0.1",
                socksPort = DEFAULT_SOCKS_PORT,
                pollInterval = p.getString(KEY_POLL_INTERVAL, DEFAULT_POLL_INTERVAL.toString())?.toDoubleOrNull()
                    ?: DEFAULT_POLL_INTERVAL,
                chunkSize = p.getInt(KEY_CHUNK_SIZE, DEFAULT_CHUNK_SIZE),
                windowSize = p.getInt(KEY_WINDOW_SIZE, DEFAULT_WINDOW_SIZE),
                ackEvery = p.getInt(KEY_ACK_EVERY, DEFAULT_ACK_EVERY),
                httpTimeout = p.getString(KEY_HTTP_TIMEOUT, DEFAULT_HTTP_TIMEOUT.toString())?.toDoubleOrNull()
                    ?: DEFAULT_HTTP_TIMEOUT,
                httpRetries = p.getInt(KEY_HTTP_RETRIES, DEFAULT_HTTP_RETRIES),
                connectTimeout = p.getString(KEY_CONNECT_TIMEOUT, DEFAULT_CONNECT_TIMEOUT.toString())?.toDoubleOrNull()
                    ?: DEFAULT_CONNECT_TIMEOUT,
                queuePollInterval = p.getString(KEY_QUEUE_POLL_INTERVAL, DEFAULT_QUEUE_POLL_INTERVAL.toString())?.toDoubleOrNull()
                    ?: DEFAULT_QUEUE_POLL_INTERVAL,
                maxSessions = p.getInt(KEY_MAX_SESSIONS, DEFAULT_MAX_SESSIONS),
                udpBatchCount = p.getInt(KEY_UDP_BATCH_COUNT, DEFAULT_UDP_BATCH_COUNT),
                udpBatchDelayMs = p.getInt(KEY_UDP_BATCH_DELAY_MS, DEFAULT_UDP_BATCH_DELAY_MS),
                udpBatchMaxBytes = p.getInt(KEY_UDP_BATCH_MAX_BYTES, DEFAULT_UDP_BATCH_MAX_BYTES),
                udpIdleTimeout = p.getString(KEY_UDP_IDLE_TIMEOUT, DEFAULT_UDP_IDLE_TIMEOUT.toString())?.toDoubleOrNull()
                    ?: DEFAULT_UDP_IDLE_TIMEOUT,
                udpMaxFlows = p.getInt(KEY_UDP_MAX_FLOWS, DEFAULT_UDP_MAX_FLOWS),
                udpMaxPacketSize = DEFAULT_UDP_MAX_PACKET_SIZE,
                udpPollInterval = p.getString(KEY_UDP_POLL_INTERVAL, DEFAULT_UDP_POLL_INTERVAL.toString())?.toDoubleOrNull()
                    ?: DEFAULT_UDP_POLL_INTERVAL,
                udpUploadWorkers = p.getInt(KEY_UDP_UPLOAD_WORKERS, DEFAULT_UDP_UPLOAD_WORKERS),
                deleteAfterRead = p.getBoolean(KEY_DELETE_AFTER_READ, DEFAULT_DELETE_AFTER_READ),
                encryptionEnabled = p.getBoolean(KEY_ENCRYPTION_ENABLED, DEFAULT_ENCRYPTION_ENABLED),
                remoteDns = listOf("8.8.8.8", "1.1.1.1"),
                ipv6Enabled = p.getBoolean(KEY_IPV6, DEFAULT_IPV6),
                maxConcurrentHttp = p.getInt(KEY_MAX_CONCURRENT_HTTP, DEFAULT_MAX_CONCURRENT_HTTP),
                backoffInitialMs = getLongCompat(p, KEY_BACKOFF_INITIAL_MS, DEFAULT_BACKOFF_INITIAL_MS),
                backoffMaxMs = getLongCompat(p, KEY_BACKOFF_MAX_MS, DEFAULT_BACKOFF_MAX_MS),
                backoffFactor = p.getString(KEY_BACKOFF_FACTOR, DEFAULT_BACKOFF_FACTOR.toString())?.toDoubleOrNull()
                    ?: DEFAULT_BACKOFF_FACTOR,
                backoffJitterMs = getLongCompat(p, KEY_BACKOFF_JITTER_MS, DEFAULT_BACKOFF_JITTER_MS),
                circuitFailThreshold = p.getInt(KEY_CIRCUIT_FAIL_THRESHOLD, DEFAULT_CIRCUIT_FAIL_THRESHOLD),
                circuitOpenMs = getLongCompat(p, KEY_CIRCUIT_OPEN_MS, DEFAULT_CIRCUIT_OPEN_MS),
                tcpBatchDelayMs = p.getInt(KEY_TCP_BATCH_DELAY_MS, DEFAULT_TCP_BATCH_DELAY_MS),
                tcpBatchMaxBytes = p.getInt(KEY_TCP_BATCH_MAX_BYTES, DEFAULT_TCP_BATCH_MAX_BYTES),
                allowedApps = allowedApps,
            )
        }

        /** Snapshot de los campos ajustables para enviar a Flutter. */
        fun snapshot(context: Context): Map<String, Any> {
            val s = fromPrefs(context)
            return mapOf(
                KEY_POLL_INTERVAL to s.pollInterval,
                KEY_CHUNK_SIZE to s.chunkSize,
                KEY_MAX_SESSIONS to s.maxSessions,
                KEY_WINDOW_SIZE to s.windowSize,
                KEY_ACK_EVERY to s.ackEvery,
                KEY_HTTP_RETRIES to s.httpRetries,
                KEY_HTTP_TIMEOUT to s.httpTimeout,
                KEY_CONNECT_TIMEOUT to s.connectTimeout,
                KEY_QUEUE_POLL_INTERVAL to s.queuePollInterval,
                KEY_UDP_BATCH_COUNT to s.udpBatchCount,
                KEY_UDP_BATCH_DELAY_MS to s.udpBatchDelayMs,
                KEY_UDP_BATCH_MAX_BYTES to s.udpBatchMaxBytes,
                KEY_UDP_IDLE_TIMEOUT to s.udpIdleTimeout,
                KEY_UDP_MAX_FLOWS to s.udpMaxFlows,
                KEY_UDP_POLL_INTERVAL to s.udpPollInterval,
                KEY_UDP_UPLOAD_WORKERS to s.udpUploadWorkers,
                KEY_DELETE_AFTER_READ to s.deleteAfterRead,
                KEY_ENCRYPTION_ENABLED to s.encryptionEnabled,
                KEY_MAX_CONCURRENT_HTTP to s.maxConcurrentHttp,
                KEY_BACKOFF_INITIAL_MS to s.backoffInitialMs,
                KEY_BACKOFF_MAX_MS to s.backoffMaxMs,
                KEY_BACKOFF_FACTOR to s.backoffFactor,
                KEY_BACKOFF_JITTER_MS to s.backoffJitterMs,
                KEY_CIRCUIT_FAIL_THRESHOLD to s.circuitFailThreshold,
                KEY_CIRCUIT_OPEN_MS to s.circuitOpenMs,
                KEY_TCP_BATCH_DELAY_MS to s.tcpBatchDelayMs,
                KEY_TCP_BATCH_MAX_BYTES to s.tcpBatchMaxBytes,
                KEY_ALLOWED_APPS to s.allowedApps.joinToString("\n"),
                KEY_IPV6 to s.ipv6Enabled,
                // Conexión y seguridad: valor guardado (vacío = interno) + hex
                // efectivo para copiar al servidor.
                KEY_RELAY_SECRET to (prefs(context).getString(KEY_RELAY_SECRET, "") ?: ""),
                KEY_BASE_URL to (prefs(context).getString(KEY_BASE_URL, "") ?: ""),
                "relay_secret_effective" to bytesToHex(s.sharedSecret),
                KEY_RTC_SERVER to s.rtcServer,
            )
        }

        /** Persiste un mapa parcial proveniente de la UI Flutter. */
        fun apply(context: Context, values: Map<String, Any>): RelaySettings {
            val p = prefs(context)
            p.edit().apply {
                values.forEach { (k, v) ->
                    when (v) {
                        is Boolean -> putBoolean(k, v)
                        // Las claves Long (backoff/circuito) se normalizan SIEMPRE
                        // a putLong aunque Dart las entregue como Integer.
                        is Int -> if (k in LONG_KEYS) putLong(k, v.toLong()) else putInt(k, v)
                        is Long -> putLong(k, v)
                        is Number -> {
                            // Doble o Float → String para no perder precisión.
                            when (k) {
                                KEY_POLL_INTERVAL, KEY_HTTP_TIMEOUT, KEY_CONNECT_TIMEOUT,
                                KEY_QUEUE_POLL_INTERVAL, KEY_UDP_IDLE_TIMEOUT,
                                KEY_UDP_POLL_INTERVAL, KEY_BACKOFF_FACTOR,
                                -> putString(k, v.toString())
                                else ->
                                    if (k in LONG_KEYS) putLong(k, v.toLong())
                                    else putInt(k, v.toInt())
                            }
                        }
                        is String -> putString(k, v)
                        else -> { /* tipo no soportado: ignorar */ }
                    }
                }
            }.apply()
            return fromPrefs(context)
        }

        fun hexToBytes(hex: String): ByteArray {
            require(hex.length % 2 == 0) { "hex impar" }
            val out = ByteArray(hex.length / 2)
            for (i in out.indices) {
                val hi = Character.digit(hex[i * 2], 16)
                val lo = Character.digit(hex[i * 2 + 1], 16)
                require(hi >= 0 && lo >= 0) { "carácter no hexadecimal" }
                out[i] = ((hi shl 4) or lo).toByte()
            }
            return out
        }
    }
}
