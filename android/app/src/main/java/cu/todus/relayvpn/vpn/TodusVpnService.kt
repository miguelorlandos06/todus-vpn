package cu.todus.relayvpn.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import cu.todus.relayvpn.AppLog
import cu.todus.relayvpn.MainActivity
import cu.todus.relayvpn.R
import cu.todus.relayvpn.RelaySettings
import cu.todus.relayvpn.VpnStats
import kotlin.concurrent.thread

/**
 * VpnService que declara BIND_Vpn_SERVICE + action android.net.VpnService (manifest),
 * corre en primer plano (tipo specialUse en Android 14+) y aloja el motor completo:
 * SOCKS5 local + pila TCP + túnel UDP + cliente ToDus.
 */
class TodusVpnService : android.net.VpnService() {

    companion object {
        const val ACTION_START = "cu.todus.relayvpn.START"
        const val ACTION_STOP = "cu.todus.relayvpn.STOP"
        const val CHANNEL_ID = "todus_vpn"
        const val NOTIFICATION_ID = 1

        const val STATE_STOPPED = "detenida"
        const val STATE_CONNECTING = "conectando"
        const val STATE_ACTIVE = "activa"
        const val STATE_ERROR = "error"

        @Volatile var instance: TodusVpnService? = null
            private set

        /** Estado compartido con la interfaz: "detenida", "conectando", "activa", "error". */
        @Volatile var state: String = STATE_STOPPED
            private set

        @Volatile var lastError: String? = null
            private set
    }

    // FIX: @Volatile — engine se escribe en el hilo "vpn-start" y se lee desde
    // stopVpn()/onDestroy() (hilo UI). Sin @Volatile el hilo de stop puede ver
    // null y saltarse la limpieza, dejando sockets y bombas vivas.
    @Volatile var engine: VpnEngine? = null
        private set

    @Volatile private var wakeLock: android.os.PowerManager.WakeLock? = null

    val stats = VpnStats()

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START
        if (action == ACTION_STOP) {
            stopVpn()
            return START_NOT_STICKY
        }
        if (engine != null) {
            // ya corre
            return START_NOT_STICKY
        }
        startForegroundCompat()
        state = STATE_CONNECTING
        updateNotification(getString(R.string.state_connecting))
        thread(name = "vpn-start", isDaemon = true) {
            try {
                val settings = RelaySettings.fromPrefs(this)
                val newEngine = VpnEngine(this, settings, stats)
                // Si el túnel RTC cae más tarde, marcar error y detener el servicio.
                newEngine.onFatalCallback = { reason ->
                    android.os.Handler(mainLooper).post {
                        if (state == STATE_ACTIVE) {
                            lastError = reason
                            state = STATE_ERROR
                            AppLog.e("[!] túnel RTC caído: $reason")
                            updateNotification(getString(R.string.state_error))
                            stopForeground(STOP_FOREGROUND_REMOVE)
                            stopSelf()
                        }
                    }
                }
                newEngine.start()
                engine = newEngine
                state = STATE_ACTIVE
                try {
                    val pm = getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
                    wakeLock = pm?.newWakeLock(android.os.PowerManager.PARTIAL_WAKE_LOCK, "ToDusVPN::StreamLock")?.apply {
                        acquire(8 * 3600 * 1000L)
                    }
                } catch (e: Exception) {
                    // ignorar si no se pudo adquirir
                }
                updateNotification(getString(R.string.state_running))
                AppLog.i("[*] VPN activa: todo el tráfico del dispositivo pasa por ToDus (método MOBILE)")
            } catch (e: Exception) {
                lastError = e.message ?: e.javaClass.simpleName
                state = STATE_ERROR
                AppLog.e("[!] error al arrancar la VPN: $lastError")
                updateNotification(getString(R.string.state_error))
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        engine?.stop()
        engine = null
        if (instance == this) instance = null
        if (state != STATE_ACTIVE) state = STATE_STOPPED
        super.onDestroy()
    }

    override fun onRevoke() {
        // El sistema u otro VPN tomó el control: detener limpio.
        AppLog.w("[*] permiso VPN revocado")
        stopVpn()
    }

    fun stopVpn() {
        state = STATE_STOPPED
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (e: Exception) {}
        wakeLock = null
        thread(name = "vpn-stop", isDaemon = true) {
            engine?.stop()
            engine = null
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // ---------------------------------------------------------------- notificación

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.app_title),
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.description = getString(R.string.app_subtitle)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pending = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_vpn)
            .setContentTitle(getString(R.string.app_title))
            .setContentText(text)
            .setContentIntent(pending)
            .setOngoing(true)
        return builder.build()
    }

    private fun startForegroundCompat() {
        val notification = buildNotification(getString(R.string.state_connecting))
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }
}
