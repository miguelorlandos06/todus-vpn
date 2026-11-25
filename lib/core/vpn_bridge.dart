import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Estado de la VPN — espejo de `TodusVpnService.STATE_*` en Kotlin.
enum VpnState { stopped, connecting, active, error }

/// Contadores en vivo del servicio (espejo de `VpnStats` en Kotlin).
class VpnStats {
  const VpnStats({
    this.uptimeMs = 0,
    this.bytesUp = 0,
    this.bytesDown = 0,
    this.tcpSessionsActive = 0,
    this.tcpSessionsTotal = 0,
    this.udpDatagramsOut = 0,
    this.udpDatagramsIn = 0,
    this.tcpSegmentsDropped = 0,
    this.udpOversizeDropped = 0,
    this.storeGetOk = 0,
    this.storePutOk = 0,
    this.storeGetFail = 0,
    this.storePutFail = 0,
    this.storeDeleteOk = 0,
    this.otherProtoDropped = 0,
    this.backoffEvents = 0,
    this.circuitOpenCount = 0,
    this.httpSemaphoreWait = 0,
    this.tcpBatchesSent = 0,
    this.sessionsRejectedByLimit = 0,
    this.rtcFramesUp = 0,
    this.rtcFramesDown = 0,
    this.rtcStreamsOpened = 0,
    this.dnsOverTcpQueries = 0,
    this.udpDirectFlows = 0,
  });

  final int uptimeMs;
  final int bytesUp;
  final int bytesDown;
  final int tcpSessionsActive;
  final int tcpSessionsTotal;
  final int udpDatagramsOut;
  final int udpDatagramsIn;
  final int tcpSegmentsDropped;
  final int udpOversizeDropped;
  final int storeGetOk;
  final int storePutOk;
  final int storeGetFail;
  final int storePutFail;
  final int storeDeleteOk;
  final int otherProtoDropped;
  // Métricas de resiliencia (nuevas).
  final int backoffEvents;
  final int circuitOpenCount;
  final int httpSemaphoreWait;
  final int tcpBatchesSent;
  final int sessionsRejectedByLimit;

  // Métricas del túnel RTC (WebRTC DataChannel).
  final int rtcFramesUp;
  final int rtcFramesDown;
  final int rtcStreamsOpened;
  final int dnsOverTcpQueries;
  final int udpDirectFlows;

  /// Fallos totales del relay (GET + PUT).
  int get storeFailures => storeGetFail + storePutFail;

  factory VpnStats.fromMap(Map<Object?, Object?> map) {
    int asInt(Object? key) {
      final value = map[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      return 0;
    }

    return VpnStats(
      uptimeMs: asInt('uptimeMs'),
      bytesUp: asInt('bytesUp'),
      bytesDown: asInt('bytesDown'),
      tcpSessionsActive: asInt('tcpSessionsActive'),
      tcpSessionsTotal: asInt('tcpSessionsTotal'),
      udpDatagramsOut: asInt('udpDatagramsOut'),
      udpDatagramsIn: asInt('udpDatagramsIn'),
      tcpSegmentsDropped: asInt('tcpSegmentsDropped'),
      udpOversizeDropped: asInt('udpOversizeDropped'),
      storeGetOk: asInt('storeGetOk'),
      storePutOk: asInt('storePutOk'),
      storeGetFail: asInt('storeGetFail'),
      storePutFail: asInt('storePutFail'),
      storeDeleteOk: asInt('storeDeleteOk'),
      otherProtoDropped: asInt('otherProtoDropped'),
      backoffEvents: asInt('backoffEvents'),
      circuitOpenCount: asInt('circuitOpenCount'),
      httpSemaphoreWait: asInt('httpSemaphoreWait'),
      tcpBatchesSent: asInt('tcpBatchesSent'),
      sessionsRejectedByLimit: asInt('sessionsRejectedByLimit'),
      rtcFramesUp: asInt('rtcFramesUp'),
      rtcFramesDown: asInt('rtcFramesDown'),
      rtcStreamsOpened: asInt('rtcStreamsOpened'),
      dnsOverTcpQueries: asInt('dnsOverTcpQueries'),
      udpDirectFlows: asInt('udpDirectFlows'),
    );
  }
}

/// Fotograma completo del estado nativo: estado + error + estadísticas + registro.
class VpnSnapshot {
  const VpnSnapshot({
    this.state = VpnState.stopped,
    this.lastError = '',
    this.stats = const VpnStats(),
    this.logLines = const <String>[],
    this.speedUp = 0,
    this.speedDown = 0,
    this.rtcPhase = '',
    this.rtcPhaseDetail = '',
    this.rtcServerPhone = '',
    this.rtcWaitlistPosition = 0,
    this.accountPhone = '',
  });

