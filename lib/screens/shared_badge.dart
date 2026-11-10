import 'package:flutter/material.dart' hide Text;

import '../collab/shared_notes.dart';
import '../l10n/language.dart';

/// The group symbol on a note that is shared (with others, or with the person), with a word about which on hover.
/// Nothing for a note that is not shared.
class SharedBadge extends StatelessWidget {
  final SharedKind kind;
  final String? from;
  final double size;
  final Color? color;

  const SharedBadge({super.key, required this.kind, this.from, this.size = 16, this.color});

  /// The words for the tooltip.
  String get message => switch (kind) {
        SharedKind.byMe => tr('Shared with others'),
        SharedKind.withMe => from == null ? tr('Shared with you') : tr('Shared with you by {who}', {'who': from}),
        SharedKind.both => tr('Shared with you, and by you with others'),
        SharedKind.none => '',
      };

  @override
  Widget build(BuildContext context) {
    if (!kind.isShared) return const SizedBox.shrink();
    return Tooltip(message: message, child: Icon(Icons.group, size: size, color: color ?? Theme.of(context).colorScheme.primary));
  }
}
