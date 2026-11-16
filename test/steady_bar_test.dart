import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/style/tool_columns.dart';

void main() {
  testWidgets('a bar at the side keeps its shape when the keyboard comes', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => tester.view.resetViewInsets());
    final bar = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(children: [
          const Expanded(child: SizedBox()),
          SteadyBar(child: ToolColumns(key: bar, children: [for (var i = 0; i < 24; i++) const SizedBox(width: 48, height: 48)])),
        ]),
      ),
    ));
    final before = tester.getSize(find.byKey(bar));
    tester.view.viewInsets = const FakeViewPadding(bottom: 500);
    await tester.pump();
    expect(tester.getSize(find.byKey(bar)), before, reason: 'laid out in half the height it would have gone to more columns');
  });
}