  final VpnState state;
  final String lastError;
  final VpnStats stats;
  final List<String> logLines;

  /// Velocidades derivadas (bytes/s) calculadas en Dart a partir de dos
  /// sondeos consecutivos; 0 cuando la VPN no está activa.
  final double speedUp;
  final double speedDown;

  /// Fase del túnel RTC (autenticando, negociando, esperando-canal, conectado…).
  final String rtcPhase;
  final String rtcPhaseDetail;
  final String rtcServerPhone;
  final int rtcWaitlistPosition;
  final String accountPhone;

  bool get isActive => state == VpnState.active;

  /// Texto humano del paso actual de la conexión RTC.
  String get rtcPhaseLabel {
    switch (rtcPhase) {
      case 'autenticando':
        return 'Autenticando cuenta toDus…';
      case 'xmpp':
        return 'Conectando señalización toDus (XMPP)…';
      case 'llamando':
        return 'Llamando al servidor por XMPP…';
      case 'esperando-canal':
        return 'Esperando canal libre (posición $rtcWaitlistPosition)…';
      case 'negociando':
        return 'Negociando WebRTC (TURN)…';
      case 'conectado':
        return 'Túnel activo${rtcServerPhone.isEmpty ? '' : ' vía $rtcServerPhone'}';
      case '':
        return '';
      default:
        return rtcPhaseDetail.isEmpty ? rtcPhase : '$rtcPhase: $rtcPhaseDetail';
    }
  }
}

/// Puente con el núcleo Kotlin a través del MethodChannel `todus.vpn/bridge`.
///
/// Sigue el mismo modelo que la actividad original: sondeo cada 500 ms de
/// estado, estadísticas y registro (el `Handler.postDelayed(500)` de la APK),
/// ahora consolidado en una única llamada `getStatus`.
class VpnBridge extends ChangeNotifier {
  VpnBridge({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('todus.vpn/bridge');

  final MethodChannel _channel;

  VpnSnapshot _snapshot = const VpnSnapshot();
  VpnSnapshot get snapshot => _snapshot;

  Timer? _timer;
  bool _polling = false;

  // Muestra anterior para calcular velocidades.
  int _lastBytesUp = 0;
  int _lastBytesDown = 0;
  DateTime _lastSampleAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Arranca el sondeo periódico (500 ms, como la app original).
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _refresh());
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  /// Sondeo manual del estado nativo (expuesto para pruebas).
  @visibleForTesting
  Future<void> poll() => _refresh();

  Future<void> _refresh() async {
    if (_polling) return;
    _polling = true;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('getStatus');
      if (raw != null) {
        _applySnapshot(raw);
      }
    } on PlatformException {
      // El lado nativo todavía no está listo: se conserva la última muestra.
    } on MissingPluginException {
      // Entorno sin puente nativo (pruebas de widgets / escritorio).
    } catch (_) {
      // Cualquier otro fallo de sondeo no debe tumbar la interfaz.
    } finally {
      _polling = false;
    }
  }

  void _applySnapshot(Map<Object?, Object?> raw) {
    final state = _parseState(raw['state']);
    final stats = VpnStats.fromMap(raw);
    final logLines = (raw['log'] as List<Object?>? ?? const <Object?>[])
        .whereType<String>()
        .toList(growable: false);

    var speedUp = 0.0;
    var speedDown = 0.0;
    final now = DateTime.now();
    if (state == VpnState.active && _lastSampleAt.millisecondsSinceEpoch > 0) {
      final seconds = now.difference(_lastSampleAt).inMilliseconds / 1000.0;
      if (seconds > 0.05) {
        final down = (stats.bytesDown - _lastBytesDown) / seconds;
        final up = (stats.bytesUp - _lastBytesUp) / seconds;
        // Suavizado exponencial para que el número no tiemble.
        const alpha = 0.45;
        speedDown = (down >= 0 ? down : 0) * alpha + _snapshot.speedDown * (1 - alpha);
        speedUp = (up >= 0 ? up : 0) * alpha + _snapshot.speedUp * (1 - alpha);
      }
    }
    if (state != VpnState.active) {
      speedUp = 0;
      speedDown = 0;
    }
    _lastBytesUp = stats.bytesUp;
    _lastBytesDown = stats.bytesDown;
    _lastSampleAt = now;

    _snapshot = VpnSnapshot(
      state: state,
      lastError: raw['lastError'] as String? ?? '',
      stats: stats,
      logLines: logLines,
      speedUp: speedUp,
      speedDown: speedDown,
      rtcPhase: raw['rtcPhase'] as String? ?? '',
      rtcPhaseDetail: raw['rtcPhaseDetail'] as String? ?? '',
      rtcServerPhone: raw['rtcServerPhone'] as String? ?? '',
      rtcWaitlistPosition: raw['rtcWaitlistPosition'] as int? ?? 0,
      accountPhone: raw['accountPhone'] as String? ?? '',
    );
    notifyListeners();
  }

