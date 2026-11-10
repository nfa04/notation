import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/style/platform_look.dart';

ThemeData base() => ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFEC6FA3)));

/// Builds [probe] under a theme and hands what it saw back.
Future<T> seen<T>(WidgetTester tester, ThemeData theme, T Function(BuildContext) probe) async {
  late T result;
  await tester.pumpWidget(MaterialApp(theme: theme, home: Builder(builder: (context) {
    result = probe(context);
    return const SizedBox();
  })));
  return result;
}

void main() {
  group('the icons of a toolbar in the iOS look', () {
    testWidgets('are the accent, faded when off, on a rounded square rather than a disc', (tester) async {
      final theme = iosLook(base());
      await tester.pumpWidget(MaterialApp(theme: theme, home: Scaffold(body: Row(children: [
        IconButton(key: const ValueKey('on'), icon: const Icon(Icons.edit), onPressed: () {}),
        const IconButton(key: ValueKey('off'), icon: Icon(Icons.edit), onPressed: null),
      ]))));
      Color? colourOf(String key) => IconTheme.of(tester.element(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Icon)))).color;
      expect(colourOf('on'), theme.colorScheme.primary);
      expect(colourOf('off')!.a, lessThan(0.5));
      final material = tester.widget<Material>(find.descendant(of: find.byKey(const ValueKey('on')), matching: find.byType(Material)).first);
      expect(material.shape, isA<RoundedRectangleBorder>());
    });

    testWidgets('keep their own colour when they are given one', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: iosLook(base()), home: Scaffold(body: IconButton(key: const ValueKey('x'), color: Colors.amber, icon: const Icon(Icons.star), onPressed: () {}))));
      expect(IconTheme.of(tester.element(find.descendant(of: find.byKey(const ValueKey('x')), matching: find.byType(Icon)))).color, Colors.amber);
    });

    testWidgets('a raised button is the tinted one, without a shadow', (tester) async {
      final theme = iosLook(base());
      await tester.pumpWidget(MaterialApp(theme: theme, home: Scaffold(body: ElevatedButton(key: const ValueKey('b'), onPressed: () {}, child: const Text('Import')))));
      final material = tester.widget<Material>(find.descendant(of: find.byKey(const ValueKey('b')), matching: find.byType(Material)).first);
      expect(material.elevation, 0);
      expect(material.color!.a, closeTo(0.12, 0.01));
      expect(tester.getSize(find.byKey(const ValueKey('b'))).height, greaterThanOrEqualTo(44));
    });
  });

  group('the bars of tools', () {
    testWidgets('in the Material look keep their tint and their shadow, and have no line', (tester) async {
      final theme = base();
      expect(await seen(tester, theme, toolBarColor), theme.colorScheme.surfaceContainerLow);
      expect(await seen(tester, theme, (c) => toolBarElevation(c, 3)), 3);
      expect(await seen(tester, theme, (c) => toolBarEdge(c, top: true)), isNull);
      expect(await seen(tester, theme, toggleToolStyle), isNull);
    });

    testWidgets('in the iOS look are the grey of the bars, flat, with a hairline on the side that faces the page', (tester) async {
      final theme = iosLook(base());
      expect(await seen(tester, theme, toolBarColor), theme.appBarTheme.backgroundColor);
      expect(await seen(tester, theme, (c) => toolBarElevation(c, 3)), 0);
      final top = (await seen(tester, theme, (c) => toolBarEdge(c, top: true)))!;
      expect((top.top.width, top.left.width, top.bottom.width), (0.5, 0.0, 0.0));
      final left = (await seen(tester, theme, (c) => toolBarEdge(c, left: true)))!;
      expect((left.top.width, left.left.width), (0.0, 0.5));
    });

    testWidgets('a tool that is on has a pale accent square, one that is off has nothing', (tester) async {
      final theme = iosLook(base());
      final style = (await seen(tester, theme, toggleToolStyle))!;
      expect(style.backgroundColor!.resolve({WidgetState.selected})!.a, closeTo(0.14, 0.01));
      expect(style.backgroundColor!.resolve({WidgetState.selected}), theme.colorScheme.primary.withValues(alpha: 0.14));
      expect(style.backgroundColor!.resolve(<WidgetState>{}), Colors.transparent);
    });

    testWidgets('dark: the bar is the dark chrome', (tester) async {
      final dark = iosLook(ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFEC6FA3), brightness: Brightness.dark)));
      expect(await seen(tester, dark, toolBarColor), const Color(0xFF1C1C1E));
    });
  });
}
