import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/style/paper_look.dart';
import 'package:notes/widgets/paper.dart';

void main() {
  testWidgets('the paper widgets build in light and dark and keep their content', (tester) async {
    for (final b in [Brightness.light, Brightness.dark]) {
      var tapped = 0;
      await tester.pumpWidget(MaterialApp(
        theme: paperLook(ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: b))),
        home: Scaffold(
          appBar: const PageHeader(title: 'Title', actions: [Icon(Symbols.add)]),
          body: Column(children: [
            const PaperSection('Group'),
            PaperPanel(child: const Text('inside'), onTap: () => tapped++),
            PaperRow(title: const Text('row'), subtitle: const Text('sub'), onTap: () => tapped++),
          ]),
        ),
      ));
      expect(find.text('Title'), findsOneWidget);
      expect(find.text('Group'), findsOneWidget);
      await tester.tap(find.text('inside'));
      await tester.tap(find.text('row'));
      expect(tapped, 2);
    }
  });
}
