import 'package:flutter/material.dart';

import '../core/vpn_bridge.dart';
import '../theme/app_theme.dart';
import '../widgets/panels.dart';
import 'login_screen.dart';

/// Pantalla de **Ajustes Avanzados**.
///
/// Permite al usuario modificar las variables clave del túnel:
///  - `pollInterval` (s) — intervalo base de sondeo.
///  - `chunkSize` (B) — tamaño del bloque TCP enviado a ToDus.
///  - `maxSessions` — tope de sesiones SOCKS5/TCP simultáneas.
///  - `maxConcurrentHttp` — peticiones PUT/GET en paralelo.
///  - `tcpBatchDelayMs` — ventana de batching TCP.
///  - `tcpBatchMaxBytes` — tamaño máximo del bloque TCP coalescido.
///  - `backoffInitialMs` / `backoffMaxMs` / `backoffFactor` — backoff.
///  - `circuitFailThreshold` / `circuitOpenMs` — circuit breaker.
///  - Filtrado de apps (lista blanca).
///
/// Los valores se persisten en `SharedPreferences` (Kotlin) y se aplican
/// reconectando la VPN si estaba activa.
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
  String? _lastMessage;

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
    values['account_phone'] = account?.phone ?? '';
    final allowed = (values['allowed_apps'] as String? ?? '').split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    setState(() {
      _values = values;
      _selectedApps
        ..clear()
        ..addAll(allowed);
      _loading = false;
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
    };
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
        'rtc_server': '',
        'allowed_apps': '',
      };
      _selectedApps.clear();
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          title: Text('Ajustes Avanzados', style: theme.textTheme.titleLarge),
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
        title: Text('Ajustes Avanzados', style: theme.textTheme.titleLarge),
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
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Estabilidad y resiliencia',
                        style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(
                      'Parámetros del túnel RTC. Los cambios se '
                      'aplican al reconectar la VPN.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              sliver: SliverList.list(
                children: [
                  const SectionHeader(label: 'Sondeo y sesiones'),
                  HairlineCard(
                    child: Column(
                      children: [
                        _SliderRow(
                          label: 'Intervalo de sondeo',
                          unit: 's',
                          value: (_asDouble(_values['poll_interval']) )
                              .clamp(0.05, 10.0),
                          min: 0.05,
                          max: 10.0,
                          divisions: 199,
                          decimals: 2,
                          onChanged: (v) => _set('poll_interval', v),
                        ),
                        const HairlineDivider(),
                        _IntSliderRow(
                          label: 'Sesiones máximas',
                          value: _asInt(_values['max_sessions']).clamp(2, 256),
                          min: 2,
                          max: 64,
                          onChanged: (v) => _set('max_sessions', v),
                        ),
                        const HairlineDivider(),
                        _IntSliderRow(
                          label: 'HTTP simultáneas',
                          value: _asInt(_values['max_concurrent_http']).clamp(1, 32),
                          min: 1,
                          max: 32,
                          onChanged: (v) => _set('max_concurrent_http', v),
                        ),
                        const HairlineDivider(),
                        _IntSliderRow(
                          label: 'Reintentos HTTP',
                          value: _asInt(_values['http_retries']).clamp(0, 8),
                          min: 0,
                          max: 8,
                          onChanged: (v) => _set('http_retries', v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  const SectionHeader(label: 'Tamaño de bloque y ventana'),
                  HairlineCard(
                    child: Column(
                      children: [
                        _IntSliderRow(
                          label: 'Chunk TCP (KiB)',
                          value: (_asInt(_values['chunk_size']) ~/ 1024).clamp(8, 2048),
                          min: 8,
                          max: 2048,
                          onChanged: (v) => _set('chunk_size', v * 1024),
                        ),
                        const HairlineDivider(),
                        _IntSliderRow(
                          label: 'Ventana (bloques en vuelo)',
                          value: _asInt(_values['window_size']).clamp(1, 64),
                          min: 1,
                          max: 64,
                          onChanged: (v) => _set('window_size', v),
                        ),
                        const HairlineDivider(),
                        _IntSliderRow(
                          label: 'ACK cada N frames',
                          value: _asInt(_values['ack_every']).clamp(1, 32),
                          min: 1,
                          max: 32,
                          onChanged: (v) => _set('ack_every', v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  const SectionHeader(label: 'Batching TCP'),
                  HairlineCard(
                    child: Column(
                      children: [
                        _IntSliderRow(
                          label: 'Delay del búfer (ms)',
                          value: _asInt(_values['tcp_batch_delay_ms']).clamp(0, 500),
                          min: 0,
                          max: 500,
                          onChanged: (v) => _set('tcp_batch_delay_ms', v),
                        ),
                        const HairlineDivider(),
                        _IntSliderRow(
                          label: 'Tamaño máx (KiB)',
                          value: (_asInt(_values['tcp_batch_max_bytes']) ~/ 1024).clamp(4, 512),
                          min: 4,
                          max: 512,
                          onChanged: (v) => _set('tcp_batch_max_bytes', v * 1024),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  const SectionHeader(label: 'Backoff exponencial'),
                  HairlineCard(
                    child: Column(
                      children: [
                        _IntSliderRow(
                          label: 'Espera inicial (ms)',
                          value: _asInt(_values['backoff_initial_ms']).clamp(100, 10000),
                          min: 100,
                          max: 10000,
                          onChanged: (v) => _set('backoff_initial_ms', v),
                        ),
                        const HairlineDivider(),
                        _IntSliderRow(
                          label: 'Espera máxima (ms)',
                          value: _asInt(_values['backoff_max_ms']).clamp(1000, 120000),
                          min: 1000,
                          max: 120000,
                          onChanged: (v) => _set('backoff_max_ms', v),
                        ),
                        const HairlineDivider(),
                        _SliderRow(
                          label: 'Factor exponencial',
                          unit: '×',
                          value: _asDouble(_values['backoff_factor']).clamp(1.0, 4.0),
                          min: 1.0,
                          max: 4.0,
                          divisions: 30,
                          decimals: 1,
                          onChanged: (v) => _set('backoff_factor', v),
                        ),
                        const HairlineDivider(),
                        _IntSliderRow(
                          label: 'Jitter (ms)',
                          value: _asInt(_values['backoff_jitter_ms']).clamp(0, 2000),
                          min: 0,
                          max: 2000,
                          onChanged: (v) => _set('backoff_jitter_ms', v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  const SectionHeader(label: 'Circuit breaker'),
                  HairlineCard(
                    child: Column(
                      children: [
                        _IntSliderRow(
                          label: 'Fallos para abrir',
                          value: _asInt(_values['circuit_fail_threshold']).clamp(1, 32),
                          min: 1,
                          max: 32,
                          onChanged: (v) => _set('circuit_fail_threshold', v),
                        ),
                        const HairlineDivider(),
                        _IntSliderRow(
                          label: 'Tiempo abierto (s)',
                          value: (_asInt(_values['circuit_open_ms']) ~/ 1000).clamp(1, 120),
                          min: 1,
                          max: 120,
                          onChanged: (v) => _set('circuit_open_ms', v * 1000),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  const SectionHeader(label: 'UDP'),
                  HairlineCard(
                    child: Column(
                      children: [
                        _IntSliderRow(
                          label: 'Datagramas por lote',
                          value: _asInt(_values['udp_batch_count']).clamp(1, 256),
                          min: 1,
                          max: 256,
                          onChanged: (v) => _set('udp_batch_count', v),
                        ),
                        const HairlineDivider(),
                        _IntSliderRow(
                          label: 'Delay de lote (ms)',
                          value: _asInt(_values['udp_batch_delay_ms']).clamp(0, 500),
                          min: 0,
                          max: 500,
                          onChanged: (v) => _set('udp_batch_delay_ms', v),
                        ),
                        const HairlineDivider(),
                        _IntSliderRow(
                          label: 'Tamaño máx lote (KiB)',
                          value: (_asInt(_values['udp_batch_max_bytes']) ~/ 1024).clamp(8, 512),
                          min: 8,
                          max: 512,
                          onChanged: (v) => _set('udp_batch_max_bytes', v * 1024),
                        ),
                        const HairlineDivider(),
                        _IntSliderRow(
                          label: 'Workers UDP',
                          value: _asInt(_values['udp_upload_workers']).clamp(1, 16),
                          min: 1,
                          max: 16,
                          onChanged: (v) => _set('udp_upload_workers', v),
                        ),
                        const HairlineDivider(),
                        _SliderRow(
                          label: 'Poll UDP',
                          unit: 's',
                          value: _asDouble(_values['udp_poll_interval']).clamp(0.02, 5.0),
                          min: 0.02,
                          max: 5.0,
                          divisions: 99,
                          decimals: 2,
                          onChanged: (v) => _set('udp_poll_interval', v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  SectionHeader(
                    label: 'Filtrado de apps',
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
                    onToggle: (pkg) {
                      setState(() {
                        if (_selectedApps.contains(pkg)) {
                          _selectedApps.remove(pkg);
                        } else {
                          _selectedApps.add(pkg);
                        }
                      });
                    },
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
                  const SizedBox(height: 24),
                  const SectionHeader(label: 'Servidor RTC (WebRTC)'),
                  HairlineCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          initialValue: _values['rtc_server'] as String? ?? '',
                          autocorrect: false,
                          enableSuggestions: false,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(
                            labelText: 'Dirección del rtcvpn-server',
                            helperText: 'Vacío = auto-descubrimiento (GitHub). '
                                'Ejemplo: http://20.123.45.67:8080',
                          ),
                          onChanged: (v) => _set('rtc_server', v),
                        ),
                        const HairlineDivider(),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          child: Row(
                            children: [
                              const Icon(Icons.person_outline,
                                  size: 20, color: AppColors.textMuted),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Cuenta toDus: ${(_values['account_phone'] as String?)?.isNotEmpty == true ? _values['account_phone'] : '—'}',
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                              TextButton.icon(
                                onPressed: _logout,
                                icon: const Icon(Icons.logout, size: 18),
                                label: const Text('Salir'),
                                style: TextButton.styleFrom(
                                  foregroundColor: AppColors.danger,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(_saving ? 'Guardando…' : 'Guardar y aplicar'),
                  ),
                  const SizedBox(height: 12),
                  if (_lastMessage != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        _lastMessage!,
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ],
        ),
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
                  leading: Icon(
                    selected ? Icons.check_circle : Icons.circle_outlined,
                    color: selected ? theme.colorScheme.primary : AppColors.textMuted,
                    size: 22,
                  ),
                  title: Text(app.label, style: theme.textTheme.bodyMedium),
                  subtitle: Text(
                    app.packageName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: kMonoFont,
                      fontSize: 11,
                    ),
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
