package cu.todus.relayvpn

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import androidx.core.content.ContextCompat
import cu.todus.relayvpn.vpn.TodusVpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/**
 * Puente Flutter ↔ núcleo Kotlin de la VPN.
 *
 * La interfaz de esta versión es 100 % Flutter; esta actividad no dibuja nada.
 * Solo expone el control del [TodusVpnService] (conectar, desconectar, estado,
 * estadísticas y registro) a través del MethodChannel `todus.vpn/bridge`,
 * reproduciendo exactamente el flujo de la actividad original:
 *
 *   1. permiso de notificaciones (Android 13+),
 *   2. diálogo de VPN del sistema (VpnService.prepare),
 *   3. arranque del servicio en primer plano.
 *
 * El núcleo (SocksServer, RelayProtocol, TodusStore, TcpStack, UdpTunnel,
 * VpnEngine, TodusVpnService, RelaySettings) es idéntico al de la APK Kotlin.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "todus.vpn/bridge"
        private const val REQUEST_VPN_PERMISSION = 41080
        private const val REQUEST_NOTIFICATION_PERMISSION = 41081
    }

    /** Resultado pendiente del flujo de conexión (diálogos de permiso). */
    private var connectResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "connect" -> handleConnect(result)
                "disconnect" -> {
                    stopVpnService()
                    result.success(true)
                }
                "getStatus" -> result.success(buildStatus())
                "clearLog" -> {
                    AppLog.clear()
                    result.success(true)
                }
                "getSettings" -> result.success(RelaySettings.snapshot(this))
                "setSettings" -> {
                    @Suppress("UNCHECKED_CAST")
                    val values = call.argument<Map<String, Any>>("values") ?: emptyMap()
                    RelaySettings.apply(this, values)
                    val active = TodusVpnService.state == TodusVpnService.STATE_ACTIVE ||
                        TodusVpnService.state == TodusVpnService.STATE_CONNECTING
                    result.success(mapOf(
                        "ok" to true,
                        "needsReconnect" to active
                    ))
                }
                "listInstalledApps" -> result.success(listInstalledApps())
                // ── Cuenta toDus (login JWT con teléfono + secreto aleatorio) ──
                "login" -> {
                    val phone = call.argument<String>("phone") ?: ""
                    thread(name = "todus-login", isDaemon = true) {
                        try {
                            val account = TodusAuth.login(this, phone)
                            result.success(mapOf(
                                "ok" to true,
                                "phone" to account.phone,
                                "jid" to account.jid,
                                "jwtExpiresAt" to account.jwtExp,
                            ))
                        } catch (e: Exception) {
                            result.error("LOGIN", e.message ?: "fallo el login toDus", null)
                        }
                    }
                }
                "getAccount" -> {
                    val account = TodusAuth.load(this)
                    result.success(
                        if (account == null) mapOf("hasAccount" to false)
                        else mapOf(
                            "hasAccount" to true,
                            "phone" to account.phone,
                            "jid" to account.jid,
                            "jwtValid" to account.jwtValid(),
                            "jwtExpiresAt" to account.jwtExp,
                        )
                    )
                }
                "logout" -> {
                    stopVpnService()
                    TodusAuth.logout(this)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // El motor se destruye (actividad terminada): no dejar resultados colgados.
        connectResult = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // ---------------------------------------------------------------- conectar

    private fun handleConnect(result: MethodChannel.Result) {
        when (TodusVpnService.state) {
            TodusVpnService.STATE_ACTIVE, TodusVpnService.STATE_CONNECTING -> {
                stopVpnService()
                result.success(true)
            }
            else -> {
                if (connectResult != null) {
                    result.error("PENDING", "Ya hay una solicitud de conexión en curso", null)
                    return
                }
                connectResult = result
                askNotificationPermissionThenVpn()
            }
        }
    }

    /** Igual que la APK original: primero notificaciones (13+), después VPN. */
    private fun askNotificationPermissionThenVpn() {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            @Suppress("DEPRECATION")
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_NOTIFICATION_PERMISSION,
            )
        } else {
            askVpnPermissionAndStart()
        }
    }

    private fun askVpnPermissionAndStart() {
        val prepareIntent = VpnService.prepare(this)
        if (prepareIntent != null) {
            @Suppress("DEPRECATION")
            startActivityForResult(prepareIntent, REQUEST_VPN_PERMISSION)
        } else {
            startVpnService()
            connectResult?.success(true)
            connectResult = null
        }
    }

    // ---------------------------------------------------------------- resultados

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_VPN_PERMISSION) {
            val pending = connectResult
            connectResult = null
            if (resultCode == RESULT_OK) {
                startVpnService()
                pending?.success(true)
            } else {
                pending?.success(false)
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_NOTIFICATION_PERMISSION) {
            // Con permiso o sin él (las notificaciones no son imprescindibles),
            // seguimos con el diálogo de VPN, igual que la app original.
            askVpnPermissionAndStart()
        }
    }

    // ---------------------------------------------------------------- servicio

    private fun startVpnService() {
        val intent = Intent(this, TodusVpnService::class.java)
        intent.action = TodusVpnService.ACTION_START
        ContextCompat.startForegroundService(this, intent)
    }

    private fun stopVpnService() {
        val intent = Intent(this, TodusVpnService::class.java)
        intent.action = TodusVpnService.ACTION_STOP
        ContextCompat.startForegroundService(this, intent)
    }

    // ---------------------------------------------------------------- estado

    /** Estado completo para la interfaz Flutter: estado, error, estadísticas, registro y fase RTC. */
    private fun buildStatus(): Map<String, Any> {
        val service = TodusVpnService.instance
        val stats = service?.stats
        val engine = service?.engine
        val rtc = engine?.currentRtc()
        val account = TodusAuth.load(this)
        return mutableMapOf(
            "state" to TodusVpnService.state,
            "lastError" to (TodusVpnService.lastError ?: ""),
            "uptimeMs" to (stats?.uptimeMillis() ?: 0L),
            "bytesUp" to (stats?.bytesUp?.get() ?: 0L),
            "bytesDown" to (stats?.bytesDown?.get() ?: 0L),
            "tcpSessionsActive" to (stats?.tcpSessionsActive?.get() ?: 0),
            "tcpSessionsTotal" to (stats?.tcpSessionsTotal?.get() ?: 0),
            "udpDatagramsOut" to (stats?.udpDatagramsOut?.get() ?: 0L),
            "udpDatagramsIn" to (stats?.udpDatagramsIn?.get() ?: 0L),
            "tcpSegmentsDropped" to (stats?.tcpSegmentsDropped?.get() ?: 0L),
            "udpOversizeDropped" to (stats?.udpOversizeDropped?.get() ?: 0L),
            "storeGetOk" to (stats?.storeGetOk?.get() ?: 0L),
            "storePutOk" to (stats?.storePutOk?.get() ?: 0L),
            "storeGetFail" to (stats?.storeGetFail?.get() ?: 0L),
            "storePutFail" to (stats?.storePutFail?.get() ?: 0L),
            "storeDeleteOk" to (stats?.storeDeleteOk?.get() ?: 0L),
            "otherProtoDropped" to (stats?.otherProtoDropped?.get() ?: 0L),
            // Métricas de resiliencia.
            "backoffEvents" to (stats?.backoffEvents?.get() ?: 0L),
            "circuitOpenCount" to (stats?.circuitOpenCount?.get() ?: 0L),
            "httpSemaphoreWait" to (stats?.httpSemaphoreWait?.get() ?: 0L),
            "tcpBatchesSent" to (stats?.tcpBatchesSent?.get() ?: 0L),
            "sessionsRejectedByLimit" to (stats?.sessionsRejectedByLimit?.get() ?: 0L),
            // ── RTC ──
            "rtcPhase" to (rtc?.phase ?: ""),
            "rtcPhaseDetail" to (rtc?.phaseDetail ?: ""),
            "rtcServerPhone" to (rtc?.serverPhone ?: ""),
            "rtcServerUrl" to (rtc?.serverUrl ?: ""),
            "rtcWaitlistPosition" to (rtc?.waitlistPosition ?: 0),
            "rtcFramesUp" to (stats?.rtcFramesUp?.get() ?: 0L),
            "rtcFramesDown" to (stats?.rtcFramesDown?.get() ?: 0L),
            "rtcStreamsOpened" to (stats?.rtcStreamsOpened?.get() ?: 0L),
            "dnsOverTcpQueries" to (stats?.dnsOverTcpQueries?.get() ?: 0L),
            "udpDirectFlows" to (stats?.udpDirectFlows?.get() ?: 0),
            "accountPhone" to (account?.phone ?: ""),
            "log" to AppLog.snapshot(),
        )
    }

    /** Lista de apps instaladas (con permiso INTERNET implícito) para que la UI
     *  permita al usuario elegir cuáles pasan por la VPN. */
    private fun listInstalledApps(): List<Map<String, String>> {
        // Apps con lanzador (una sola consulta, rápida): requiere la declaración
        // <queries> MAIN/LAUNCHER en el AndroidManifest, o en Android 11+ el
        // sistema devuelve una lista casi vacía (filtrado de visibilidad).
        val intent = android.content.Intent(android.content.Intent.ACTION_MAIN)
            .addCategory(android.content.Intent.CATEGORY_LAUNCHER)
        val launchable = packageManager.queryIntentActivities(intent, 0)
        val seen = HashSet<String>()
        val out = ArrayList<Map<String, String>>(launchable.size)
        for (ri in launchable) {
            val pkg = ri.activityInfo?.packageName ?: continue
            // Ignorar la propia app: nunca puede pasar por su propia VPN.
            if (pkg == packageName) continue
            // Deduplicar: paquetes con varias actividades lanzables salen varias veces.
            if (!seen.add(pkg)) continue
            // NO filtramos FLAG_SYSTEM: apps de sistema con lanzador (ToDus,
            // YouTube, Chrome…) también pueden necesitar la lista blanca.
            val label = try {
                ri.loadLabel(packageManager).toString().ifBlank { pkg }
            } catch (_: Exception) {
                pkg
            }
            out.add(mapOf("packageName" to pkg, "label" to label))
        }
        out.sortBy { it["label"]?.lowercase() ?: "" }
        return out
    }
}
