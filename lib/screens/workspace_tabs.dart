import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
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

  /// The tabs were put in a new order (all the keys, in that order).
  final ValueChanged<List<String>> onReorder;

  /// Shows all tabs side by side (as far as they fit), or one again.
  final VoidCallback onToggleAll;
  final bool allShown;

  /// A button at the left end (the one that brings the menu back).
  final Widget? leading;

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
    required this.onReorder,
    required this.onToggleAll,
    required this.allShown,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Container(
        height: 40,
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.outlineVariant))),
        child: Row(children: [
          ?leading,
          Expanded(
            child: ReorderableListView(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              // (no lift shadow: the paper look is flat)
              proxyDecorator: (child, _, _) => Material(type: MaterialType.transparency, child: child),
              onReorderItem: (from, to) {
                if (from == to) return;
                final keys = [for (final t in tabs) t.key];
                keys.insert(to, keys.removeAt(from));
                onReorder(keys);
              },
              children: [
                for (var i = 0; i < tabs.length; i++)
                  // a pointer drags at once; a finger holds the tab a moment first (a swipe along the strip still scrolls it)
                  if (_touch)
                    ReorderableDelayedDragStartListener(key: ValueKey('drag-${tabs[i].key}'), index: i, child: _tab(context, tabs[i], i))
                  else
                    ReorderableDragStartListener(key: ValueKey('drag-${tabs[i].key}'), index: i, child: _tab(context, tabs[i], i)),
              ],
            ),
          ),
          IconButton(key: const ValueKey('tab-new'), tooltip: tr('Open a note in a new tab'), visualDensity: VisualDensity.compact, icon: const Icon(Symbols.add, size: 20), onPressed: onNewTab),
          if (tabs.length > 1)
            IconButton(
              key: const ValueKey('tab-all'),
              tooltip: allShown ? tr('Show one tab at a time') : tr('Show all tabs side by side'),
              visualDensity: VisualDensity.compact,
              icon: Icon(allShown ? Symbols.crop_square : Symbols.view_column, size: 20),
              onPressed: onToggleAll,
            ),
        ]),
      ),
    );
  }

  Widget _tab(BuildContext context, WorkspaceTab t, int index) {
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
          if (index > 0) PopupMenuItem(value: 'left', child: const Text('Move left')),
          if (index < tabs.length - 1) PopupMenuItem(value: 'right', child: const Text('Move right')),
          PopupMenuItem(value: 'close', child: const Text('Close tab')),
          if (tabs.length > 1) PopupMenuItem(value: 'others', child: const Text('Close other tabs')),
        ],
      );
      void move(int by) {
        final keys = [for (final x in tabs) x.key];
        keys.insert(index + by, keys.removeAt(index));
        onReorder(keys);
      }

      switch (choice) {
        case 'left':
          move(-1);
        case 'right':
          move(1);
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
      // (a long press is the drag on a touch screen: there the menu comes with a tap on the tab that has the keyboard)
      onLongPressStart: _touch ? null : (d) => menu(d.globalPosition),
      onSecondaryTapDown: (d) => menu(d.globalPosition),
      onTapDown: (d) => _tapAt = d.globalPosition,
      // a middle click closes, as in a browser
      onTertiaryTapUp: (_) => onClose(t.key),
      onTap: () => _touch && hasKeys ? menu(_tapAt ?? Offset.zero) : onSelect(t.key, beside: HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isShiftPressed || HardwareKeyboard.instance.isMetaPressed),
      child: _Hover(builder: (hovered) => Container(
        constraints: const BoxConstraints(minWidth: 90, maxWidth: 220),
        padding: const EdgeInsets.only(left: 10, right: 2),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(width: 1.5, color: hasKeys ? scheme.onSurface : (on ? scheme.onSurface.withValues(alpha: 0.35) : Colors.transparent))),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(t.icon, size: 16, color: hasKeys ? scheme.onSurface : scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Flexible(child: Text.verbatim(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: hasKeys ? FontWeight.w500 : FontWeight.normal, color: hasKeys ? scheme.onSurface : scheme.onSurfaceVariant))),
          // the close mark shows on the tabs that are open on screen and under the pointer; elsewhere it is a gap (a middle click or the menu close it)
          if (!(on || hovered || _touch)) const SizedBox(width: 14) else IconButton(
            key: ValueKey('tab-close-${t.key}'),
            tooltip: tr('Close tab'),
            visualDensity: VisualDensity.compact,
            iconSize: 14,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            icon: const Icon(Symbols.close),
            onPressed: () => onClose(t.key),
          ),
        ]),
      )),
    );
  }
}


Offset? _tapAt; // where the last tap on a tab went down (the menu opens there)

bool get _touch => const {TargetPlatform.android, TargetPlatform.iOS}.contains(defaultTargetPlatform);

/// Tells its builder whether the pointer is over it.
class _Hover extends StatefulWidget {
  final Widget Function(bool hovered) builder;
  const _Hover({required this.builder});

  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
  bool _in = false;

  @override
  Widget build(BuildContext context) => MouseRegion(onEnter: (_) => setState(() => _in = true), onExit: (_) => setState(() => _in = false), child: widget.builder(_in));
}
