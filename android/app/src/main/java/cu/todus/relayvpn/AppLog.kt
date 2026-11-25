package cu.todus.relayvpn

import android.util.Log

/**
 * Registro en memoria (búfer circular) + Logcat, equivalente a los print() del script Python.
 * La actividad muestra las últimas líneas para diagnosticar igual que en Termux.
 */
object AppLog {
    private const val MAX_LINES = 400
    private val lines = ArrayDeque<String>()
    private val lock = Any()

    fun i(message: String) {
        add("INFO", message)
        Log.i("TodusVpn", message)
    }

    /** Nivel debug: solo Logcat (no llena el búfer de la interfaz). */
    fun d(message: String) {
        Log.d("TodusVpn", message)
    }

    fun w(message: String) {
        add("WARN", message)
        Log.w("TodusVpn", message)
    }

    fun e(message: String) {
        add("ERROR", message)
        Log.e("TodusVpn", message)
    }

    private fun add(level: String, message: String) {
        val ts = System.currentTimeMillis()
        val h = (ts / 3_600_000L) % 24
        val m = (ts / 60_000L) % 60
        val s = (ts / 1000L) % 60
        val line = "[%02d:%02d:%02d %s] %s".format(h, m, s, level, message)
        synchronized(lock) {
            lines.addLast(line)
            while (lines.size > MAX_LINES) lines.removeFirst()
        }
    }

    /** Copia del búfer para la interfaz. */
    fun snapshot(): List<String> = synchronized(lock) { lines.toList() }

    fun clear() = synchronized(lock) { lines.clear() }
}
