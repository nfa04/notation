import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/widgets/overflow_strip.dart';

void main() {
  Widget strip(int n, {double width = 300}) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: width, height: 44, child: OverflowStrip(children: [for (var i = 0; i < n; i++) SizedBox(width: 48, child: Center(child: Text('b$i')))])),
          ),
        ),
      );

  testWidgets('buttons that fit have no arrows', (tester) async {
    await tester.pumpWidget(strip(4));
    await tester.pump();
    expect(find.byKey(const ValueKey('strip-more')), findsNothing);
    expect(find.byKey(const ValueKey('strip-less')), findsNothing);
  });

  testWidgets('hidden buttons show an arrow on the side they are on, which brings them in', (tester) async {
    await tester.pumpWidget(strip(20));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('strip-more')), findsOneWidget, reason: 'more to the right');
    expect(find.byKey(const ValueKey('strip-less')), findsNothing, reason: 'nothing to the left yet');
    await tester.tap(find.byKey(const ValueKey('strip-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('strip-less')), findsOneWidget, reason: 'now some are to the left');
    // all the way to the end: nothing more to the right
    for (var i = 0; i < 6; i++) {
      if (find.byKey(const ValueKey('strip-more')).evaluate().isEmpty) break;
      await tester.tap(find.byKey(const ValueKey('strip-more')));
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const ValueKey('strip-more')), findsNothing);
    expect(find.byKey(const ValueKey('strip-less')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('strip-less')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('strip-more')), findsOneWidget, reason: 'and going back shows more to the right again');
  });
}
