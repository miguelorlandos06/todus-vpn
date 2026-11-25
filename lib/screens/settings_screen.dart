import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/vpn_bridge.dart';
import '../theme/app_theme.dart';
import '../widgets/panels.dart';
import 'login_screen.dart';

/// Pantalla de **Ajustes** — reorganizada por relevancia.
///
/// Orden de las secciones (de lo más usado a lo más técnico):
///  1. **Cuenta**: número toDus en sesión y cierre de sesión.
///  2. **Servidor RTC**: número al que la app «llama» por XMPP
///     (señalización 100 % XMPP: CALL → ACCEPT → TURN → DataChannel).
///  3. **Túnel WebRTC**: sesiones, timeouts y búfer TCP que gobiernan el
///     DataChannel.
///  4. **Red**: IPv6 y demás opciones de la interfaz TUN.
///  5. **Filtrado de apps**: lista blanca de aplicaciones.
///  6. **Avanzado (relay legacy)**: plegada por defecto; parámetros del
///     transporte relay antiguo y de resiliencia que rara vez se tocan.
///
/// Los valores se persisten en `SharedPreferences` (Kotlin) y se aplican
/// reconectando la VPN si estaba activa. El botón de guardar queda fijo
/// abajo para estar siempre accesible.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.bridge});

  final VpnBridge bridge;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic> _values = <String, dynamic>{};
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  String? _lastMessage;
  String _accountPhone = '';

  // Apps instaladas y seleccionadas.
  final List<InstalledApp> _installedApps = <InstalledApp>[];
  final Set<String> _selectedApps = <String>{};
  String _appFilter = '';
  bool _loadingApps = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() => _loading = true);
    final values = await widget.bridge.getSettings();
    final account = await widget.bridge.getAccount();
    final allowed = (values['allowed_apps'] as String? ?? '').split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    setState(() {
      _values = values;
      _accountPhone = account?.phone ?? '';
      _selectedApps
        ..clear()
        ..addAll(allowed);
      _loading = false;
      _dirty = false;
    });
  }

  Future<void> _loadInstalledApps() async {
    setState(() => _loadingApps = true);
    final apps = await widget.bridge.listInstalledApps();
    setState(() {
      _installedApps
        ..clear()
        ..addAll(apps);
      _loadingApps = false;
    });
  }

  void _set<T extends Object>(String key, T value) {
    setState(() {
      _values = <String, dynamic>{
        ..._values,
        key: value,
      };
      _dirty = true;
    });
  }

  void _toggleApp(String pkg) {
    setState(() {
      if (_selectedApps.contains(pkg)) {
        _selectedApps.remove(pkg);
      } else {
        _selectedApps.add(pkg);
      }
      _dirty = true;
    });
  }

  /// Cierra la sesión toDus y vuelve a la pantalla de login.
  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Cerrar sesión?'),
        content: const Text(
          'Se detendrá la VPN y se olvidará el número de toDus de este '
          'dispositivo. Necesitarás volver a ingresar tu número.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cerrar sesión'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.bridge.logout();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => LoginScreen(bridge: widget.bridge)),
      (route) => false,
    );
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _lastMessage = null;
    });
    final toSave = <String, dynamic>{
      ..._values,
      'allowed_apps': _selectedApps.join('\n'),
    }..remove('account_phone');
    final ok = await widget.bridge.setSettings(toSave);
    if (ok) {
      // Recarga el hex efectivo por si la clave es una frase (SHA-256).
      final fresh = await widget.bridge.getSettings();
      final hex = fresh['relay_secret_effective'];
      if (hex != null) {
        _values = <String, dynamic>{
          ..._values,
          'relay_secret_effective': hex,
        };
      }
    }
    setState(() {
      _saving = false;
      _dirty = false;
      _lastMessage = ok
          ? 'Ajustes guardados. Si la VPN estaba activa, se reconectó automáticamente.'
          : 'No se pudieron guardar los ajustes (¿falta puente nativo?).';
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_lastMessage ?? '')),
      );
    }
  }

  Future<void> _resetDefaults() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restaurar valores por defecto'),
        content: const Text(
          'Se reestablecen todos los parámetros a sus valores estables por '
          'defecto. Si la VPN está activa, se reconectará.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restaurar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // Defaults estables — coinciden con RelaySettings.DEFAULT_*.
    setState(() {
      _values = <String, dynamic>{
        'poll_interval': 1.0,
        'chunk_size': 524288,
        'max_sessions': 10,
        'window_size': 16,
        'ack_every': 4,
        'http_retries': 4,
        'http_timeout': 20.0,
        'connect_timeout': 25.0,
        'queue_poll_interval': 0.5,
        'udp_batch_count': 64,
        'udp_batch_delay_ms': 50,
        'udp_batch_max_bytes': 131072,
        'udp_idle_timeout': 180.0,
        'udp_max_flows': 128,
        'udp_poll_interval': 0.1,
        'udp_upload_workers': 4,
        'delete_after_read': false,
        'max_concurrent_http': 8,
        'backoff_initial_ms': 1000,
        'backoff_max_ms': 30000,
        'backoff_factor': 2.0,
        'backoff_jitter_ms': 250,
        'circuit_fail_threshold': 8,
        'circuit_open_ms': 15000,
        'tcp_batch_delay_ms': 50,
        'tcp_batch_max_bytes': 65536,
        'ipv6_enabled': false,
        'relay_secret': '',
        'base_url': '',
        'rtc_server_phone': '5350256349',
        'allowed_apps': '',
      };
      _selectedApps.clear();
      _dirty = true;
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          title: Text('Ajustes', style: theme.textTheme.titleLarge),
          backgroundColor: theme.scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Ajustes', style: theme.textTheme.titleLarge),
        backgroundColor: theme.scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          IconButton(
            tooltip: 'Restaurar por defecto',
            onPressed: _resetDefaults,
            icon: const Icon(Icons.restart_alt),
            color: AppColors.textMuted,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                    sliver: SliverList.list(
                      children: [
                        // ── 1. Cuenta ────────────────────────────────────
                        _AccountCard(phone: _accountPhone, onLogout: _logout),
                        const SizedBox(height: 28),

                        // ── 2. Servidor RTC ──────────────────────────────
                        const _GroupHeader(
                          icon: Icons.hub_outlined,
                          label: 'Servidor RTC',
                          description: 'Señalización 100% XMPP: la app llama a este '
                              'número (CALL → ACCEPT) y abre el DataChannel por TURN.',
                        ),
                        _ServerPhoneCard(
                          value: (_values['rtc_server_phone'] as String? ?? ''),
                          onChanged: (v) => _set('rtc_server_phone', v),
                        ),
                        const SizedBox(height: 28),

                        // ── 3. Túnel WebRTC ─────────────────────────────
                        const _GroupHeader(
                          icon: Icons.bolt_outlined,
                          label: 'Túnel WebRTC',
                          description: 'Sesiones y búfer del DataChannel (TURN).',
                        ),
                        HairlineCard(
                          child: Column(
                            children: [
                              _IntSliderRow(
                                label: 'Sesiones máximas',
                                value: _asInt(_values['max_sessions']).clamp(2, 64),
                                min: 2,
                                max: 64,
                                onChanged: (v) => _set('max_sessions', v),
                              ),
                              const HairlineDivider(),
                              _SliderRow(
                                label: 'Timeout de conexión',
                                unit: 's',
                                value: _asDouble(_values['connect_timeout']).clamp(5, 120),
                                min: 5,
                                max: 120,
                                divisions: 115,
                                decimals: 0,
                                onChanged: (v) => _set('connect_timeout', v),
                              ),
                              const HairlineDivider(),
                              _IntSliderRow(
                                label: 'Búfer TCP (delay)',
                                value: _asInt(_values['tcp_batch_delay_ms']).clamp(0, 500),
                                min: 0,
                                max: 500,
                                onChanged: (v) => _set('tcp_batch_delay_ms', v),
                              ),
                              const HairlineDivider(),
                              _IntSliderRow(
                                label: 'Búfer TCP máx (KiB)',
                                value: (_asInt(_values['tcp_batch_max_bytes']) ~/ 1024).clamp(4, 512),
                                min: 4,
                                max: 512,
                                onChanged: (v) => _set('tcp_batch_max_bytes', v * 1024),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 28),

                        // ── 4. Red ──────────────────────────────────────
                        const _GroupHeader(
                          icon: Icons.language_outlined,
                          label: 'Red',
                          description: 'Opciones de la interfaz TUN del dispositivo.',
                        ),
                        HairlineCard(
                          child: _SwitchRow(
                            label: 'Capturar IPv6 (::/0)',
                            value: _values['ipv6_enabled'] == true,
                            onChanged: (v) => _set('ipv6_enabled', v),
                          ),
                        ),
                        const SizedBox(height: 28),

                        // ── 5. Filtrado de apps ──────────────────────────
                        _GroupHeader(
                          icon: Icons.apps_outlined,
                          label: 'Filtrado de apps',
                          description: 'Sin selección, todo el teléfono pasa por la VPN.',
                          trailing: TextButton.icon(
                            onPressed: _loadingApps ? null : _loadInstalledApps,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Cargar'),
                          ),
                        ),
                        _AppFilterCard(
                          installedApps: _installedApps,
                          selectedApps: _selectedApps,
                          filter: _appFilter,
                          loading: _loadingApps,
                          onFilterChanged: (v) => setState(() => _appFilter = v),
                          onToggle: _toggleApp,
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            _selectedApps.isEmpty
                                ? 'Sin filtrado: TODO el teléfono pasa por la VPN.'
                                : 'Solo ${_selectedApps.length} app(s) pasarán por la VPN.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        const SizedBox(height: 28),

                        // ── 6. Avanzado (relay legacy) ───────────────────
                        _LegacySection(
                          values: _values,
                          set: _set,
                        ),
                        if (_lastMessage != null) ...<Widget>[
                          const SizedBox(height: 16),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              _lastMessage!,
                              style: theme.textTheme.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                        const SizedBox(height: 120),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      // ── Barra fija de guardado, siempre visible ─────────────────────────
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: _SaveBar(saving: _saving, dirty: _dirty, onSave: _save),
      ),
    );
  }

  double _asDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  int _asInt(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

/// Cabecera de grupo con icono, título y descripción breve.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.icon,
    required this.label,
    required this.description,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String description;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 12),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
            ),
            child: Icon(icon, size: 18, color: AppColors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  style: theme.textTheme.labelMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.3),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Tarjeta de cuenta: número en sesión + botón para salir.
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.phone, required this.onLogout});

  final String phone;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HairlineCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[AppColors.accentDeep, AppColors.accent],
              ),
            ),
            child: const Icon(Icons.person_outline, size: 22, color: Color(0xFF04211C)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('CUENTA TODUS', style: theme.textTheme.labelSmall),
                const SizedBox(height: 3),
                Text(
                  phone.isEmpty ? '—' : '+53 ${phone.substring(phone.length >= 8 ? 2 : 0)}',
                  style: const TextStyle(
                    fontFamily: kMonoFont,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: onLogout,
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Salir'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.danger,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tarjeta del número del servidor RTC (al que se llama por XMPP).
class _ServerPhoneCard extends StatefulWidget {
  const _ServerPhoneCard({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_ServerPhoneCard> createState() => _ServerPhoneCardState();
}

class _ServerPhoneCardState extends State<_ServerPhoneCard> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(covariant _ServerPhoneCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sincroniza tras «Restaurar por defecto» sin pisar la selección del teclado.
    if (widget.value != oldWidget.value && widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HairlineCard(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                '+53',
                style: TextStyle(
                  fontFamily: kMonoFont,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accent,
                  fontSize: 16,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _controller,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.phone,
                  maxLength: 10,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  cursorColor: AppColors.accent,
                  style: const TextStyle(
                    fontFamily: kMonoFont,
                    color: AppColors.textPrimary,
                    fontSize: 17,
                    letterSpacing: 1.2,
                  ),
                  decoration: const InputDecoration(
                    counterText: '',
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 12),
                    hintText: '5350256349',
                    hintStyle: TextStyle(
                      fontFamily: kMonoFont,
                      color: AppColors.textMuted,
                      fontSize: 17,
                    ),
                  ),
                  onChanged: widget.onChanged,
                ),
              ),
            ],
          ),
          const HairlineDivider(),
          Padding(
            padding: const EdgeInsets.only(top: 10, left: 4),
            child: Text(
              'Número toDus del servidor (10 dígitos, empieza por 53). '
              'Vacío = 5350256349 (primer número del pool).',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fila con interruptor (toggle) y etiqueta.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      title: Text(label, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}

/// Sección plegada por defecto con los parámetros legacy del relay.
class _LegacySection extends StatefulWidget {
  const _LegacySection({required this.values, required this.set});

  final Map<String, dynamic> values;
  final void Function(String key, Object value) set;

  @override
  State<_LegacySection> createState() => _LegacySectionState();
}

class _LegacySectionState extends State<_LegacySection> {
  bool _expanded = false;

  double _asDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  int _asInt(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = widget.values;
    final s = widget.set;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GroupHeader(
          icon: Icons.tune,
          label: 'Avanzado (relay legacy)',
          description: 'Parámetros del transporte relay antiguo y de '
              'resiliencia. Rara vez necesitan cambios.',
          trailing: IconButton(
            tooltip: _expanded ? 'Plegar' : 'Desplegar',
            onPressed: () => setState(() => _expanded = !_expanded),
            icon: AnimatedRotation(
              turns: _expanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(Icons.expand_more),
            ),
            color: AppColors.textMuted,
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 220),
          crossFadeState: _expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          firstChild: HairlineCard(
            padding: const EdgeInsets.all(14),
            child: Text(
              'Plegado — toca el botón para desplegar.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          secondChild: Column(
            children: [
              HairlineCard(
                child: Column(
                  children: [
                    _IntSliderRow(
                      label: 'Reintentos HTTP',
                      value: _asInt(v['http_retries']).clamp(0, 8),
                      min: 0,
                      max: 8,
                      onChanged: (x) => s('http_retries', x),
                    ),
                    const HairlineDivider(),
                    _IntSliderRow(
                      label: 'HTTP simultáneas',
                      value: _asInt(v['max_concurrent_http']).clamp(1, 32),
                      min: 1,
                      max: 32,
                      onChanged: (x) => s('max_concurrent_http', x),
                    ),
                    const HairlineDivider(),
                    _SliderRow(
                      label: 'Intervalo de sondeo',
                      unit: 's',
                      value: _asDouble(v['poll_interval']).clamp(0.05, 10.0),
                      min: 0.05,
                      max: 10.0,
                      divisions: 199,
                      decimals: 2,
                      onChanged: (x) => s('poll_interval', x),
                    ),
                    const HairlineDivider(),
                    _SliderRow(
                      label: 'Timeout HTTP',
                      unit: 's',
                      value: _asDouble(v['http_timeout']).clamp(5, 120),
                      min: 5,
                      max: 120,
                      divisions: 115,
                      decimals: 0,
                      onChanged: (x) => s('http_timeout', x),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const _LegacySubtitle(label: 'Backoff exponencial'),
              HairlineCard(
                child: Column(
                  children: [
                    _IntSliderRow(
                      label: 'Espera inicial (ms)',
                      value: _asInt(v['backoff_initial_ms']).clamp(100, 10000),
                      min: 100,
                      max: 10000,
                      onChanged: (x) => s('backoff_initial_ms', x),
                    ),
                    const HairlineDivider(),
                    _IntSliderRow(
                      label: 'Espera máxima (ms)',
                      value: _asInt(v['backoff_max_ms']).clamp(1000, 120000),
                      min: 1000,
                      max: 120000,
                      onChanged: (x) => s('backoff_max_ms', x),
                    ),
                    const HairlineDivider(),
                    _SliderRow(
                      label: 'Factor exponencial',
                      unit: '×',
                      value: _asDouble(v['backoff_factor']).clamp(1.0, 4.0),
                      min: 1.0,
                      max: 4.0,
                      divisions: 30,
                      decimals: 1,
                      onChanged: (x) => s('backoff_factor', x),
                    ),
                    const HairlineDivider(),
                    _IntSliderRow(
                      label: 'Jitter (ms)',
                      value: _asInt(v['backoff_jitter_ms']).clamp(0, 2000),
                      min: 0,
                      max: 2000,
                      onChanged: (x) => s('backoff_jitter_ms', x),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const _LegacySubtitle(label: 'Circuit breaker'),
              HairlineCard(
                child: Column(
                  children: [
                    _IntSliderRow(
                      label: 'Fallos para abrir',
                      value: _asInt(v['circuit_fail_threshold']).clamp(1, 32),
                      min: 1,
                      max: 32,
                      onChanged: (x) => s('circuit_fail_threshold', x),
                    ),
                    const HairlineDivider(),
                    _IntSliderRow(
                      label: 'Tiempo abierto (s)',
                      value: (_asInt(v['circuit_open_ms']) ~/ 1000).clamp(1, 120),
                      min: 1,
                      max: 120,
                      onChanged: (x) => s('circuit_open_ms', x * 1000),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const _LegacySubtitle(label: 'Bloques y ventana (relay)'),
              HairlineCard(
                child: Column(
                  children: [
                    _IntSliderRow(
                      label: 'Chunk TCP (KiB)',
                      value: (_asInt(v['chunk_size']) ~/ 1024).clamp(8, 2048),
                      min: 8,
                      max: 2048,
                      onChanged: (x) => s('chunk_size', x * 1024),
                    ),
                    const HairlineDivider(),
                    _IntSliderRow(
                      label: 'Ventana (bloques en vuelo)',
                      value: _asInt(v['window_size']).clamp(1, 64),
                      min: 1,
                      max: 64,
                      onChanged: (x) => s('window_size', x),
                    ),
                    const HairlineDivider(),
                    _IntSliderRow(
                      label: 'ACK cada N frames',
                      value: _asInt(v['ack_every']).clamp(1, 32),
                      min: 1,
                      max: 32,
                      onChanged: (x) => s('ack_every', x),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const _LegacySubtitle(label: 'UDP'),
              HairlineCard(
                child: Column(
                  children: [
                    _IntSliderRow(
                      label: 'Datagramas por lote',
                      value: _asInt(v['udp_batch_count']).clamp(1, 256),
                      min: 1,
                      max: 256,
                      onChanged: (x) => s('udp_batch_count', x),
                    ),
                    const HairlineDivider(),
                    _IntSliderRow(
                      label: 'Delay de lote (ms)',
                      value: _asInt(v['udp_batch_delay_ms']).clamp(0, 500),
                      min: 0,
                      max: 500,
                      onChanged: (x) => s('udp_batch_delay_ms', x),
                    ),
                    const HairlineDivider(),
                    _IntSliderRow(
                      label: 'Tamaño máx lote (KiB)',
                      value: (_asInt(v['udp_batch_max_bytes']) ~/ 1024).clamp(8, 512),
                      min: 8,
                      max: 512,
                      onChanged: (x) => s('udp_batch_max_bytes', x * 1024),
                    ),
                    const HairlineDivider(),
                    _IntSliderRow(
                      label: 'Workers UDP',
                      value: _asInt(v['udp_upload_workers']).clamp(1, 16),
                      min: 1,
                      max: 16,
                      onChanged: (x) => s('udp_upload_workers', x),
                    ),
                    const HairlineDivider(),
                    _SliderRow(
                      label: 'Poll UDP',
                      unit: 's',
                      value: _asDouble(v['udp_poll_interval']).clamp(0.02, 5.0),
                      min: 0.02,
                      max: 5.0,
                      divisions: 99,
                      decimals: 2,
                      onChanged: (x) => s('udp_poll_interval', x),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Subtítulo dentro de la sección avanzada.
class _LegacySubtitle extends StatelessWidget {
  const _LegacySubtitle({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

/// Barra fija inferior con el botón «Guardar y aplicar».
class _SaveBar extends StatelessWidget {
  const _SaveBar({required this.saving, required this.dirty, required this.onSave});

  final bool saving;
  final bool dirty;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(
          top: BorderSide(color: AppColors.outline.withValues(alpha: 0.6)),
        ),
      ),
      padding: const EdgeInsets.only(top: 10),
      child: FilledButton.icon(
        onPressed: saving ? null : onSave,
        icon: saving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(dirty ? Icons.save_outlined : Icons.check_circle_outline, size: 20),
        label: Text(saving ? 'Guardando…' : (dirty ? 'Guardar y aplicar' : 'Guardado')),
      ),
    );
  }
}

/// Fila con slider de coma flotante y valor formateado.
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.unit,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.decimals,
    required this.onChanged,
  });

  final String label;
  final String unit;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final int decimals;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label, style: theme.textTheme.bodyMedium),
              ),
              Text(
                '${value.toStringAsFixed(decimals)} $unit',
                style: tabular(theme.textTheme.titleMedium!.copyWith(
                  fontFamily: kDisplayFont,
                  fontWeight: FontWeight.w600,
                )),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// Fila con slider entero.
class _IntSliderRow extends StatelessWidget {
  const _IntSliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label, style: theme.textTheme.bodyMedium),
              ),
              Text(
                '$value',
                style: tabular(theme.textTheme.titleMedium!.copyWith(
                  fontFamily: kDisplayFont,
                  fontWeight: FontWeight.w600,
                )),
              ),
            ],
          ),
          Slider(
            value: value.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: max - min,
            onChanged: (v) => onChanged(v.round()),
          ),
        ],
      ),
    );
  }
}

/// Tarjeta con la lista de apps instaladas y casillas para marcar las permitidas.
class _AppFilterCard extends StatelessWidget {
  const _AppFilterCard({
    required this.installedApps,
    required this.selectedApps,
    required this.filter,
    required this.loading,
    required this.onFilterChanged,
    required this.onToggle,
  });

  final List<InstalledApp> installedApps;
  final Set<String> selectedApps;
  final String filter;
  final bool loading;
  final ValueChanged<String> onFilterChanged;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (loading) {
      return HairlineCard(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text('Cargando apps instaladas…', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      );
    }
    if (installedApps.isEmpty) {
      return HairlineCard(
        padding: const EdgeInsets.all(22),
        child: Column(
          children: [
            const Icon(Icons.apps_outlined, size: 32, color: AppColors.textMuted),
            const SizedBox(height: 10),
            Text('Pulsa “Cargar” para listar las apps instaladas',
                style: theme.textTheme.bodySmall),
          ],
        ),
      );
    }

    final filterLower = filter.toLowerCase().trim();
    final visible = installedApps.where((a) {
      if (filterLower.isEmpty) return true;
      return a.label.toLowerCase().contains(filterLower) ||
          a.packageName.toLowerCase().contains(filterLower);
    }).toList();

    return HairlineCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 20),
              hintText: 'Buscar app…',
              border: OutlineInputBorder(),
            ),
            onChanged: onFilterChanged,
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final app = visible[index];
                final selected = selectedApps.contains(app.packageName);
                return ListTile(
                  dense: true,
                  title: Text(app.label, style: theme.textTheme.bodyMedium),
                  subtitle: Text(
                    app.packageName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: kMonoFont,
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Checkbox(
                    value: selected,
                    onChanged: (_) => onToggle(app.packageName),
                    activeColor: AppColors.accent,
                  ),
                  onTap: () => onToggle(app.packageName),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
