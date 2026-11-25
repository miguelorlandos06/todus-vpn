import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:todus_relay_vpn/core/vpn_bridge.dart';
import 'package:todus_relay_vpn/main.dart';
import 'package:todus_relay_vpn/screens/log_screen.dart';
import 'package:todus_relay_vpn/theme/app_theme.dart';

const MethodChannel _channel = MethodChannel('todus.vpn/bridge');

Map<String, Object> _statusMap({
  String state = 'detenida',
  String lastError = '',
  int uptimeMs = 0,
  List<String> log = const <String>[],
}) {
  return <String, Object>{
    'state': state,
    'lastError': lastError,
    'uptimeMs': uptimeMs,
    'bytesUp': 121000,
    'bytesDown': 842000,
    'tcpSessionsActive': 3,
    'tcpSessionsTotal': 14,
    'udpDatagramsOut': 57,
    'udpDatagramsIn': 61,
    'tcpSegmentsDropped': 0,
    'udpOversizeDropped': 0,
    'storeGetOk': 120,
    'storePutOk': 80,
    'storeGetFail': 2,
    'storePutFail': 1,
    'storeDeleteOk': 40,
    'otherProtoDropped': 5,
    'log': log,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Cuenta guardada por defecto: la app arranca en el Home (no en el login).
  Map<String, Object> accountMap({bool hasAccount = true}) => <String, Object>{
    'hasAccount': hasAccount,
    'phone': '5350256349',
    'jid': '5350256349@im.todus.cu',
    'jwtValid': true,
    'jwtExpiresAt': 4102444800,
  };

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  void mockAccount() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'getAccount') return accountMap();
      if (call.method == 'getStatus') return _statusMap();
      return null;
    });
  }

  testWidgets('La inicio muestra el estado desconectado y la marca', (tester) async {
    mockAccount();
    await tester.pumpWidget(ToDusVpnApp(bridge: VpnBridge()));
    await tester.pumpAndSettle();

    expect(find.text('ToDus'), findsOneWidget);
    expect(find.text('Desconectado'), findsOneWidget);
    expect(find.text('Sin conectar'), findsOneWidget);
    expect(find.byIcon(Icons.power_settings_new), findsOneWidget);
    expect(find.text('Inicio'), findsOneWidget);
    expect(find.text('Datos'), findsOneWidget);
    expect(find.text('Registro'), findsOneWidget);
  });

  testWidgets('Sin cuenta: aparece la pantalla «Ingresar número»', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'getAccount') return accountMap(hasAccount: false);
      if (call.method == 'getStatus') return _statusMap();
      return null;
    });
    await tester.pumpWidget(ToDusVpnApp(bridge: VpnBridge()));
    await tester.pumpAndSettle();

    expect(find.text('Ingresar número'), findsOneWidget);
    expect(find.textContaining('Por favor, ingresa el número'), findsOneWidget);
    expect(find.text('+53'), findsOneWidget);
    expect(find.text('Continuar'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets); // bandera cubana
  });

  testWidgets('Estado activo: muestra Protegido, duración y velocidades', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'getAccount') return accountMap();
      if (call.method == 'getStatus') {
        return _statusMap(state: 'activa', uptimeMs: 754000);
      }
      return null;
    });

    final bridge = VpnBridge();
    await tester.pumpWidget(ToDusVpnApp(bridge: bridge));
    await tester.pumpAndSettle();
    await bridge.poll();
    await tester.pump();

    expect(find.text('Protegido'), findsOneWidget);
    expect(find.text('Conectado'), findsOneWidget);
    expect(find.text('00:12:34 · RTC'), findsOneWidget);
    expect(find.text('822.3 KB'), findsOneWidget); // datos bajados (842000 B)
    expect(find.text('118.2 KB'), findsOneWidget); // datos subidos (121000 B)
    expect(find.text('3 activas'), findsOneWidget); // conexiones TCP
  });

  testWidgets('Estado de error: muestra el aviso con el último error', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'getAccount') return accountMap();
      if (call.method == 'getStatus') {
        return _statusMap(state: 'error', lastError: 'No se pudo establecer la VPN');
      }
      return null;
    });

    final bridge = VpnBridge();
    await tester.pumpWidget(ToDusVpnApp(bridge: bridge));
    await tester.pumpAndSettle();
    await bridge.poll();
    await tester.pump();

    expect(find.text('Sin conexión'), findsOneWidget);
    expect(find.textContaining('No se pudo establecer la VPN'), findsWidgets);
  });

  testWidgets('Tocar el orbe desconectado invoca conectar', (tester) async {
    var connects = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'getAccount') return accountMap();
      if (call.method == 'connect') {
        connects++;
        return true;
      }
      if (call.method == 'getStatus') {
        return _statusMap();
      }
      return null;
    });

    await tester.pumpWidget(ToDusVpnApp(bridge: VpnBridge()));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.power_settings_new));
    await tester.pump();
    await tester.pump();

    expect(connects, 1);
  });

  testWidgets('El registro pinta las líneas con niveles', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'getStatus') {
        return _statusMap(
          state: 'activa',
          log: <String>[
            '[10:20:30 INFO] [+] CONNECT example.com:443',
            '[10:20:31 WARN] reintento de publicación',
            '[10:20:32 ERROR] [ToDus PUT] fallo de red',
          ],
        );
      }
      return null;
    });

    final bridge = VpnBridge();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: LogScreen(bridge: bridge)),
      ),
    );
    await bridge.poll();
    await tester.pump();

    expect(find.textContaining('[+] CONNECT example.com:443'), findsOneWidget);
    expect(find.textContaining('reintento de publicación'), findsOneWidget);
    expect(find.textContaining('[ToDus PUT] fallo de red'), findsOneWidget);
    expect(find.text('3 líneas · en vivo'), findsOneWidget);
  });

  testWidgets('Registro vacío muestra el estado vacío explicado', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async => _statusMap());

    final bridge = VpnBridge();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: LogScreen(bridge: bridge)),
      ),
    );
    await bridge.poll();
    await tester.pump();

    expect(find.text('Sin actividad todavía'), findsOneWidget);
    expect(find.text('Sin actividad'), findsOneWidget); // subtítulo de la cabecera
  });

  test('El puente parsea el mapa nativo completo', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'getStatus') {
        return _statusMap(state: 'conectando', log: <String>['[01:02:03 INFO] hola']);
      }
      return null;
    });

    final bridge = VpnBridge();
    await bridge.poll();

    expect(bridge.snapshot.state, VpnState.connecting);
    expect(bridge.snapshot.stats.storeGetOk, 120);
    expect(bridge.snapshot.stats.storeFailures, 3);
    expect(bridge.snapshot.stats.bytesDown, 842000);
    expect(bridge.snapshot.logLines, <String>['[01:02:03 INFO] hola']);
  });

  test('toggle conecta cuando está detenida y desconecta cuando está activa', () async {
    final calls = <String>[];
    String state = 'detenida';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      if (call.method == 'connect') {
        state = 'conectando';
        return true;
      }
      if (call.method == 'disconnect') {
        state = 'detenida';
        return true;
      }
      if (call.method == 'getStatus') {
        return _statusMap(state: state);
      }
      return null;
    });

    final bridge = VpnBridge();

    // Detenida → connect
    final connected = await bridge.toggle();
    expect(connected, isTrue);
    expect(calls, contains('connect'));

    // Activa → disconnect
    await bridge.poll(); // el estado ahora es 'conectando' según el mock
    final disconnected = await bridge.toggle();
    expect(disconnected, isTrue);
    expect(calls, contains('disconnect'));
  });
}
