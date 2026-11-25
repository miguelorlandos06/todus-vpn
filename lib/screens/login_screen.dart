import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/vpn_bridge.dart';
import '../theme/app_theme.dart';
import 'root_shell.dart';

/// Pantalla de entrada: «Ingresar número».
///
/// Estructura (según especificación):
///  - Marca arriba («ToDus VPN» con emblema).
///  - Título superior centrado: «Ingresar número».
///  - Subtítulo: «Por favor, ingresa el número de tú cuenta de toDus para
///    continuar.»
///  - Contenedor cuadrado con la bandera cubana y «+53»; a su lado,
///    contenedor rectangular para el número de 8 dígitos, con indicador de
///    progreso dígito a dígito.
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
    _focus.addListener(() => setState(() {}));
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
    final digits = _controller.text;

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
                      const SizedBox(height: 40),
                      // ── Marca ───────────────────────────────────────────
                      const _BrandMark(),
                      const SizedBox(height: 36),
                      // ── Título superior centrado ──────────────────────
                      Text(
                        'Ingresar número',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontFamily: kDisplayFont,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 10),
                      // ── Subtítulo ─────────────────────────────────────
                      Text(
                        'Por favor, ingresa el número de tú cuenta de toDus para continuar.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppColors.textMuted,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 36),
                      // ── Bandera +53 │ número de 8 dígitos ─────────────
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: <Widget>[
                          // Contenedor cuadrado: bandera cubana + +53
                          _FlagBox(focused: _focus.hasFocus),
                          const SizedBox(width: 12),
                          // Contenedor rectangular: número de 8 dígitos
                          Expanded(child: _PhoneBox(controller: _controller, focus: _focus)),
                        ],
                      ),
                      const SizedBox(height: 18),
                      // ── Progreso dígito a dígito ──────────────────────
                      _DigitProgress(count: digits.length),
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Text(
                          digits.isEmpty
                              ? 'Número cubano de 8 dígitos (sin el 53)'
                              : (digits.length < 8
                                  ? 'Faltan ${8 - digits.length} dígitos'
                                  : 'Número completo'),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: digits.length == 8
                                ? AppColors.accent
                                : AppColors.textMuted,
                          ),
                        ),
                      ),
                      if (_error != null) ...<Widget>[
                        const SizedBox(height: 18),
                        _ErrorBanner(message: _error!),
                      ],
                      const SizedBox(height: 40),
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
        child: _ContinueButton(
          enabled: _canContinue,
          working: _working,
          onPressed: _continue,
        ),
      ),
    );
  }
}

/// Marca de la app sobre la pantalla de login: emblema + wordmark.
class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[AppColors.accentDeep, AppColors.accent],
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: AppColors.accent.withValues(alpha: 0.28),
                blurRadius: 30,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: const Icon(Icons.shield_outlined, size: 32, color: Color(0xFF04211C)),
        ),
        const SizedBox(height: 14),
        Text(
          'ToDus VPN',
          style: theme.textTheme.titleLarge?.copyWith(
            fontFamily: kDisplayFont,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }
}

/// Contenedor cuadrado con la bandera cubana y el prefijo «+53».
///
/// El borde se anima al enfocar el campo (sincronizado con _PhoneBox).
class _FlagBox extends StatelessWidget {
  const _FlagBox({required this.focused});

  final bool focused;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: focused ? AppColors.accent : AppColors.outline,
          width: focused ? 1.6 : 1.2,
        ),
        boxShadow: focused
            ? <BoxShadow>[
                BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.18),
                  blurRadius: 22,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              boxShadow: const <BoxShadow>[
                BoxShadow(color: Color(0x66000000), blurRadius: 8, offset: Offset(0, 3)),
              ],
            ),
            child: const ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(6)),
              child: CustomPaint(
                size: Size(46, 28),
                painter: CubanFlagPainter(),
              ),
            ),
          ),
          const SizedBox(height: 9),
          const Text(
            '+53',
            style: TextStyle(
              fontFamily: kMonoFont,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              fontSize: 16,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Contenedor rectangular del número de teléfono (8 dígitos).
class _PhoneBox extends StatelessWidget {
  const _PhoneBox({required this.controller, required this.focus});

  final TextEditingController controller;
  final FocusNode focus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final focused = focus.hasFocus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      height: 96,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: focused ? AppColors.accent : AppColors.outline,
          width: focused ? 1.6 : 1.2,
        ),
        boxShadow: focused
            ? <BoxShadow>[
                BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.18),
                  blurRadius: 22,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: TextField(
        controller: controller,
        focusNode: focus,
        autofocus: true,
        cursorColor: AppColors.accent,
        cursorWidth: 2,
        enabled: true,
        keyboardType: TextInputType.phone,
        maxLength: 8,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
        textAlign: TextAlign.left,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) {},
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
            color: AppColors.textMuted.withValues(alpha: 0.4),
            letterSpacing: 2.4,
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 26),
        ),
      ),
    );
  }
}

/// Indicador de progreso: 8 segmentos que se llenan con los dígitos escritos.
class _DigitProgress extends StatelessWidget {
  const _DigitProgress({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: List<Widget>.generate(8, (i) {
          final filled = i < count;
          return Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              height: 4,
              decoration: BoxDecoration(
                color: filled
                    ? AppColors.accent
                    : AppColors.surfaceRaised,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Botón «Continuar»: degradado teal cuando está activo, apagado si faltan
/// dígitos; spinner mientras se solicita el JWT.
class _ContinueButton extends StatelessWidget {
  const _ContinueButton({
    required this.enabled,
    required this.working,
    required this.onPressed,
  });

  final bool enabled;
  final bool working;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      height: 58,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: enabled
            ? const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: <Color>[AppColors.accentDeep, AppColors.accent],
              )
            : null,
        color: enabled ? null : AppColors.surfaceRaised,
        boxShadow: enabled
            ? <BoxShadow>[
                BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.3),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: enabled ? onPressed : null,
          child: Center(
            child: working
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.6,
                      color: AppColors.accent,
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        'Continuar',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontFamily: kDisplayFont,
                          fontWeight: FontWeight.w700,
                          color: enabled
                              ? const Color(0xFF04211C)
                              : AppColors.textMuted,
                          fontSize: 17,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.arrow_forward,
                        size: 20,
                        color: enabled ? const Color(0xFF04211C) : AppColors.textMuted,
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// Aviso de error con el último fallo del login.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.error_outline, color: AppColors.danger, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.textPrimary,
                height: 1.35,
              ),
            ),
          ),
        ],
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
