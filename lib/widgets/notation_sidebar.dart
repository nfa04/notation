import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';

/// One place of the menu.
class SidebarItem {
  /// The index the shell goes by.
  final int id;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const SidebarItem({required this.id, required this.icon, required this.selectedIcon, required this.label});
}

/// The menu of places: flat rows on a quiet ground, grouped by thin lines, the place that is open marked by a pale square,
/// settings at the foot. [wide] shows the labels, otherwise only the icons (with the label as a tooltip). The same rows,
/// taller, make the drawer of a phone ([roomy]).
class NotationSidebar extends StatelessWidget {
  /// The places, in the order they are shown; the groups are cut where [groupBreaks] says (an id that starts a new group).
  final List<SidebarItem> items;
  final int? selected;
  final bool wide;
  final bool roomy;
  final ValueChanged<int> onSelect;

  /// The id that is pinned at the foot, away from the groups.
  final int? pinned;
  final Set<int> groupStarts;

  /// The order the person gave (ids); a place keeps to its group, only the order inside a group follows this. With [onReorder] the rows can be dragged.
  final List<int> order;

  /// Told the new order of all places after a row was dragged to another spot in its group.
  final ValueChanged<List<int>>? onReorder;
  final Widget? header;
  final Widget? footer;

  /// Something for the empty room under the places (wide bar only): it is told how much height is left, and shows what fits.
  final Widget Function(double room)? fill;

  const NotationSidebar({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelect,
    this.wide = true,
    this.roomy = false,
    this.pinned,
    this.groupStarts = const {9, 2, 4},
    this.order = const [],
    this.onReorder,
    this.header,
    this.footer,
    this.fill,
  });

  static Color groundOf(BuildContext context) {
    final t = Theme.of(context);
    return Color.alphaBlend(t.colorScheme.onSurface.withValues(alpha: t.brightness == Brightness.dark ? 0.035 : 0.025), t.colorScheme.surface);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rule = scheme.outlineVariant;
    final grouped = [for (final i in items) if (i.id != pinned) i];
    final foot = [for (final i in items) if (i.id == pinned) i];
    // the groups first (cut where one starts), then each one in the order the person gave
    final groups = <List<SidebarItem>>[];
    for (final i in grouped) {
      if (groups.isEmpty || groupStarts.contains(i.id)) groups.add([]);
      groups.last.add(i);
    }
    int rank(SidebarItem i) {
      final at = order.indexOf(i.id);
      return at < 0 ? order.length : at;
    }
    for (final g in groups) {
      final base = {for (var k = 0; k < g.length; k++) g[k].id: k};
      g.sort((a, b) => rank(a) != rank(b) ? rank(a).compareTo(rank(b)) : base[a.id]!.compareTo(base[b.id]!));
    }
    final children = <Widget>[];
    for (var gi = 0; gi < groups.length; gi++) {
      final g = groups[gi];
      if (gi > 0) children.add(Padding(padding: EdgeInsets.symmetric(vertical: roomy ? 10 : 8, horizontal: wide ? 8 : 4), child: Divider(height: 1, thickness: 1, color: rule)));
      if (onReorder == null) {
        for (final i in g) {
          children.add(_row(context, i));
        }
      } else {
        children.add(ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          buildDefaultDragHandles: false,
          // (no lift shadow: the paper look is flat)
          proxyDecorator: (child, _, _) => Material(type: MaterialType.transparency, child: child),
          onReorderItem: (from, to) {
            if (from == to) return;
            final ids = [for (final i in g) i.id];
            ids.insert(to, ids.removeAt(from));
            onReorder!([
              for (var k = 0; k < groups.length; k++)
                ...(k == gi ? ids : [for (final i in groups[k]) i.id]),
              for (final i in foot) i.id,
            ]);
          },
          children: [
            for (var k = 0; k < g.length; k++)
              // a pointer drags at once; a finger holds the row a moment first (a swipe along the list still scrolls it)
              if (roomy)
                ReorderableDelayedDragStartListener(key: ValueKey('drag-nav-${g[k].id}'), index: k, child: _row(context, g[k]))
              else
                ReorderableDragStartListener(key: ValueKey('drag-nav-${g[k].id}'), index: k, child: _row(context, g[k])),
          ],
        ));
      }
    }
    return Material(
      color: groundOf(context),
      child: SizedBox(
        width: roomy ? null : (wide ? 232 : 60),
        child: SafeArea(
          right: false,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: wide ? 10 : 8, vertical: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (header != null) Padding(padding: const EdgeInsets.only(bottom: 14), child: ConstrainedBox(constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45), child: SingleChildScrollView(child: header))),
              Expanded(
                child: LayoutBuilder(builder: (context, box) {
                  final rows = grouped.length;
                  final used = rows * (roomy ? 46.0 : (wide ? 38.0 : 42.0)) + (children.length - rows) * 17;
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Flexible(child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: children)),
                    if (fill != null && wide && !roomy) fill!(box.maxHeight - used),
                  ]);
                }),
              ),
              ?footer,
              if (foot.isNotEmpty) ...[
                Padding(padding: EdgeInsets.symmetric(vertical: 8, horizontal: wide ? 8 : 4), child: Divider(height: 1, thickness: 1, color: rule)),
                for (final i in foot) _row(context, i),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, SidebarItem i) {
    final scheme = Theme.of(context).colorScheme;
    final on = selected == i.id;
    final label = tr(i.label);
    final height = roomy ? 44.0 : (wide ? 36.0 : 40.0);
    final colour = on ? scheme.onSurface : scheme.onSurfaceVariant;
    final row = Material(
      color: on ? scheme.onSurface.withValues(alpha: 0.07) : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        key: ValueKey('nav-${i.id}'),
        borderRadius: BorderRadius.circular(6),
        onTap: () => onSelect(i.id),
        child: SizedBox(
          height: height,
          child: Row(mainAxisAlignment: wide ? MainAxisAlignment.start : MainAxisAlignment.center, children: [
            if (wide) const SizedBox(width: 10),
            Icon(on ? i.selectedIcon : i.icon, size: 20, color: colour),
            if (wide) ...[
              const SizedBox(width: 12),
              Expanded(child: Text.verbatim(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: on ? FontWeight.w500 : FontWeight.w400, color: colour))),
            ],
          ]),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Semantics(selected: on, button: true, label: label, excludeSemantics: true, onTap: () => onSelect(i.id), child: wide ? row : Tooltip(message: label, child: row)),
    );
  }
}
