import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../core/vpn_bridge.dart';
import '../core/vpn_ui.dart';
import '../theme/app_theme.dart';
import '../widgets/connect_orb.dart';
import '../widgets/panels.dart';
import '../widgets/status_chip.dart';
import 'about_screen.dart';
import 'settings_screen.dart';

/// Pantalla principal: un control (el orbe) + de un vistazo lo que importa
/// (estado, duración, velocidades y datos de la sesión). Todo con datos reales
/// del servicio; nada decorativo.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.bridge});

  final VpnBridge bridge;

  Future<void> _onOrbPressed(BuildContext context) async {
    final granted = await bridge.toggle();
    if (!granted &&
        bridge.snapshot.state != VpnState.active &&
        bridge.snapshot.state != VpnState.connecting &&
        context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Permiso de VPN denegado: no se puede conectar'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final orbSize = (constraints.maxWidth * 0.58).clamp(190.0, 260.0);

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight - 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _BrandBar(
                    onAbout: () => _openAbout(context),
                    onSettings: () => _openSettings(context),
                  ),
                  const SizedBox(height: 8),
                  AnimatedBuilder(
                    animation: bridge,
                    builder: (context, _) {
                      final snapshot = bridge.snapshot;
                      final state = snapshot.state;
                      final active = state == VpnState.active;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: 8),
                          Center(
                            child: StatusChip(state: state),
                          ),
                          const SizedBox(height: 28),
                          Center(
                            child: ConnectOrb(
                              state: state,
                              size: orbSize,
                              onPressed: () => _onOrbPressed(context),
                            ),
                          ),
                          const SizedBox(height: 30),
                          Center(
                            child: Text(
                              vpnStatusWord(state),
                              style: tabular(
                                theme.textTheme.headlineLarge!.copyWith(
                                  color: vpnStateColor(state, theme.colorScheme),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Builder(builder: (context) {
                            final phaseLabel = snapshot.rtcPhaseLabel;
                            final subtitle = active
                                ? '${formatDuration(snapshot.stats.uptimeMs)} ·'
                                    ' RTC${snapshot.rtcServerPhone.isEmpty ? '' : ' vía ${snapshot.rtcServerPhone}'}'
                                : (state == VpnState.connecting && phaseLabel.isNotEmpty
                                    ? phaseLabel
                                    : vpnStatusHint(state));
                            return Center(
                              child: Text(
                                subtitle,
                                style: tabular(
                                  theme.textTheme.bodyMedium!.copyWith(color: AppColors.textMuted),
                                ),
                                textAlign: TextAlign.center,
                              ),
                            );
                          }),
                          if (state == VpnState.error && snapshot.lastError.isNotEmpty) ...[
                            const SizedBox(height: 18),
                            _ErrorBanner(message: snapshot.lastError),
                          ],
                          const SizedBox(height: 26),
                          _SpeedPills(snapshot: snapshot),
                          const SizedBox(height: 26),
                          const SectionHeader(label: 'Sesión'),
                          HairlineCard(
                            child: Column(
                              children: [
                                StatRow(
                                  label: 'Datos bajados',
                                  value: formatBytes(snapshot.stats.bytesDown),
                                ),
                                const HairlineDivider(),
                                StatRow(
                                  label: 'Datos subidos',
                                  value: formatBytes(snapshot.stats.bytesUp),
                                ),
                                const HairlineDivider(),
                                StatRow(
                                  label: 'Conexiones TCP',
                                  value: snapshot.stats.tcpSessionsActive > 0
                                      ? '${snapshot.stats.tcpSessionsActive} activas'
                                      : '0',
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openAbout(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (context) => const AboutScreen()),
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (context) => SettingsScreen(bridge: bridge)),
    );
  }
}

/// Marca de la app: wordmark tipográfico + acceso a “Acerca de” y “Ajustes”.
class _BrandBar extends StatelessWidget {
  const _BrandBar({required this.onAbout, required this.onSettings});

  final VoidCallback onAbout;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.35)),
          ),
          child: Icon(Icons.shield_outlined, size: 19, color: theme.colorScheme.primary),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ToDus',
              style: theme.textTheme.titleLarge,
            ),
            Text(
              'Relay VPN',
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
        const Spacer(),
        IconButton(
          tooltip: 'Ajustes avanzados',
          onPressed: onSettings,
          icon: const Icon(Icons.tune),
          color: AppColors.textMuted,
        ),
        IconButton(
          tooltip: 'Acerca de ToDus VPN',
          onPressed: onAbout,
          icon: const Icon(Icons.info_outline),
          color: AppColors.textMuted,
        ),
      ],
    );
  }
}

/// Aviso de error con el último fallo del servicio.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final danger = theme.colorScheme.error;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 20, color: danger),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Revisa la pestaña Registro para más detalles.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Par de píldoras con las velocidades en vivo (bajada / subida).
class _SpeedPills extends StatelessWidget {
  const _SpeedPills({required this.snapshot});

  final VpnSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final active = snapshot.state == VpnState.active;

    return Row(
      children: [
        Expanded(
          child: _SpeedPill(
            icon: Icons.arrow_downward,
            label: 'Bajada',
            value: active ? formatSpeed(snapshot.speedDown) : '—',
            highlight: true,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _SpeedPill(
            icon: Icons.arrow_upward,
            label: 'Subida',
            value: active ? formatSpeed(snapshot.speedUp) : '—',
            highlight: false,
          ),
        ),
      ],
    );
  }
}

class _SpeedPill extends StatelessWidget {
  const _SpeedPill({
    required this.icon,
    required this.label,
    required this.value,
    required this.highlight,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = highlight ? theme.colorScheme.primary : AppColors.textMuted;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label.toUpperCase(),
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: tabular(
                  theme.textTheme.titleMedium!.copyWith(
                    fontFamily: kDisplayFont,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
