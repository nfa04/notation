import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/shortcut_settings.dart';
import 'package:notes/shortcuts/key_combo.dart';
import 'package:notes/shortcuts/shortcut_action.dart';
import 'package:notes/shortcuts/shortcut_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const ctrl = LogicalKeyboardKey.controlLeft;
const shift = LogicalKeyboardKey.shiftLeft;
const alt = LogicalKeyboardKey.altLeft;

/// Presses [key] with [held] down, and lets go again.
Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {List<LogicalKeyboardKey> held = const []}) async {
  for (final h in held) {
    await tester.sendKeyDownEvent(h);
  }
  await tester.sendKeyEvent(key);
  for (final h in held.reversed) {
    await tester.sendKeyUpEvent(h);
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  group('KeyCombo', () {
    test('is written out and read back, whatever the case of the letter', () {
      final combo = KeyCombo(LogicalKeyboardKey.keyZ, ctrl: true, shift: true);
      expect(combo.encode(), 'ctrl+shift+${LogicalKeyboardKey.keyZ.keyId}');
      expect(KeyCombo.decode(combo.encode()), combo);
      expect(KeyCombo.decode('ctrl+${0x5a}'), KeyCombo(LogicalKeyboardKey.keyZ, ctrl: true)); // "Z" is the key z
    });

    test('anything unreadable, or a modifier on its own, is no combination', () {
      expect(KeyCombo.decode('ctrl+x'), isNull);
      expect(KeyCombo.decode('hyper+97'), isNull);
      expect(KeyCombo.decode(''), isNull);
      expect(KeyCombo.decode('ctrl+${LogicalKeyboardKey.shiftLeft.keyId}'), isNull);
    });

    test('reads the way people say it', () {
      expect(KeyCombo(LogicalKeyboardKey.keyZ, ctrl: true, shift: true).label(TargetPlatform.linux), 'Ctrl+Shift+Z');
      expect(KeyCombo(LogicalKeyboardKey.keyZ, meta: true, alt: true).label(TargetPlatform.macOS), 'Option+Cmd+Z');
      expect(KeyCombo(LogicalKeyboardKey.f5).label(TargetPlatform.linux), 'F5');
      expect(KeyCombo(LogicalKeyboardKey.space, ctrl: true).label(TargetPlatform.linux), 'Ctrl+Space');
      expect(KeyCombo(LogicalKeyboardKey.pageDown, ctrl: true).label(TargetPlatform.linux), 'Ctrl+Page Down');
    });

    test('only keys with Ctrl, Alt or Cmd, and the function keys, work while a text is typed', () {
      expect(KeyCombo(LogicalKeyboardKey.keyP).worksInText, isFalse);
      expect(KeyCombo(LogicalKeyboardKey.keyP, shift: true).worksInText, isFalse);
      expect(KeyCombo(LogicalKeyboardKey.keyP, ctrl: true).worksInText, isTrue);
      expect(KeyCombo(LogicalKeyboardKey.f5).worksInText, isTrue);
    });
  });

  group('the defaults', () {
    for (final mac in [false, true]) {
      test('${mac ? 'on a Mac' : 'elsewhere'}: no two actions share a key, and every action is known to the app', () {
        final actions = shortcutActions(mac: mac);
        expect({for (final a in actions) a.id}.length, actions.length);
        final seen = <KeyCombo, String>{};
        for (final a in actions) {
          for (final c in a.defaults) {
            expect(seen[c], isNull, reason: '${c.label()} is for both ${seen[c]} and ${a.id}');
            seen[c] = a.id;
            expect(KeyCombo.isModifierKey(c.key), isFalse, reason: a.id);
          }
        }
        expect(actions.map((a) => a.id), containsAll(navigationActions.keys));
        // the usual ones are there
        final undo = actions.firstWhere((a) => a.id == 'edit.undo').defaults.single;
        expect(undo, mac ? KeyCombo(LogicalKeyboardKey.keyZ, meta: true) : KeyCombo(LogicalKeyboardKey.keyZ, ctrl: true));
      });
    }
  });

  group('ShortcutService', () {
    test('has the defaults until something is changed, and a change is remembered', () async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      final settings = SettingsRepository(db);
      final service = ShortcutService(settings, mac: false);
      await service.load();
      final x = KeyCombo(LogicalKeyboardKey.keyX, ctrl: true, shift: true);
      expect(service.bindingsOf('tool.plot'), isEmpty);
      expect(service.bindingsOf('tool.pen'), [KeyCombo(LogicalKeyboardKey.keyP)]);
      expect(service.anyChanged, isFalse);

      await service.addBinding('tool.plot', x);
      await service.setBindings('tool.pen', []); // taken away altogether
      expect(service.bindingsOf('tool.plot'), [x]);
      expect(service.bindingsOf('tool.pen'), isEmpty);
      expect(service.changed('tool.pen'), isTrue);

      final again = ShortcutService(settings, mac: false);
      await again.load();
      expect(again.bindingsOf('tool.plot'), [x]);
      expect(again.bindingsOf('tool.pen'), isEmpty);
      expect(again.bindingsOf('tool.eraser'), [KeyCombo(LogicalKeyboardKey.keyE)]); // what was never touched is as it came

      await again.reset('tool.pen');
      expect(again.bindingsOf('tool.pen'), [KeyCombo(LogicalKeyboardKey.keyP)]);
      await again.resetAll();
      expect(again.anyChanged, isFalse);
      expect(await settings.get('keyboard_shortcuts'), isNull);
    });

    test('a key goes to one action: giving it to another takes it from the first', () async {
      final service = ShortcutService.inMemory(mac: false);
      final undo = KeyCombo(LogicalKeyboardKey.keyZ, ctrl: true);
      expect(service.usedBy(undo).map((a) => a.id), ['edit.undo']);
      await service.addBinding('tool.plot', undo);
      expect(service.bindingsOf('tool.plot'), [undo]);
      expect(service.bindingsOf('edit.undo'), isEmpty);
      expect(service.usedBy(undo).map((a) => a.id), ['tool.plot']);
      // the same key twice is one key
      await service.setBindings('tool.plot', [undo, undo]);
      expect(service.bindingsOf('tool.plot'), [undo]);
    });

    test('settings that cannot be read, or that name actions there are none of, leave the defaults', () async {
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      final settings = SettingsRepository(db);
      await settings.set('keyboard_shortcuts', 'not json');
      final broken = ShortcutService(settings, mac: false);
      await broken.load();
      expect(broken.anyChanged, isFalse);
      await settings.set('keyboard_shortcuts', '{"gone.action":["ctrl+97"],"tool.plot":["ctrl+97","junk"]}');
      final partly = ShortcutService(settings, mac: false);
      await partly.load();
      expect(partly.bindingsOf('tool.plot'), [KeyCombo(LogicalKeyboardKey.keyA, ctrl: true)]);
      expect(partly.action('gone.action'), isNull);
    });

    testWidgets('hands a pressed combination to the newest handler that does it, and not while paused or typing', (tester) async {
      final service = ShortcutService.inMemory(mac: false);
      await service.setBindings('tool.plot', [KeyCombo(LogicalKeyboardKey.keyX, ctrl: true, shift: true), KeyCombo(LogicalKeyboardKey.keyQ)]);
      final asked = <String>[];
      final first = <String>[];
      bool older(String id) {
        first.add(id);
        return id == 'tool.plot';
      }

      bool newer(String id) {
        asked.add(id);
        return false; // not its action
      }

      service.addHandler(older);
      service.addHandler(newer);
      final focus = FocusNode();
      final text = TextEditingController();
      addTearDown(() {
        service.removeHandler(older);
        service.removeHandler(newer);
      });
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: TextField(controller: text, focusNode: focus))));

      await press(tester, LogicalKeyboardKey.keyX, held: [ctrl, shift]);
      expect(asked, ['tool.plot']);
      expect(first, ['tool.plot']);

      service.pause();
      await press(tester, LogicalKeyboardKey.keyX, held: [ctrl, shift]);
      expect(asked, ['tool.plot']); // nothing new
      service.resume();

      await press(tester, LogicalKeyboardKey.keyQ); // a plain key: it is for the text while one is typed in
      expect(asked, ['tool.plot', 'tool.plot']);
      focus.requestFocus();
      await tester.pump();
      await press(tester, LogicalKeyboardKey.keyQ);
      expect(asked, ['tool.plot', 'tool.plot']);
      await press(tester, LogicalKeyboardKey.keyX, held: [ctrl, shift]); // but one with Ctrl is not typing
      expect(asked, ['tool.plot', 'tool.plot', 'tool.plot']);
    });
  });

  group('in the editor', () {
    late NoteRepository repo;
    late String id;

    Future<ShortcutService> open(WidgetTester tester, {void Function(ShortcutService)? configure}) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        repo = NoteRepository(db);
        id = await repo.createNote();
      });
      final service = ShortcutService.inMemory(mac: false);
      configure?.call(service);
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, shortcuts: service)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      return service;
    }

    testWidgets('the default keys change the mode, the tool and the color', (tester) async {
      await open(tester);
      expect(find.byKey(const ValueKey('undo-button')), findsNothing); // select mode: no drawing bar
      await press(tester, LogicalKeyboardKey.digit2, held: [alt]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('undo-button')), findsOneWidget);

      expect(find.byIcon(Icons.auto_fix_normal), findsNothing); // (the icon of the eraser when it is on)
      await press(tester, LogicalKeyboardKey.keyE);
      await tester.pump();
      expect(find.byIcon(Icons.auto_fix_normal), findsOneWidget);
      await press(tester, LogicalKeyboardKey.keyE); // again: the pen
      await tester.pump();
      expect(find.byIcon(Icons.auto_fix_normal), findsNothing);

      // the dot on the width button is in the color of the pen
      Color pen() => ((tester.widget<Container>(find.descendant(of: find.byTooltip('Stroke Size'), matching: find.byType(Container)).first)).decoration! as BoxDecoration).color!;
      await press(tester, LogicalKeyboardKey.digit3);
      await tester.pump();
      expect(pen(), Colors.redAccent);
      await press(tester, LogicalKeyboardKey.digit5);
      await tester.pump();
      expect(pen(), Colors.purple);

      await press(tester, LogicalKeyboardKey.digit1, held: [alt]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('undo-button')), findsNothing); // back in select mode
    });

    testWidgets('a key the person chose does what it is set to, and the old one does nothing', (tester) async {
      await open(tester, configure: (s) {
        s.addBinding('tool.eraser', KeyCombo(LogicalKeyboardKey.keyX, ctrl: true, shift: true));
        s.setBindings('mode.draw', [KeyCombo(LogicalKeyboardKey.keyD)]);
      });
      await press(tester, LogicalKeyboardKey.digit2, held: [alt]); // the usual key for draw mode is gone
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('undo-button')), findsNothing);

      await press(tester, LogicalKeyboardKey.keyX, held: [ctrl, shift]); // the eraser, which goes to draw mode by itself
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('undo-button')), findsOneWidget);
      expect(find.byIcon(Icons.auto_fix_normal), findsOneWidget);
    });

    testWidgets('the keys of the line width step through the widths of the menu', (tester) async {
      await open(tester);
      await press(tester, LogicalKeyboardKey.digit2, held: [alt]);
      await tester.pumpAndSettle();
      Future<double> width() async => (tester.widget<Container>(find.descendant(of: find.byTooltip('Stroke Size'), matching: find.byType(Container)).first)).constraints!.maxWidth;
      final normal = await width();
      await press(tester, LogicalKeyboardKey.period);
      await tester.pump();
      expect(await width(), greaterThan(normal));
      await press(tester, LogicalKeyboardKey.comma);
      await press(tester, LogicalKeyboardKey.comma);
      await tester.pump();
      expect(await width(), lessThan(normal));
    });

    testWidgets('the slider at the end of the width menu sets any width', (tester) async {
      await open(tester);
      await press(tester, LogicalKeyboardKey.digit2, held: [alt]);
      await tester.pumpAndSettle();
      Future<double> width() async => (tester.widget<Container>(find.descendant(of: find.byTooltip('Stroke Size'), matching: find.byType(Container)).first)).constraints!.maxWidth;
      final normal = await width();
      await tester.ensureVisible(find.byTooltip('Stroke Size'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stroke Size'));
      await tester.pumpAndSettle();
      expect(find.text('Hairline (0.5pt)'), findsOneWidget);
      await tester.drag(find.descendant(of: find.byKey(const ValueKey('custom-width')), matching: find.byType(Slider)), const Offset(60, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('custom-width')), findsOneWidget); // (the menu stays open)
      expect(await width(), greaterThan(normal));
    });
  });

  group('the settings', () {
    Future<ShortcutService> show(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final service = ShortcutService.inMemory(mac: false);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ShortcutSettings(service: service)))));
      return service;
    }

    testWidgets('a shortcut is recorded by pressing it, and a key that is used elsewhere is said so', (tester) async {
      final service = await show(tester);
      final add = find.byKey(const ValueKey('shortcut-add-tool.plot'));
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('key-recorder')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('key-recorder-assign'))).onPressed, isNull); // nothing pressed yet

      await tester.sendKeyDownEvent(ctrl);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
      await tester.pump();
      final recorder = find.byKey(const ValueKey('key-recorder'));
      expect(find.descendant(of: recorder, matching: find.text('Ctrl+Z')), findsOneWidget);
      expect(find.textContaining('Already used for: Undo'), findsOneWidget);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(ctrl);
      await tester.pump();
      expect(find.descendant(of: recorder, matching: find.text('Ctrl+Z')), findsOneWidget); // it stays until another is pressed

      await tester.tap(find.byKey(const ValueKey('key-recorder-assign')));
      await tester.pumpAndSettle();
      expect(service.bindingsOf('tool.plot'), [KeyCombo(LogicalKeyboardKey.keyZ, ctrl: true)]);
      expect(service.bindingsOf('edit.undo'), isEmpty);
      expect(find.byKey(const ValueKey('shortcut-reset-tool.plot')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('shortcut-reset-tool.plot')));
      await tester.pumpAndSettle();
      expect(service.bindingsOf('tool.plot'), isEmpty);
    });

    testWidgets('a shortcut can be changed, taken away, and Escape leaves the recording alone', (tester) async {
      final service = await show(tester);
      final pen = find.byKey(ValueKey('shortcut-tool.pen-${KeyCombo(LogicalKeyboardKey.keyP).encode()}'));
      await tester.ensureVisible(pen);
      await tester.pumpAndSettle();
      await tester.tap(pen); // change it
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('key-recorder')), findsNothing);
      expect(service.changed('tool.pen'), isFalse);

      await tester.tap(pen);
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.keyB, held: [alt]);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('key-recorder-assign')));
      await tester.pumpAndSettle();
      expect(service.bindingsOf('tool.pen'), [KeyCombo(LogicalKeyboardKey.keyB, alt: true)]);

      await tester.tap(find.descendant(of: find.byKey(const ValueKey('shortcut-row-tool.pen')), matching: find.byTooltip('Remove this shortcut')));
      await tester.pumpAndSettle();
      expect(service.bindingsOf('tool.pen'), isEmpty);
      expect(find.descendant(of: find.byKey(const ValueKey('shortcut-row-tool.pen')), matching: find.text('Not set')), findsOneWidget);

      await tester.ensureVisible(find.byKey(const ValueKey('shortcuts-reset-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shortcuts-reset-all')));
      await tester.pumpAndSettle();
      expect(service.anyChanged, isFalse);
    });

    testWidgets('the list can be searched by what an action is called or by its keys', (tester) async {
      await show(tester);
      await tester.enterText(find.byKey(const ValueKey('shortcut-search')), 'eraser');
      await tester.pump();
      expect(find.byKey(const ValueKey('shortcut-row-tool.eraser')), findsOneWidget);
      expect(find.byKey(const ValueKey('shortcut-row-tool.pen')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('shortcut-search')), 'f5');
      await tester.pump();
      expect(find.byKey(const ValueKey('shortcut-row-note.present')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('shortcut-search')), 'nothing like this');
      await tester.pump();
      expect(find.text('No action matches.'), findsOneWidget);
    });
  });
}
