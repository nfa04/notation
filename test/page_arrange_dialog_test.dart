
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/screens/page_arrange_dialog.dart';

void main() {
  Future<List<int>?> open(WidgetTester tester, {int count = 6, int locked = 0}) async {
    List<int>? result;
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showPageArrangeDialog(context, count: count, locked: locked, thumbnail: (_) async => null);
            done = true;
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    addTearDown(() => done);
    return result;
  }

  testWidgets('a page chosen and sent to the front, then applied', (tester) async {
    await open(tester);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('arrange-apply'))).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('arrange-page-4')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('arrange-to-front')));
    await tester.pump();
    final first = tester.getTopLeft(find.byKey(const ValueKey('arrange-page-4')));
    expect(first.dx, lessThan(tester.getTopLeft(find.byKey(const ValueKey('arrange-page-0'))).dx));
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('arrange-apply'))).onPressed, isNotNull);
  });

  testWidgets('dragging a page onto another puts it there (touch: after a hold)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    List<int>? got;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => got = await showPageArrangeDialog(context, count: 5, thumbnail: (_) async => null),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final drag = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('arrange-page-3'))));
    await tester.pump(const Duration(milliseconds: 300));
    await drag.moveTo(tester.getCenter(find.byKey(const ValueKey('arrange-slot-0'))));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('arrange-apply')));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
    expect(got, [3, 0, 1, 2, 4]);
  });

  testWidgets('a mouse drags at once, without holding', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    List<int>? got;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => got = await showPageArrangeDialog(context, count: 5, thumbnail: (_) async => null),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final drag = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('arrange-page-4'))), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(-30, 0));
    await drag.moveTo(tester.getCenter(find.byKey(const ValueKey('arrange-slot-1'))));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('arrange-apply')));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
    expect(got, [0, 4, 1, 2, 3]);
  });

  testWidgets('pages can be taken out and put back before applying', (tester) async {
    List<int>? got;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => got = await showPageArrangeDialog(context, count: 4, thumbnail: (_) async => null),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('arrange-remove-1')));
    await tester.tap(find.byKey(const ValueKey('arrange-remove-2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('arrange-remove-2'))); // put back
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('arrange-apply')));
    await tester.pumpAndSettle();
    expect(got, [0, 2, 3]);
  });

  testWidgets('the last page left cannot be removed', (tester) async {
    List<int>? got;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => got = await showPageArrangeDialog(context, count: 2, thumbnail: (_) async => null),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('arrange-remove-0')));
    await tester.tap(find.byKey(const ValueKey('arrange-remove-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('arrange-apply')));
    await tester.pumpAndSettle();
    expect(got, [1]);
  });

  testWidgets('a page dropped before the first or after the last goes to the front or the end', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    List<int>? got;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => got = await showPageArrangeDialog(context, count: 5, thumbnail: (_) async => null),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    var drag = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('arrange-page-2'))), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(10, 0));
    await drag.moveTo(tester.getCenter(find.byKey(const ValueKey('arrange-end'))));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    drag = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('arrange-page-3'))), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(10, 0));
    await drag.moveTo(tester.getCenter(find.byKey(const ValueKey('arrange-front'))));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('arrange-apply')));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
    expect(got, [3, 0, 1, 4, 2]);
  });

  testWidgets('the locked first page stays', (tester) async {
    await open(tester, locked: 1);
    await tester.tap(find.byKey(const ValueKey('arrange-page-3')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('arrange-to-front')));
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(const ValueKey('arrange-page-0'))).dx, lessThan(tester.getTopLeft(find.byKey(const ValueKey('arrange-page-3'))).dx));
  });
}
