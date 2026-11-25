import 'package:flutter/material.dart';

import '../core/formatters.dart';
import '../core/vpn_bridge.dart';
import '../widgets/panels.dart';

/// Superficie de monitoreo: todas las métricas reales del servicio,
/// agrupadas por capa (tráfico, TCP, UDP, relay ToDus) para escanear
/// de arriba a abajo sin ruido visual.
class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key, required this.bridge});

  final VpnBridge bridge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Estadísticas', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Text(
                    'Contadores en vivo del servicio. Se reinician en cada conexión.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            sliver: AnimatedBuilder(
              animation: bridge,
              builder: (context, _) {
                final s = bridge.snapshot.stats;
                final active = bridge.snapshot.isActive;
                final danger = theme.colorScheme.error;

                return SliverList.list(
                  children: [
                    const SectionHeader(label: 'Tráfico'),
                    HairlineCard(
                      child: Column(
                        children: [
                          StatRow(
                            label: 'Bajada total',
                            value: formatBytes(s.bytesDown),
                            emphasis: true,
                          ),
                          const HairlineDivider(),
                          StatRow(
                            label: 'Subida total',
                            value: formatBytes(s.bytesUp),
                            emphasis: true,
                          ),
                          const HairlineDivider(),
                          StatRow(
                            label: 'Duración de la sesión',
                            value: formatDuration(s.uptimeMs),
                          ),
                          const HairlineDivider(),
                          StatRow(
                            label: 'Estado',
                            value: active ? 'Túnel activo' : 'Túnel inactivo',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    const SectionHeader(label: 'TCP'),
                    HairlineCard(
                      child: Column(
                        children: [
                          StatRow(label: 'Sesiones activas', value: formatCount(s.tcpSessionsActive)),
                          const HairlineDivider(),
                          StatRow(label: 'Sesiones totales', value: formatCount(s.tcpSessionsTotal)),
                          const HairlineDivider(),
                          StatRow(
                            label: 'Segmentos descartados',
                            value: formatCount(s.tcpSegmentsDropped),
                            valueColor: s.tcpSegmentsDropped > 0 ? danger : null,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    const SectionHeader(label: 'UDP'),
                    HairlineCard(
                      child: Column(
                        children: [
                          StatRow(label: 'Datagramas enviados', value: formatCount(s.udpDatagramsOut)),
                          const HairlineDivider(),
                          StatRow(label: 'Datagramas recibidos', value: formatCount(s.udpDatagramsIn)),
                          const HairlineDivider(),
                          StatRow(
                            label: 'Descartados (> MTU)',
                            value: formatCount(s.udpOversizeDropped),
                            valueColor: s.udpOversizeDropped > 0 ? danger : null,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    const SectionHeader(label: 'Túnel RTC (WebRTC)'),
                    HairlineCard(
                      child: Column(
                        children: [
                          StatRow(label: 'Streams TCP abiertos', value: formatCount(s.rtcStreamsOpened)),
                          const HairlineDivider(),
                          StatRow(label: 'Frames enviados', value: formatCount(s.rtcFramesUp)),
                          const HairlineDivider(),
                          StatRow(label: 'Frames recibidos', value: formatCount(s.rtcFramesDown)),
                          const HairlineDivider(),
                          StatRow(label: 'Consultas DNS por TCP', value: formatCount(s.dnsOverTcpQueries)),
                          const HairlineDivider(),
                          StatRow(label: 'Flujos UDP directos', value: formatCount(s.udpDirectFlows)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    const SectionHeader(label: 'Resiliencia'),
                    HairlineCard(
                      child: Column(
                        children: [
                          StatRow(
                            label: 'Backoffs aplicados',
                            value: formatCount(s.backoffEvents),
                            valueColor: s.backoffEvents > 0 ? danger : null,
                          ),
                          const HairlineDivider(),
                          StatRow(
                            label: 'Circuito abierto (veces)',
                            value: formatCount(s.circuitOpenCount),
                            valueColor: s.circuitOpenCount > 0 ? danger : null,
                          ),
                          const HairlineDivider(),
                          StatRow(
                            label: 'Ses. rechazadas por límite',
                            value: formatCount(s.sessionsRejectedByLimit),
                            valueColor: s.sessionsRejectedByLimit > 0 ? danger : null,
                          ),
                          const HairlineDivider(),
                          StatRow(
                            label: 'Esperas en semáforo HTTP',
                            value: formatCount(s.httpSemaphoreWait),
                          ),
                          const HairlineDivider(),
                          StatRow(
                            label: 'Bloques TCP coalescidos',
                            value: formatCount(s.tcpBatchesSent),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    const SectionHeader(label: 'Otros'),
                    HairlineCard(
                      child: Column(
                        children: [
                          StatRow(
                            label: 'Protocolos no TCP/UDP descartados',
                            value: formatCount(s.otherProtoDropped),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
