import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/screens/flashcard_view.dart';
import 'package:notes/style/motion.dart';

Widget _app(Widget child, {bool noMotion = false}) =>
    MaterialApp(builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: noMotion), child: c!), home: Scaffold(body: child));

void main() {
  testWidgets('Reveal grows to its height, and is gone once it has shrunk', (tester) async {
    var open = false;
    late StateSetter set;
    await tester.pumpWidget(_app(StatefulBuilder(builder: (context, s) {
      set = s;
      return Column(children: [Reveal(open: open, child: const SizedBox(key: ValueKey('inner'), height: 100, width: 100))]);
    })));
    expect(find.byKey(const ValueKey('inner')), findsNothing);
    set(() => open = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final partway = tester.getSize(find.byType(Reveal)).height;
    expect(partway, inExclusiveRange(0, 100));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(Reveal)).height, 100);
    set(() => open = false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inner')), findsNothing);
  });

  testWidgets('Reveal opens at once when motion is off', (tester) async {
    var open = false;
    late StateSetter set;
    await tester.pumpWidget(_app(noMotion: true, StatefulBuilder(builder: (context, s) {
      set = s;
      return Column(children: [Reveal(open: open, child: const SizedBox(height: 100, width: 100))]);
    })));
    set(() => open = true);
    await tester.pump();
    await tester.pump();
    expect(tester.getSize(find.byType(Reveal)).height, 100);
  });

  testWidgets('a flashcard turns over: edge-on in the middle, the other face after', (tester) async {
    var front = true;
    late StateSetter set;
    await tester.pumpWidget(_app(StatefulBuilder(builder: (context, s) {
      set = s;
      return FlipCard(front: front, face: (f) => Text(f ? 'question' : 'answer'));
    })));
    expect(find.text('question'), findsOneWidget);
    set(() => front = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('question'), findsOneWidget); // still the first half of the turn
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('answer'), findsOneWidget);
    expect(find.text('question'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('answer'), findsOneWidget);
  });

  testWidgets('FadeOnChange fades in when it appears', (tester) async {
    await tester.pumpWidget(_app(const FadeOnChange(token: 'a', child: Text('x'))));
    expect(tester.widget<FadeTransition>(find.byType(FadeTransition).last).opacity.value, 0);
    await tester.pumpAndSettle();
    expect(tester.widget<FadeTransition>(find.byType(FadeTransition).last).opacity.value, 1);
  });
}
