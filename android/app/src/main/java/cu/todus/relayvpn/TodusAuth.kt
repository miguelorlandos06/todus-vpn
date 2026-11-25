package cu.todus.relayvpn

import android.content.Context
import android.content.SharedPreferences
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.TimeUnit

/**
 * Cuenta toDus del usuario de la APK + login JWT contra auth.todus.cu.
 *
 * Flujo (idéntico al del servidor rtcvpn-server, todus.go):
 *  1. POST https://auth.todus.cu/v2/auth/token
 *     Content-Type: application/octet-stream, User-Agent: ToDus 2.1.1
 *     Cuerpo protobuf: campo 1 = teléfono (10 dígitos), campo 2 = secreto.
 *  2. La respuesta contiene el JWT (se extrae con la misma regexp que el
 *     servidor Go: eyJxxx.yyy.zzz).
 *
 * El secreto se genera UNA VEZ por teléfono con 32 caracteres aleatorios y se
 * persiste, de modo que la cuenta siga siendo accesible en reconexiones
 * posteriores (el servidor de toDus asocia el secreto a la cuenta).
 */
object TodusAuth {

    private const val PREFS = "todus_account"
    private const val KEY_PHONE = "phone"
    private const val KEY_SECRET = "secret"
    private const val KEY_JWT = "jwt"
    private const val KEY_JWT_EXP = "jwt_exp"

    const val AUTH_URL = "https://auth.todus.cu/v2/auth/token"
    private const val OCTET_STREAM = "application/octet-stream; charset=utf-8"
    private val JWT_RE = Regex("eyJ[a-zA-Z0-9_-]+\\.[a-zA-Z0-9_-]+\\.[a-zA-Z0-9_-]+")
    private val ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

    data class Account(
        val phone: String,          // 10 dígitos nacionales (53XXXXXXXX)
        val secret: String,         // 32 caracteres aleatorios (persistido)
        val jwt: String,            // token actual (vacío si falta)
        val jwtExp: Long,           // exp unix (segundos); 0 si desconocido
    ) {
        val jid: String get() = "$phone@im.todus.cu"
        fun jwtValid(nowSec: Long = System.currentTimeMillis() / 1000): Boolean =
            jwt.isNotEmpty() && (jwtExp == 0L || nowSec < jwtExp - 300)
    }

    fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Cuenta guardada (null si nunca se ha iniciado sesión). */
    fun load(context: Context): Account? {
        val p = prefs(context)
        val phone = p.getString(KEY_PHONE, null)?.trim().orEmpty()
        if (phone.isEmpty()) return null
        return Account(
            phone = phone,
            secret = p.getString(KEY_SECRET, "").orEmpty(),
            jwt = p.getString(KEY_JWT, "").orEmpty(),
            jwtExp = p.getLong(KEY_JWT_EXP, 0L),
        )
    }

    /**
     * Inicio de sesión desde la pantalla «Ingresar número».
     * Recibe los 8 dígitos locales (el +53 lo pone la UI) o el número completo;
     * genera el secreto aleatorio de 32 caracteres, pide el JWT y persiste todo.
     */
    fun login(context: Context, phoneInput: String, client: OkHttpClient = defaultClient()): Account {
        val phone = normalizePhone(phoneInput)
        require(phone.length == 10 && phone.startsWith("53")) {
            "Número cubano inválido: se esperan 10 dígitos comenzando por 53"
        }
        val p = prefs(context)
        // Reusar el secreto si ya existía para este teléfono (cuenta estable),
        // o generar uno nuevo de 32 caracteres aleatorios la primera vez.
        val secret = p.getString(KEY_SECRET, null)
            ?.takeIf { it.length == 32 && p.getString(KEY_PHONE, "") == phone }
            ?: randomSecret(32)

        val jwt = requestJwt(phone, secret, client)
        p.edit()
            .putString(KEY_PHONE, phone)
            .putString(KEY_SECRET, secret)
            .putString(KEY_JWT, jwt)
            .putLong(KEY_JWT_EXP, jwtExp(jwt))
            .apply()
        AppLog.i("[auth] login OK para $phone (jwt ${jwt.length} chars)")
        return Account(phone, secret, jwt, jwtExp(jwt))
    }

