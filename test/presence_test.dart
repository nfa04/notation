import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/screens/page_scrollbar.dart';
import 'package:notes/screens/presence.dart';

void main() {
  test('a person has the same colour everywhere, and different people mostly differ', () {
    expect(presenceColor('abc'), presenceColor('abc'));
    expect({for (final s in ['a1', 'b2', 'c3', 'd4', 'e5']) presenceColor(s).toARGB32()}.length, greaterThan(2));
  });

  testWidgets('a page that others have in view gets a border and their names', (tester) async {
    const ben = Participant('s1', 'Ben');
    const cy = Participant('s2', 'Cy');
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: PresenceFrame(frames: [(viewers: [ben, cy], top: 0, height: null)], everyone: [ben, cy], child: SizedBox(width: 200, height: 300)),
      ),
    ));
    expect(find.byKey(const ValueKey('presence-frame')), findsOneWidget);
    expect(find.text('Ben'), findsOneWidget);
    expect(find.text('Cy'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PresenceFrame(frames: [], everyone: [ben, cy], child: SizedBox(width: 200, height: 300))),
    ));
    expect(find.byKey(const ValueKey('presence-frame')), findsNothing);
  });

  testWidgets('on a page shown as several sheets only the sheet the person is on is framed', (tester) async {
    const ben = Participant('s1', 'Ben');
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: PresenceFrame(frames: [(viewers: [ben], top: 324, height: 300)], everyone: [ben], child: SizedBox(width: 200, height: 948)),
        ),
      ),
    ));
    final frame = tester.getRect(find.byKey(const ValueKey('presence-frame')));
    expect(frame.top, 324);
    expect(frame.height, 300);
    expect(tester.getTopLeft(find.text('Ben')).dy, greaterThanOrEqualTo(324));
  });

  testWidgets('the page scrollbar shows who is where', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(children: [
          Expanded(child: ListView(controller: scroll, children: [for (var i = 0; i < 10; i++) SizedBox(height: 400, child: Text('page $i'))])),
          SizedBox(
            width: 40,
            child: PageScrollbar(
              controller: scroll,
              pageCount: 10,
              onJumpToPage: (_) {},
              previewBuilder: (_) => const SizedBox(),
              markers: const [(page: 7, color: Colors.red, label: 'Ben'), (page: 7, color: Colors.blue, label: 'Cy')],
            ),
          ),
        ]),
      ),
    ));
    expect(find.byKey(const ValueKey('presence-marker-Ben')), findsOneWidget);
    expect(find.byKey(const ValueKey('presence-marker-Cy')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('presence-marker-Cy'))).dx, lessThan(tester.getTopLeft(find.byKey(const ValueKey('presence-marker-Ben'))).dx)); // side by side
  });

  testWidgets('one person on two devices (same label twice) does not break the scrollbar', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(children: [
          Expanded(child: ListView(controller: scroll, children: [for (var i = 0; i < 10; i++) SizedBox(height: 400, child: Text('page $i'))])),
          SizedBox(
            width: 40,
            child: PageScrollbar(
              controller: scroll,
              pageCount: 10,
              onJumpToPage: (_) {},
              previewBuilder: (_) => const SizedBox(),
              markers: const [
                (page: 2, color: Colors.red, label: 'Noel (#cca1)'),
                (page: 5, color: Colors.blue, label: 'Noel (#cca1)'),
              ],
            ),
          ),
        ]),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(Tooltip), findsNWidgets(2));
  });
}
