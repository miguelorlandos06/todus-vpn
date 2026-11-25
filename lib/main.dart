import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/vpn_bridge.dart';
import 'screens/login_screen.dart';
import 'screens/root_shell.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: AppColors.surface,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  final bridge = VpnBridge()..start();
  runApp(ToDusVpnApp(bridge: bridge));
}

/// Raíz de la app: tema oscuro + decisión inicial Login/Home.
///
/// Si ya hay una cuenta toDus guardada (JWT con teléfono + secreto aleatorio
/// de 32 caracteres) se entra directo al Home; si no, aparece la pantalla
/// «Ingresar número».
class ToDusVpnApp extends StatefulWidget {
  const ToDusVpnApp({super.key, required this.bridge});

  /// Puente con el núcleo Kotlin. En producción lo crea `main()`; las pruebas
  /// pueden inyectar uno controlado.
  final VpnBridge bridge;

  @override
  State<ToDusVpnApp> createState() => _ToDusVpnAppState();
}

class _ToDusVpnAppState extends State<ToDusVpnApp> {
  /// null = decidiendo; true = ir al Home; false = ir al login.
  bool? _hasAccount;

  @override
  void initState() {
    super.initState();
    _decideStart();
  }

  Future<void> _decideStart() async {
    final account = await widget.bridge.getAccount();
    if (!mounted) return;
    setState(() => _hasAccount = account != null);
  }

  @override
  void dispose() {
    widget.bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget home;
    switch (_hasAccount) {
      case true:
        home = RootShell(bridge: widget.bridge);
      case false:
        home = LoginScreen(bridge: widget.bridge);
      case null:
        // Decidiendo: pantalla de arranque mínima con el logotipo textual.
        home = const Scaffold(
          backgroundColor: AppColors.background,
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'ToDus VPN',
                  style: TextStyle(
                    fontFamily: kDisplayFont,
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                SizedBox(height: 22),
                SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: AppColors.accent,
                  ),
                ),
              ],
            ),
          ),
        );
    }
    return MaterialApp(
      title: 'ToDus VPN',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: home,
    );
  }
}