    /** Renueva el JWT con el secreto persistido (revalidación silenciosa). */
    fun revalidate(context: Context, account: Account, client: OkHttpClient = defaultClient()): Account {
        val jwt = requestJwt(account.phone, account.secret, client)
        val updated = account.copy(jwt = jwt, jwtExp = jwtExp(jwt))
        prefs(context).edit()
            .putString(KEY_JWT, jwt)
            .putLong(KEY_JWT_EXP, updated.jwtExp)
            .apply()
        AppLog.i("[auth] JWT revalidado para ${account.phone}")
        return updated
    }

    fun logout(context: Context) {
        prefs(context).edit().clear().apply()
    }

    // ---------------------------------------------------------------- internals

    fun normalizePhone(input: String): String =
        input.filter { it.isDigit() }.let { cleaned ->
            when {
                cleaned.length == 12 && cleaned.startsWith("53") -> cleaned.drop(2)
                else -> cleaned
            }
        }

    fun randomSecret(n: Int): String {
        val rng = SecureRandom()
        val out = StringBuilder(n)
        for (i in 0 until n) out.append(ALPHABET[rng.nextInt(ALPHABET.length)])
        return out.toString()
    }

    /** Codifica un campo protobuf wire-type 2 (length-delimited). */
    private fun sf(fieldNumber: Int, value: String): ByteArray {
        val data = value.toByteArray(Charsets.UTF_8)
        val head = ArrayList<Byte>(2)
        head.add(((fieldNumber shl 3) or 2).toByte())
        var v = data.size.toLong()
        while (v > 0x7f) {
            head.add(((v and 0x7f) or 0x80).toByte())
            v = v shr 7
        }
        head.add(v.toByte())
        return head.toByteArray() + data
    }

    fun requestJwt(phone: String, secret: String, client: OkHttpClient): String {
        val body = (sf(1, phone) + sf(2, secret)).toRequestBody(OCTET_STREAM.toMediaType())
        val req = Request.Builder()
            .url(AUTH_URL)
            .post(body)
            .header("content-type", "application/octet-stream")
            .header("user-agent", "ToDus 2.1.1")
            .build()
        client.newCall(req).execute().use { resp ->
            val raw = resp.body?.bytes() ?: ByteArray(0)
            if (!resp.isSuccessful) {
                throw IllegalStateException("auth.todus.cu HTTP ${resp.code}: ${String(raw).take(200)}")
            }
            val m = JWT_RE.find(String(raw)) ?: run {
                // A veces la respuesta es JSON: {"token":"..."} — cubrir ambos casos.
                val jsonTok = try {
                    JSONObject(String(raw)).optString("token", "")
                } catch (e: Exception) { "" }
                if (jsonTok.isNotEmpty()) return jsonTok
                throw IllegalStateException("JWT no encontrado en la respuesta de auth.todus.cu")
            }
            return m.value
        }
    }

    /** exp del JWT sin verificar firma (unix segundos; 0 si no se puede leer). */
    fun jwtExp(token: String): Long {
        val parts = token.split(".")
        if (parts.size < 2) return 0L
        try {
            val b64 = parts[1]
            val pad = (4 - b64.length % 4) % 4
            val payload = android.util.Base64.decode(
                b64 + "=".repeat(pad),
                android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP,
            )
            val json = JSONObject(String(payload))
            return if (json.has("exp")) json.getLong("exp") else 0L
        } catch (e: Exception) {
            return 0L
        }
    }

    fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    fun md5Hex(s: String): String =
        MessageDigest.getInstance("MD5").digest(s.toByteArray(Charsets.UTF_8))
            .joinToString("") { String.format("%02x", it) }
}
