import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/screens/margin_ruler.dart';

void main() {
  Future<List<(double, double)>> pump(WidgetTester tester, {double width = 800, double left = 56, double right = 56}) async {
    final changes = <(double, double)>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: StatefulBuilder(
              builder: (context, setState) => MarginRuler(
                pageWidth: 800,
                left: left,
                right: right,
                onChanged: (l, r) => setState(() {
                  left = l;
                  right = r;
                  changes.add((l, r));
                }),
              ),
            ),
          ),
        ),
      ),
    ));
    return changes;
  }

  Future<void> dragBy(WidgetTester tester, String key, double dx) async {
    final g = await tester.startGesture(tester.getCenter(find.byKey(ValueKey(key))));
    for (var i = 0; i < 6; i++) {
      await g.moveBy(Offset(dx / 6, 0));
      await tester.pump();
    }
    await g.up();
  }

  testWidgets('the left handle widens the left margin', (tester) async {
    final changes = await pump(tester);
    await dragBy(tester, 'margin-left', 120);
    expect(changes.last.$1, greaterThan(100));
    expect(changes.last.$2, 56);
  });

  testWidgets('the right handle moves the right margin the other way', (tester) async {
    final changes = await pump(tester);
    await dragBy(tester, 'margin-right', -120);
    expect(changes.last.$2, greaterThan(100));
    expect(changes.last.$1, 56);
  });

  testWidgets('margins cannot cross or leave the page', (tester) async {
    final changes = await pump(tester);
    await dragBy(tester, 'margin-left', 3000);
    final (l, r) = changes.last;
    expect(800 - l - r, greaterThanOrEqualTo(MarginRuler.minText - 0.001));
    await dragBy(tester, 'margin-right', 3000);
    expect(changes.last.$2, lessThanOrEqualTo(800 - changes.last.$1));
    await dragBy(tester, 'margin-left', -3000);
    expect(changes.last.$1, MarginRuler.minMargin);
  });

  testWidgets('a narrower screen scales the drag', (tester) async {
    final changes = await pump(tester, width: 400);
    await dragBy(tester, 'margin-left', 60); // 60 px on screen = 120 page units
    expect(changes.last.$1, greaterThan(100));
  });
}
