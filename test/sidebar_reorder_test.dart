import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/widgets/notation_sidebar.dart';

void main() {
  const items = [
    SidebarItem(id: 0, icon: Icons.home, selectedIcon: Icons.home, label: 'Dashboard'),
    SidebarItem(id: 1, icon: Icons.folder, selectedIcon: Icons.folder, label: 'Folders'),
    SidebarItem(id: 6, icon: Icons.search, selectedIcon: Icons.search, label: 'Search'),
    SidebarItem(id: 2, icon: Icons.event, selectedIcon: Icons.event, label: 'Calendar'),
    SidebarItem(id: 5, icon: Icons.settings, selectedIcon: Icons.settings, label: 'Settings'),
  ];

  Future<void> show(WidgetTester t, {List<int> order = const [], ValueChanged<List<int>>? onReorder}) => t.pumpWidget(MaterialApp(
        home: Scaffold(body: Row(children: [NotationSidebar(items: items, selected: 0, pinned: 5, order: order, onReorder: onReorder, onSelect: (_) {})])),
      ));

  testWidgets('the saved order is followed inside a group, a place keeps its group', (t) async {
    await show(t, order: [6, 0, 1, 2], onReorder: (_) {});
    final y = [for (final id in [6, 0, 1, 2]) t.getTopLeft(find.byKey(ValueKey('nav-$id'))).dy];
    expect(y[0] < y[1] && y[1] < y[2] && y[2] < y[3], isTrue);
  });

  testWidgets('dragging a row reports the new order of all places', (t) async {
    List<int>? got;
    await show(t, onReorder: (o) => got = o);
    final g = await t.startGesture(t.getCenter(find.byKey(const ValueKey('nav-0'))));
    await t.pump();
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(0, 14));
      await t.pump();
    }
    await g.up();
    await t.pumpAndSettle();
    expect(got, isNotNull);
    expect(got!.toSet(), {0, 1, 6, 2, 5});
    expect(got!.indexOf(0) > got!.indexOf(1), isTrue);
  });
}
