import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show HardwareKeyboard;

import '../l10n/language.dart';
import '../l10n/text.dart';

/// What the strip needs to know about one tab.
class WorkspaceTab {
  /// 'graph' for the graph, else the id of the note.
  final String key;
  final String title;
  final IconData icon;

  /// A note with no title is shown as "Untitled".
  final bool untitled;
  const WorkspaceTab({required this.key, required this.title, required this.icon, this.untitled = false});
}

/// The tab strip of the work area: the notes and the graph that are open, one tab each. The tabs that are on screen are marked (the one
/// that has the keyboard strongest); a click shows a tab in place of the one that has the keyboard, a click with Ctrl or Shift (or "Show
/// beside the others" of the menu, which comes with a right click or a long press) shows it next to the others.
class WorkspaceTabStrip extends StatelessWidget {
  final List<WorkspaceTab> tabs;
  final Set<String> shown;
  final String? focused;

  /// A tab was clicked; [beside] when it is to be shown next to the others (or taken out of them if it is shown already).
  final void Function(String key, {required bool beside}) onSelect;
  final ValueChanged<String> onClose;
  final ValueChanged<String> onShowAlone;
  final ValueChanged<String> onCloseOthers;
  final VoidCallback onNewTab;

  /// Shows all tabs side by side (as far as they fit), or one again.
  final VoidCallback onToggleAll;
  final bool allShown;

  const WorkspaceTabStrip({
    super.key,
    required this.tabs,
    required this.shown,
    required this.focused,
    required this.onSelect,
    required this.onClose,
    required this.onShowAlone,
    required this.onCloseOthers,
    required this.onNewTab,
    required this.onToggleAll,
    required this.allShown,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: SizedBox(
        height: 40,
        child: Row(children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [for (final t in tabs) _tab(context, t)],
            ),
          ),
          IconButton(key: const ValueKey('tab-new'), tooltip: tr('Open a note in a new tab'), visualDensity: VisualDensity.compact, icon: const Icon(Icons.add, size: 20), onPressed: onNewTab),
          if (tabs.length > 1)
            IconButton(
              key: const ValueKey('tab-all'),
              tooltip: allShown ? tr('Show one tab at a time') : tr('Show all tabs side by side'),
              visualDensity: VisualDensity.compact,
              icon: Icon(allShown ? Icons.crop_square : Icons.view_column_outlined, size: 20),
              onPressed: onToggleAll,
            ),
        ]),
      ),
    );
  }

  Widget _tab(BuildContext context, WorkspaceTab t) {
    final scheme = Theme.of(context).colorScheme;
    final on = shown.contains(t.key), hasKeys = focused == t.key;
    final title = t.title.trim().isEmpty ? tr('Untitled') : t.title.trim();
    Future<void> menu(Offset at) async {
      final box = Overlay.of(context).context.findRenderObject() as RenderBox;
      final choice = await showMenu<String>(
        context: context,
        position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & box.size),
        items: [
          PopupMenuItem(value: 'beside', child: Text(on && shown.length > 1 ? 'Take out of the side-by-side view' : 'Show beside the others')),
          if (shown.length > 1 || !on) PopupMenuItem(value: 'alone', child: const Text('Show alone')),
          PopupMenuItem(value: 'close', child: const Text('Close tab')),
          if (tabs.length > 1) PopupMenuItem(value: 'others', child: const Text('Close other tabs')),
        ],
      );
      switch (choice) {
        case 'beside':
          onSelect(t.key, beside: true);
        case 'alone':
          onShowAlone(t.key);
        case 'close':
          onClose(t.key);
        case 'others':
          onCloseOthers(t.key);
      }
    }

    return GestureDetector(
      key: ValueKey('tab-${t.key}'),
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (d) => menu(d.globalPosition),
      onSecondaryTapDown: (d) => menu(d.globalPosition),
      // a middle click closes, as in a browser
      onTertiaryTapUp: (_) => onClose(t.key),
      onTap: () => onSelect(t.key, beside: HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isShiftPressed || HardwareKeyboard.instance.isMetaPressed),
      child: Container(
        constraints: const BoxConstraints(minWidth: 90, maxWidth: 220),
        padding: const EdgeInsets.only(left: 10, right: 2),
        decoration: BoxDecoration(
          color: hasKeys ? scheme.surface : (on ? scheme.surface.withValues(alpha: 0.5) : Colors.transparent),
          border: Border(bottom: BorderSide(width: 2, color: hasKeys ? scheme.primary : (on ? scheme.primary.withValues(alpha: 0.4) : Colors.transparent))),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(t.icon, size: 16, color: hasKeys ? scheme.primary : scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Flexible(child: Text.verbatim(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: hasKeys ? FontWeight.w600 : FontWeight.normal))),
          IconButton(
            key: ValueKey('tab-close-${t.key}'),
            tooltip: tr('Close tab'),
            visualDensity: VisualDensity.compact,
            iconSize: 14,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            icon: const Icon(Icons.close),
            onPressed: () => onClose(t.key),
          ),
        ]),
      ),
    );
  }
}
