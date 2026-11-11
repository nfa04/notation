import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/features/toolbar_profiles.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/shortcuts/shortcut_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'shortcut_test.dart' show alt, ctrl, press, shift;

void main() {
  setUpAll(AppDatabase.initFfi);

  group('saved profiles', () {
    test('they come back as they were saved, with the one in use', () {
      final a = ToolbarProfile(id: 'a', name: 'Draw', top: ['mode', 'edit'], bottom: ['insert'], hidden: {'history'}, tools: {Feature.highlighter, Feature.shapes});
      final b = ToolbarProfile(id: 'b', name: 'Maths', top: ['edit'], bottom: [], hidden: {}, tools: {Feature.solve, Feature.plots});
      final read = decodeToolbarProfiles(encodeToolbarProfiles([a, b], 'b'));
      expect(read.active, 'b');
      expect(read.profiles.map((p) => p.name), ['Draw', 'Maths']);
      expect(read.profiles.first.top, ['mode', 'edit']);
      expect(read.profiles.first.bottom, ['insert']);
      expect(read.profiles.first.hidden, {'history'});
      expect(read.profiles.first.tools, {Feature.highlighter, Feature.shapes});
    });

    test('nothing saved, something unreadable, a tool from the future and a missing active profile are all handled', () {
      expect(decodeToolbarProfiles(null).profiles, isEmpty);
      expect(decodeToolbarProfiles('not json').profiles, isEmpty);
      expect(decodeToolbarProfiles('{"profiles":[{"id":1}]}').profiles, isEmpty);
      final read = decodeToolbarProfiles('{"active":"gone","profiles":[{"id":"a","name":"A","tools":["solve","a tool from the future"]}]}');
      expect(read.profiles.single.tools, contains(Feature.solve), reason: 'the tool of the future is left out, the others are kept');
      expect(read.active, 'a', reason: 'an active profile that does not exist falls back to the first');
    });

    test('every tool the editor shows is part of a profile, and only the app-wide ones are not', () {
      expect(toolbarTools, containsAll([Feature.highlighter, Feature.solve, Feature.brushes, Feature.pdf, Feature.assistant, Feature.history, Feature.noteFiles, Feature.citations, Feature.handwriting]));
      expect(toolbarTools.toSet(), Feature.values.toSet().difference({Feature.calendar, Feature.automations}));
    });

    test('a profile saved before a tool was part of profiles has that tool on, and one the person left off stays off', () {
      // saved when profiles covered the writing and maths tools only, and without a record of that
      final old = decodeToolbarProfiles('{"active":"a","profiles":[{"id":"a","name":"A","tools":["solve"]}]}').profiles.single;
      expect(old.tools, contains(Feature.pdf), reason: 'it did not know of the PDF tool');
      expect(old.tools, contains(Feature.assistant));
      expect(old.tools, contains(Feature.solve));
      expect(old.tools, isNot(contains(Feature.plots)), reason: 'it knew of plots, and plots were off');
      // saved by this version
      final again = decodeToolbarProfiles(encodeToolbarProfiles([old.copyWith(tools: {Feature.solve})], 'a')).profiles.single;
      expect(again.tools, {Feature.solve}, reason: 'it knows of all of them now: the rest were left off');
    });
  });

  group('in the editor', () {
    late NoteRepository repo;
    late FeatureSettings features;

    Future<void> open(WidgetTester tester, {Size size = const Size(1600, 1000)}) async {
      features = FeatureSettings((k) async => null, (k, v) async {});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late String id;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        await db.delete('settings');
        repo = NoteRepository(db);
        await repo.settings.set('index_handwriting', '0');
        await repo.settings.set('pdf_handwriting_text', '0');
        id = await repo.createNote();
      });
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, features: features, shortcuts: ShortcutService.inMemory(mac: false))));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
    }

    // what the editor saved (its writes to the database need real time to finish)
    Future<String?> saved(WidgetTester tester) async =>
        (await tester.runAsync<String?>(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return repo.settings.get('toolbar_profiles');
        }));

    // makes the profiles with these names, the last one in use
    Future<void> makeProfiles(WidgetTester tester, List<String> names) async {
      for (final name in names) {
        await tester.ensureVisible(find.byKey(const ValueKey('customize-toolbar'))); // (it scrolls sideways on a narrow screen)
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('customize-toolbar')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('profile-new')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('toolbar-profile-name')), name);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
      }
    }

    String shownProfile(WidgetTester tester) {
      final menu = find.byKey(const ValueKey('toolbar-profile-menu'));
      return tester.widget<Text>(find.descendant(of: menu, matching: find.byType(Text))).data!;
    }

    Future<void> chooseProfile(WidgetTester tester, String id) async {
      await tester.tap(find.byKey(const ValueKey('toolbar-profile-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('toolbar-profile-$id')));
      await tester.pumpAndSettle();
    }

    Future<void> openTools(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('customize-toolbar')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('toolbar-tools')), matching: find.byType(ListTile)).first);
      await tester.pumpAndSettle();
    }

    final addTable = find.byKey(const ValueKey('add-table'));

    testWidgets('a profile uses some of the tools that are on, and changing the profile leaves the settings alone', (tester) async {
      await open(tester);
      expect(find.byKey(const ValueKey('toolbar-profile-menu')), findsNothing, reason: 'one arrangement is no choice');
      expect(addTable, findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('customize-toolbar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('profile-new')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('toolbar-profile-name')), 'Creative');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      // the new profile does without tables
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('toolbar-tools')), matching: find.byType(ListTile)).first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('toolbar-tool-tables')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toolbar-tool-tables')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(addTable, findsNothing, reason: 'this profile does not use tables');
      expect(features.on(Feature.tables), isTrue, reason: 'the settings are the person\'s, not the profile\'s');
      expect(features.allOn, isTrue);
      expect(find.descendant(of: find.byKey(const ValueKey('toolbar-profile-menu')), matching: find.text('Creative')), findsOneWidget);

      final creative = decodeToolbarProfiles(await saved(tester)).profiles.firstWhere((p) => p.name == 'Creative').id;
      await chooseProfile(tester, 'default');
      expect(addTable, findsOneWidget);
      await chooseProfile(tester, creative);
      expect(addTable, findsNothing);
      expect(features.allOn, isTrue);

      final read = decodeToolbarProfiles(await saved(tester));
      expect(read.profiles.map((p) => p.name), ['Default', 'Creative']);
      expect(read.profiles.firstWhere((p) => p.id == read.active).name, 'Creative');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a tool that is off in the settings is off in every profile, and comes back only where the profile uses it', (tester) async {
      await open(tester);
      await makeProfiles(tester, ['Draw']); // "Default" uses every tool, "Draw" is made from it
      final draw = decodeToolbarProfiles(await saved(tester)).profiles.firstWhere((p) => p.name == 'Draw').id;
      await openTools(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('toolbar-tool-tables')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toolbar-tool-tables'))); // "Draw" does without tables
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(addTable, findsNothing);

      // tables are switched off in the settings
      await tester.runAsync(() => features.set(Feature.tables, false));
      await chooseProfile(tester, 'default');
      expect(addTable, findsNothing, reason: 'off in the settings: not in the profile that uses tables either');
      await chooseProfile(tester, draw);
      expect(addTable, findsNothing);
      // and the dialog has no switch for it
      await openTools(tester);
      expect(find.byKey(const ValueKey('toolbar-tool-tables'), skipOffstage: false), findsNothing);
      expect(find.byKey(const ValueKey('toolbar-tool-shapes'), skipOffstage: false), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      // switched on again: back where the profile uses it, still not where it does not
      await tester.runAsync(() => features.set(Feature.tables, true));
      await chooseProfile(tester, 'default');
      expect(addTable, findsOneWidget);
      await chooseProfile(tester, draw);
      expect(addTable, findsNothing);
      await saved(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the dialog has a switch for every tool that is on, in groups, and none for the ones of the app as a whole', (tester) async {
      await open(tester);
      await makeProfiles(tester, ['Draw']);
      await openTools(tester);
      for (final f in toolbarTools) {
        expect(find.byKey(ValueKey('toolbar-tool-${f.name}'), skipOffstage: false), findsOneWidget, reason: f.title);
      }
      expect(find.byKey(const ValueKey('toolbar-tool-calendar'), skipOffstage: false), findsNothing);
      for (final group in FeatureGroup.values) {
        if (group == FeatureGroup.organising) continue; // (only partly there)
        expect(find.text(group.title, skipOffstage: false), findsWidgets, reason: group.title); // (a group and a tool can share a name)
      }
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await saved(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the buttons of the note (favourite, lock...) go with their switch', (tester) async {
      await open(tester);
      expect(find.byKey(const ValueKey('favorite-note')), findsOneWidget);
      await tester.runAsync(() => features.set(Feature.favorites, false));
      await tester.pumpAndSettle();
      // (the editor looks at the tools when it is built: a change in the settings is seen when it is back on screen)
      await tester.tap(find.byKey(const ValueKey('customize-toolbar')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('favorite-note')), findsNothing);
      await saved(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a profile has its own bars: moving a section in one leaves the other as it was', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('customize-toolbar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('profile-new')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('toolbar-profile-name')), 'Maths');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      // 'insert' starts in the bottom bar: this profile puts it at the top
      await tester.tap(find.byKey(const ValueKey('toolbar-move-insert')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-text-box')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('bottom-toolbar')), matching: find.byKey(const ValueKey('add-text-box'))), findsNothing);

      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toolbar-profile-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toolbar-profile-default')));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(const ValueKey('bottom-toolbar')), matching: find.byKey(const ValueKey('add-text-box'))), findsOneWidget);
      await saved(tester); // (lets the saving finish)
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('deleting down to one profile leaves just the toolbar again', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('customize-toolbar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('profile-new')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('toolbar-profile-name')), 'Other');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('profile-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('toolbar-profile-menu')), findsNothing);
      expect(await saved(tester), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the keys go through the profiles, around the end and back', (tester) async {
      await open(tester);
      await press(tester, LogicalKeyboardKey.keyP, held: [ctrl, alt]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('toolbar-profile-menu')), findsNothing, reason: 'with one arrangement there is nothing to go to');

      await makeProfiles(tester, ['Draw', 'Maths']); // (the first one made is "Default", of the arrangement before)
      expect(shownProfile(tester), 'Maths');
      await press(tester, LogicalKeyboardKey.keyP, held: [ctrl, alt]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(shownProfile(tester), 'Default', reason: 'after the last comes the first');
      expect(find.widgetWithText(SnackBar, 'Default'), findsOneWidget, reason: 'it says where it went');
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.keyP, held: [ctrl, alt, shift]);
      await tester.pumpAndSettle();
      expect(shownProfile(tester), 'Maths');
      await press(tester, LogicalKeyboardKey.keyP, held: [ctrl, alt, shift]);
      await tester.pumpAndSettle();
      expect(shownProfile(tester), 'Draw');
      await saved(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('on a phone the button for the profiles stays in view, whatever the toolbar holds', (tester) async {
      await open(tester, size: const Size(412, 900));
      await makeProfiles(tester, ['Draw']);
      final menu = find.byKey(const ValueKey('toolbar-profile-menu'));
      expect(menu, findsOneWidget);
      final box = tester.getRect(menu);
      expect(box.left, greaterThanOrEqualTo(0));
      expect(box.right, lessThanOrEqualTo(412));
      // and it is not one of the buttons that scroll
      expect(find.ancestor(of: menu, matching: find.byType(SingleChildScrollView)), findsNothing);
      await saved(tester);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
