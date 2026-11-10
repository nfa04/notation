import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/style/platform_dialog.dart';
import 'package:notes/style/platform_look.dart';

ThemeData base({Brightness brightness = Brightness.light}) =>
    ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFEC6FA3), brightness: brightness));

/// A page with a button that opens [dialog]; what the dialog answers is kept in [answer].
Widget app(ThemeData theme, Widget dialog, {List<Object?>? answers}) => MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open'),
              onPressed: () async {
                final answer = await showDialog<Object?>(context: context, builder: (_) => dialog);
                answers?.add(answer);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

Future<void> open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
}

void main() {
  group('the Material look', () {
    testWidgets('is the AlertDialog it was', (tester) async {
      await tester.pumpWidget(app(base(), const PlatformAlertDialog(title: Text('Delete?'), content: Text('It is gone.'), actions: [Text('No'), Text('Yes')])));
      await open(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Delete?'), findsOneWidget);
      expect(isIosLook(tester.element(find.byType(AlertDialog))), isFalse);
    });
  });

  group('the iOS look', () {
    ThemeData ios([Brightness b = Brightness.light]) => iosLook(base(brightness: b));

    testWidgets('is an alert of its own, not the Material one', (tester) async {
      await tester.pumpWidget(app(ios(), const PlatformAlertDialog(title: Text('Delete?'), content: Text('It is gone.'), actions: [Text('No'), Text('Yes')])));
      await open(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(Dialog), findsOneWidget);
      expect(isIosLook(tester.element(find.byType(Dialog))), isTrue);
    });

    testWidgets('title and message stand in the middle of the alert', (tester) async {
      await tester.pumpWidget(app(ios(), const PlatformAlertDialog(title: Text('Delete?'), content: Text('It is gone.'), actions: [Text('No')])));
      await open(tester);
      final dialog = tester.getRect(find.byType(Dialog));
      expect(tester.getCenter(find.text('Delete?')).dx, closeTo(dialog.center.dx, 1));
      expect(tester.getCenter(find.text('It is gone.')).dx, closeTo(dialog.center.dx, 1));
      expect(dialog.width, greaterThanOrEqualTo(270));
    });

    testWidgets('two buttons stand side by side, with a line between them', (tester) async {
      await tester.pumpWidget(app(ios(), PlatformAlertDialog(title: const Text('Sure?'), actions: [
        TextButton(onPressed: () {}, child: const Text('No')),
        TextButton(onPressed: () {}, child: const Text('Yes')),
      ])));
      await open(tester);
      final no = tester.getRect(find.widgetWithText(TextButton, 'No')), yes = tester.getRect(find.widgetWithText(TextButton, 'Yes'));
      expect(no.top, yes.top);
      expect(no.right, lessThanOrEqualTo(yes.left));
      expect(no.width, closeTo(yes.width, 1));
      expect(find.byType(VerticalDivider), findsOneWidget);
      expect(no.height, greaterThanOrEqualTo(44));
    });

    testWidgets('three buttons stand one under the other', (tester) async {
      await tester.pumpWidget(app(ios(), PlatformAlertDialog(title: const Text('Which?'), actions: [
        TextButton(onPressed: () {}, child: const Text('A')),
        TextButton(onPressed: () {}, child: const Text('B')),
        TextButton(onPressed: () {}, child: const Text('C')),
      ])));
      await open(tester);
      final a = tester.getRect(find.widgetWithText(TextButton, 'A')), b = tester.getRect(find.widgetWithText(TextButton, 'B')), c = tester.getRect(find.widgetWithText(TextButton, 'C'));
      expect(a.bottom, lessThanOrEqualTo(b.top));
      expect(b.bottom, lessThanOrEqualTo(c.top));
      expect(a.width, closeTo(c.width, 1));
      expect(find.byType(VerticalDivider), findsNothing);
    });

    testWidgets('a button answers, and a filled button in an alert is a plain one', (tester) async {
      final answers = <Object?>[];
      await tester.pumpWidget(app(
        ios(),
        Builder(
          builder: (context) => PlatformAlertDialog(title: const Text('Sure?'), actions: [
            TextButton(onPressed: () => Navigator.pop(context, 'no'), child: const Text('No')),
            FilledButton(key: const ValueKey('yes'), onPressed: () => Navigator.pop(context, 'yes'), child: const Text('Yes')),
          ]),
        ),
        answers: answers,
      ));
      await open(tester);
      final filled = tester.widget<FilledButton>(find.byKey(const ValueKey('yes')));
      expect(filled.onPressed, isNotNull);
      final material = tester.widget<Material>(find.descendant(of: find.byKey(const ValueKey('yes')), matching: find.byType(Material)).first);
      expect(material.color, anyOf(isNull, Colors.transparent), reason: 'no coloured block in an alert');
      await tester.tap(find.byKey(const ValueKey('yes')));
      await tester.pumpAndSettle();
      expect(answers, ['yes']);
    });

    testWidgets('a form with a text field, a list tile and a switch needs no more than it did', (tester) async {
      final answers = <Object?>[];
      await tester.pumpWidget(app(
        ios(),
        Builder(
          builder: (context) => PlatformAlertDialog(
            title: const Text('Name it'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              const TextField(key: ValueKey('name'), decoration: InputDecoration(labelText: 'Name', border: OutlineInputBorder())),
              const ListTile(title: Text('Row')),
              SwitchListTile.adaptive(value: true, onChanged: (_) {}, title: const Text('On')),
            ]),
            actions: [TextButton(onPressed: () => Navigator.pop(context, 'ok'), child: const Text('Save'))],
          ),
        ),
        answers: answers,
      ));
      await open(tester);
      await tester.enterText(find.byKey(const ValueKey('name')), 'hello');
      expect(tester.takeException(), isNull);
      expect(find.text('hello'), findsOneWidget);
      // (a form is not centred)
      final dialog = tester.getRect(find.byType(Dialog));
      expect(tester.getRect(find.text('Row')).left, lessThan(dialog.center.dx));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(answers, ['ok']);
    });

    testWidgets('a tall message scrolls inside the alert and the buttons stay in view', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(ios(), PlatformAlertDialog(
        title: const Text('Long'),
        scrollable: true,
        content: Column(mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < 60; i++) Text('line $i')]),
        actions: [TextButton(onPressed: () {}, child: const Text('Close'))],
      )));
      await open(tester);
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.text('Close')).bottom, lessThanOrEqualTo(600));
      expect(tester.getRect(find.byType(Dialog)).height, lessThanOrEqualTo(600));
    });

    testWidgets('a list that scrolls itself fits in the alert', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(ios(), PlatformAlertDialog(
        title: const Text('Pick'),
        content: SizedBox(width: 300, child: ListView(shrinkWrap: true, children: [for (var i = 0; i < 60; i++) ListTile(title: Text('item $i'))])),
        actions: [TextButton(onPressed: () {}, child: const Text('Cancel'))],
      )));
      await open(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('item 0'), findsOneWidget);
      expect(tester.getRect(find.text('Cancel')).bottom, lessThanOrEqualTo(600));
    });

    testWidgets('no title, no buttons, an icon: still an alert', (tester) async {
      await tester.pumpWidget(app(ios(), const PlatformAlertDialog(icon: Icon(Icons.check), content: Text('Done'))));
      await open(tester);
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('in the dark too', (tester) async {
      await tester.pumpWidget(app(ios(Brightness.dark), PlatformAlertDialog(title: const Text('Dark'), actions: [TextButton(onPressed: () {}, child: const Text('OK'))])));
      await open(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Dark'), findsOneWidget);
    });
  });

  group('the rest of the iOS look', () {
    test('a text field is a grey rounded field with no line, whatever border the field asks for', () {
      final t = iosLook(base()).inputDecorationTheme;
      expect(t.filled, isTrue);
      for (final b in [t.border, t.enabledBorder, t.focusedBorder, t.disabledBorder]) {
        expect(b, isA<OutlineInputBorder>());
        expect(b!.borderSide, BorderSide.none);
      }
      expect(t.errorBorder!.borderSide.width, 1);
      expect(t.errorBorder!.borderSide.color, iosLook(base()).colorScheme.error);
    });

    test('the Material look has the theme it had', () {
      final t = base();
      expect(t.extension<IosLookMarker>(), isNull);
      expect(t.inputDecorationTheme.filled, isNot(true));
    });

    test('the mark is only in the iOS look, and switching the look keeps other extensions', () {
      final withOther = base().copyWith(extensions: [const IosLookMarker()]);
      expect(iosLook(withOther).extensions.length, 1);
      expect(ThemeData.lerp(base(), iosLook(base()), 0.5).extensions, isNotNull);
    });

    test('a note at the bottom is dark grey with rounded corners; a chip is a grey capsule without a line', () {
      final t = iosLook(base());
      expect(t.snackBarTheme.backgroundColor, const Color(0xFF3A3A3C));
      expect(t.snackBarTheme.shape, isA<RoundedRectangleBorder>());
      expect(t.chipTheme.shape, isA<StadiumBorder>());
      expect(t.chipTheme.side, BorderSide.none);
      expect(t.chipTheme.elevation, 0);
    });

    testWidgets('a field in the iOS look builds and shows its label and text', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: iosLook(base()),
        home: const Scaffold(body: Padding(padding: EdgeInsets.all(20), child: TextField(decoration: InputDecoration(labelText: 'Title', border: OutlineInputBorder(), isDense: true)))),
      ));
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('abc'), findsOneWidget);
      expect(find.text('Title'), findsOneWidget);
    });

    testWidgets('a field that asks for no fill stays clear (the text boxes of a page)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: iosLook(base()),
        home: const Scaffold(body: TextField(decoration: InputDecoration(filled: false, border: InputBorder.none))),
      ));
      final decorator = tester.widget<InputDecorator>(find.byType(InputDecorator));
      expect(decorator.decoration.filled, isFalse);
    });

    testWidgets('choices are the iOS radio in the iOS look, the Material one otherwise', (tester) async {
      Widget page(ThemeData theme) => MaterialApp(
            theme: theme,
            home: Scaffold(
              body: RadioGroup<int>(
                groupValue: 1,
                onChanged: (_) {},
                child: const Column(children: [RadioListTile<int>.adaptive(value: 1, title: Text('One')), RadioListTile<int>.adaptive(value: 2, title: Text('Two'))]),
              ),
            ),
          );
      await tester.pumpWidget(page(iosLook(base())));
      expect(find.byType(CupertinoRadio<int>), findsNWidgets(2));
      await tester.pumpWidget(page(base().copyWith(platform: TargetPlatform.android)));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoRadio<int>), findsNothing);
    });

    testWidgets('a note at the bottom in the iOS look is shown', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: iosLook(base()),
        home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved'))), child: const Text('go')))),
      ));
      await tester.tap(find.text('go'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Saved'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
