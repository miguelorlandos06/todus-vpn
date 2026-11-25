import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/vpn_bridge.dart';
import '../theme/app_theme.dart';
import 'root_shell.dart';

/// Pantalla de entrada: «Ingresar número».
///
/// Estructura (según especificación):
///  - Título superior centrado: «Ingresar número».
///  - Subtítulo: «Por favor, ingresa el número de tú cuenta de toDus para
///    continuar.»
///  - Contenedor cuadrado con la bandera cubana y «+53»; a su lado,
///    contenedor rectangular para el número de 8 dígitos.
///  - Botón «Continuar» en la parte inferior: solicita el JWT de toDus con el
///    teléfono y una contraseña aleatoria de 32 caracteres (generada y
///    persistida en Kotlin) y lleva al Home.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.bridge});

  final VpnBridge bridge;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _canContinue => _controller.text.length == 8 && !_working;

  Future<void> _continue() async {
    if (!_canContinue) return;
    final digits = _controller.text;
    final fullPhone = '53$digits';
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.bridge.loginToDus(fullPhone);
      if (!mounted) return;
      // JWT obtenido: ir al Home (reemplaza la pila para que «atrás» no vuelva
      // al login de una sesión ya iniciada).
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => RootShell(bridge: widget.bridge)),
      );
    } catch (e) {
      // PlatformException con el mensaje de auth.todus.cu u otro fallo.
      setState(() {
        _error = _humanizeError(e);
      });
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Extrae un mensaje presentable de la excepción del canal.
  String _humanizeError(Object e) {
    var msg = e.toString();
    if (msg.contains('LOGIN')) {
      final m = RegExp(r'message: (.+?), (null|details)').firstMatch(msg);
      if (m != null) return m.group(1)!.trim();
      final m2 = RegExp(r'LOGIN, (.+?),').firstMatch(msg);
      if (m2 != null) return m2.group(1)!.trim();
      return 'No se pudo autenticar con toDus. Verifica el número e inténtalo de nuevo.';
    }
    return msg.replaceFirst('Exception: ', '').trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const SizedBox(height: 56),
                      // ── Título superior centrado ──────────────────────
                      Text(
                        'Ingresar número',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontFamily: kDisplayFont,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // ── Subtítulo ─────────────────────────────────────
                      Text(
                        'Por favor, ingresa el número de tú cuenta de toDus para continuar.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppColors.textMuted,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 40),
                      // ── Bandera +53 │ número de 8 dígitos ─────────────
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: <Widget>[
                          // Contenedor cuadrado: bandera cubana + +53
                          Container(
                            width: 92,
                            height: 92,
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: _focus.hasFocus
                                    ? AppColors.accent
                                    : AppColors.outline,
                                width: 1.2,
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                const CustomPaint(
                                  size: Size(44, 26),
                                  painter: CubanFlagPainter(),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '+53',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontFamily: kMonoFont,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary,
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Contenedor rectangular: número de 8 dígitos
                          Expanded(
                            child: Container(
                              height: 92,
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: _focus.hasFocus
                                      ? AppColors.accent
                                      : AppColors.outline,
                                  width: 1.2,
                                ),
                              ),
                              child: TextField(
                                controller: _controller,
                                focusNode: _focus,
                                autofocus: true,
                                enabled: !_working,
                                keyboardType: TextInputType.phone,
                                maxLength: 8,
                                inputFormatters: <TextInputFormatter>[
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                textAlign: TextAlign.left,
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) => _continue(),
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontFamily: kMonoFont,
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.textPrimary,
                                  letterSpacing: 2.4,
                                ),
                                decoration: InputDecoration(
                                  counterText: '',
                                  hintText: '5xxxxxxx',
                                  hintStyle: theme.textTheme.headlineSmall?.copyWith(
                                    fontFamily: kMonoFont,
                                    color: AppColors.textMuted.withValues(alpha: 0.45),
                                    letterSpacing: 2.4,
                                  ),
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 24,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Ayuda: cuenta atrás de dígitos.
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Text(
                          _controller.text.isEmpty
                              ? 'Número cubano de 8 dígitos (sin el 53)'
                              : (_controller.text.length < 8
                                  ? 'Faltan ${8 - _controller.text.length} dígitos'
                                  : 'Número completo'),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: _controller.text.length == 8
                                ? AppColors.accent
                                : AppColors.textMuted,
                          ),
                        ),
                      ),
                      if (_error != null) ...<Widget>[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.danger.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: AppColors.danger.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Row(
                            children: <Widget>[
                              const Icon(Icons.error_outline,
                                  color: AppColors.danger, size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 48),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
      // ── Botón Continuar en la parte inferior ─────────────────────────────
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(28, 0, 28, 24),
        child: FilledButton(
          onPressed: _canContinue ? _continue : null,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            backgroundColor: _canContinue ? AppColors.accent : AppColors.surfaceRaised,
            foregroundColor: _canContinue
                ? const Color(0xFF04211C)
                : AppColors.textMuted,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          child: _working
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.6,
                    color: AppColors.accent,
                  ),
                )
              : const Text('Continuar', style: TextStyle(fontSize: 17)),
        ),
      ),
    );
  }
}

/// Bandera cubana dibujada a mano (sin depender de emojis ni assets):
/// 5 franjas horizontales azul-blanco-azul-blanco-azul, triángulo rojo al
/// asta y estrella blanca de 5 puntas.
class CubanFlagPainter extends CustomPainter {
  const CubanFlagPainter();

  static const Color _blue = Color(0xFF003893);
  static const Color _red = Color(0xFFCF142B);
  static const Color _white = Color(0xFFFFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final stripe = h / 5;

    // Fondo blanco base.
    final bg = Paint()..color = _white;
    canvas.drawRect(Offset.zero & size, bg);

    // Franjas azules (1, 3, 5).
    final blue = Paint()..color = _blue;
    canvas.drawRect(Rect.fromLTWH(0, 0, w, stripe), blue);
    canvas.drawRect(Rect.fromLTWH(0, stripe * 2, w, stripe), blue);
    canvas.drawRect(Rect.fromLTWH(0, stripe * 4, w, stripe), blue);

    // Triángulo rojo al asta (izquierda).
    final triangle = Path()
      ..moveTo(0, 0)
      ..lineTo(h * 0.9, h / 2)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(triangle, Paint()..color = _red);

    // Estrella blanca de 5 puntas en el centro del triángulo.
    final cx = h * 0.32;
    final cy = h / 2;
    final outer = h * 0.22;
    final inner = outer * 0.382;
    final star = Path();
    for (var i = 0; i < 10; i++) {
      final angle = -math.pi / 2 + i * math.pi / 5;
      final r = i.isEven ? outer : inner;
      final px = cx + r * math.cos(angle);
      final py = cy + r * math.sin(angle);
      if (i == 0) {
        star.moveTo(px, py);
      } else {
        star.lineTo(px, py);
      }
    }
    star.close();
    canvas.drawPath(star, Paint()..color = _white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
