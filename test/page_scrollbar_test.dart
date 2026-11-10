import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/screens/page_scrollbar.dart';

void main() {
  testWidgets('dragging the thumb previews a page and only scrolls on release', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = ScrollController();
    addTearDown(controller.dispose);
    final jumps = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          ListView.builder(
            controller: controller,
            itemCount: 20,
            itemBuilder: (_, i) => SizedBox(height: 500, child: Text('page $i')),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 40,
            child: PageScrollbar(
              controller: controller,
              pageCount: 20,
              onJumpToPage: jumps.add,
              previewBuilder: (i) => Text('preview $i'),
            ),
          ),
        ]),
      ),
    ));

    expect(find.byKey(const ValueKey('page-preview')), findsNothing);

    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('page-scrollbar-thumb'))));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    expect(find.byKey(const ValueKey('page-preview')), findsOneWidget);
    expect(find.textContaining('preview '), findsOneWidget);
    expect(controller.offset, 0); // nothing moved yet
    expect(jumps, isEmpty);

    await gesture.up();
    await tester.pump();
    expect(jumps, hasLength(1));
    expect(jumps.single, inInclusiveRange(5, 10));
    expect(find.byKey(const ValueKey('page-preview')), findsNothing);
  });

  testWidgets('a single page needs no scrollbar', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PageScrollbar(
        controller: ScrollController(),
        pageCount: 1,
        onJumpToPage: (_) {},
        previewBuilder: (_) => const SizedBox(),
      ),
    ));
    expect(find.byKey(const ValueKey('page-scrollbar-thumb')), findsNothing);
  });
}
