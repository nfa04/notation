import 'package:flutter/material.dart' hide Text;

import '../collab/link_stats.dart';
import '../l10n/language.dart';

/// How good a device's link in a live session is, as bars (shown next to a name), with the words in a tooltip. A link through a relay
/// has a small mark: the relay's bandwidth is spent on it. Nothing is shown while nothing is known.
class LinkSignal extends StatelessWidget {
  final LinkBand band;
  final bool relayed;
  final double size;

  const LinkSignal({super.key, required this.band, this.relayed = false, this.size = 18});

  /// The words for [band], as the tooltip says them.
  static String describe(LinkBand band, {bool relayed = false}) {
    final quality = switch (band) {
      LinkBand.good => tr('Good connection'),
      LinkBand.fair => tr('Unstable connection'),
      LinkBand.poor => tr('Poor connection'),
      LinkBand.unknown => tr('Connection not measured yet'),
    };
    return relayed ? tr('{quality}, through a relay', {'quality': quality}) : quality;
  }

  /// The colour for [band]: green, orange, red.
  static Color colorOf(BuildContext context, LinkBand band) => switch (band) {
        LinkBand.good => Colors.green.shade600,
        LinkBand.fair => Colors.orange.shade700,
        LinkBand.poor => Theme.of(context).colorScheme.error,
        LinkBand.unknown => Theme.of(context).disabledColor,
      };

  @override
  Widget build(BuildContext context) {
    if (band == LinkBand.unknown) return const SizedBox.shrink();
    final color = colorOf(context, band);
    return Tooltip(
      message: describe(band, relayed: relayed),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(
          switch (band) {
            LinkBand.good => Icons.signal_cellular_alt,
            LinkBand.fair => Icons.signal_cellular_alt_2_bar,
            _ => Icons.signal_cellular_alt_1_bar,
          },
          key: ValueKey('link-signal-${band.name}'),
          size: size,
          color: color,
        ),
        if (relayed) Icon(Icons.alt_route, key: const ValueKey('link-signal-relayed'), size: size * 0.7, color: color),
      ]),
    );
  }
}

/// A small coloured dot for the corner of a button, shown only when the link is not good (so that a session that works shows nothing).
class LinkDot extends StatelessWidget {
  final LinkBand band;

  const LinkDot({super.key, required this.band});

  @override
  Widget build(BuildContext context) {
    if (band != LinkBand.fair && band != LinkBand.poor) return const SizedBox.shrink();
    return Container(
      key: ValueKey('link-dot-${band.name}'),
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: LinkSignal.colorOf(context, band), shape: BoxShape.circle, border: Border.all(color: Theme.of(context).colorScheme.surface, width: 1.5)),
    );
  }
}
