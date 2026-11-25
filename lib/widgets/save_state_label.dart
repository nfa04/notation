import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/language.dart';
import '../l10n/text.dart';

/// Where the note stands with saving: written, waiting to be written (a change a moment ago), or a save that failed.
enum NoteSaveState { saved, saving, failed }

/// A quiet word beside the title of a note that says whether what is on screen is saved: "Saving…" while a change waits
/// to be written, "Saved" once it is, "Not saved" when writing failed. Only this widget is built again when the state
/// changes, never the editor around it. [compact]: an icon with the word as its tooltip (a phone's title row).
class SaveStateLabel extends StatelessWidget {
  final ValueListenable<NoteSaveState> state;
  final bool compact;

  const SaveStateLabel({super.key, required this.state, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<NoteSaveState>(
      valueListenable: state,
      builder: (context, s, _) {
        final (word, icon, color) = switch (s) {
          NoteSaveState.saved => (tr('Saved'), Symbols.cloud_done, scheme.onSurfaceVariant),
          NoteSaveState.saving => (tr('Saving...'), Symbols.sync, scheme.onSurfaceVariant),
          NoteSaveState.failed => (tr('Not saved'), Symbols.error, scheme.error),
        };
        return Semantics(
          key: const ValueKey('save-state'),
          liveRegion: s == NoteSaveState.failed,
          label: word,
          excludeSemantics: true,
          child: Tooltip(
            message: word,
            child: compact
                ? Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Icon(icon, size: 16, color: color))
                : Text.verbatim(word, maxLines: 1, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
          ),
        );
      },
    );
  }
}