  static VpnState _parseState(Object? raw) {
    switch (raw) {
      case 'activa':
        return VpnState.active;
      case 'conectando':
        return VpnState.connecting;
      case 'error':
        return VpnState.error;
      default:
        return VpnState.stopped;
    }
  }

  /// Alterna conectar/desconectar, igual que el botón de la app original.
  Future<bool> toggle() {
    final state = _snapshot.state;
    if (state == VpnState.active || state == VpnState.connecting) {
      return disconnect();
    }
    return connect();
  }

  /// Solicita conectar: notificaciones (Android 13+) → diálogo VPN → servicio.
  /// Devuelve false si el usuario denegó el permiso de VPN.
  Future<bool> connect() async {
    try {
      final ok = await _channel.invokeMethod<bool>('connect');
      await _refresh();
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> disconnect() async {
    try {
      final ok = await _channel.invokeMethod<bool>('disconnect');
      await _refresh();
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> clearLog() async {
    try {
      await _channel.invokeMethod<bool>('clearLog');
    } on PlatformException {
      // Sin puente: ignorar (pruebas).
    } on MissingPluginException {
      // Entorno de pruebas.
    }
    await _refresh();
  }

  // ─── Ajustes Avanzados ───────────────────────────────────────────
  // Métodos para leer y escribir la configuración persistida en Kotlin.
  // Las claves coinciden con `RelaySettings.KEY_*`.

  Future<Map<String, dynamic>> getSettings() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('getSettings');
      return raw ?? <String, dynamic>{};
    } on PlatformException {
      return <String, dynamic>{};
    } on MissingPluginException {
      return <String, dynamic>{};
    }
  }

  /// Devuelve `true` si la VPN está activa y necesita reconectar para aplicar
  /// los nuevos valores.
  Future<bool> setSettings(Map<String, dynamic> values) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'setSettings',
        <String, dynamic>{'values': values},
      );
      if (raw == null) return false;
      final needsReconnect = raw['needsReconnect'] == true;
      if (needsReconnect) {
        // Reconectar silenciosamente para aplicar: solo si estaba activa.
        await disconnect();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await connect();
      }
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<List<InstalledApp>> listInstalledApps() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listInstalledApps');
      if (raw == null) return const <InstalledApp>[];
      return raw
          .whereType<Map<Object?, Object?>>()
          .map(InstalledApp.fromMap)
          .whereType<InstalledApp>()
          .toList(growable: false);
    } on PlatformException {
      return const <InstalledApp>[];
    } on MissingPluginException {
      return const <InstalledApp>[];
    }
  }

  // ─── Cuenta toDus (pantalla de login) ──────────────────────────

  /// Inicia sesión en toDus con el número dado (el JWT se solicita en Kotlin
  /// con un secreto aleatorio de 32 caracteres). Devuelve el teléfono completo
  /// o null si falló (lanza con el mensaje del servidor).
  Future<String> loginToDus(String phone) async {
    final raw = await _channel.invokeMapMethod<String, dynamic>('login', <String, dynamic>{
      'phone': phone,
    });
    return raw?['phone'] as String? ?? '';
  }

  /// ¿Hay cuenta guardada? Devuelve null si nunca se ha iniciado sesión.
  Future<TodusAccount?> getAccount() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('getAccount');
      if (raw == null || raw['hasAccount'] != true) return null;
      return TodusAccount(
        phone: raw['phone'] as String? ?? '',
        jid: raw['jid'] as String? ?? '',
        jwtValid: raw['jwtValid'] == true,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Cierra sesión (detiene la VPN y borra la cuenta persistida).
  Future<void> logout() async {
    try {
      await _channel.invokeMethod<bool>('logout');
    } on PlatformException {
      // ignorar
    } on MissingPluginException {
      // entorno de pruebas
    }
    await _refresh();
  }
}

/// Cuenta toDus guardada en el lado nativo.
class TodusAccount {
  const TodusAccount({required this.phone, required this.jid, required this.jwtValid});

  final String phone;
  final String jid;
  final bool jwtValid;
}

/// App instalada visible para la selección de filtrado.
class InstalledApp {
  const InstalledApp({required this.packageName, required this.label});

  final String packageName;
  final String label;

  static InstalledApp? fromMap(Map<Object?, Object?> map) {
    final pkg = map['packageName'];
    final label = map['label'];
    if (pkg is! String || label is! String) return null;
    return InstalledApp(packageName: pkg, label: label);
  }
}
