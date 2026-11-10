import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/app_services.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/features/toolbar_profiles.dart';
import 'package:notes/models/authorship.dart';
import 'package:notes/profile/user_profile.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/intro_screen.dart';
import 'package:notes/screens/main_shell.dart';
import 'package:notes/screens/settings_screen.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/style/style_service.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:notes/sync/device_calendar_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class Store {
  final values = <String, String>{};
  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  setUpAll(AppDatabase.initFfi);
  tearDown(() {
    Authorship.set(null);
    Authorship.setId(null);
  });

  late Store store;
  late UserProfile profile;
  late FeatureSettings features;

  Future<void> start(WidgetTester tester) async {
    store = Store();
    profile = UserProfile(store.read, store.write);
    features = FeatureSettings(store.read, store.write);
    await tester.runAsync(() async {
      await profile.load();
      await features.load();
    });
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  group('the intro', () {
    testWidgets('asks for a name and what the app is used for, and switches on the tools that go with it', (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await start(tester);
      await tester.pumpWidget(MaterialApp(home: ListenableBuilder(listenable: profile, builder: (context, _) => IntroScreen(profile: profile, features: features))));
      expect(find.text('Welcome to Notation'), findsOneWidget);

      await tap(tester, find.byKey(const ValueKey('intro-next')));
      expect(find.text('What should we call you?'), findsOneWidget);
      expect(find.byKey(const ValueKey('intro-id')), findsOneWidget);
      expect(find.textContaining(profile.id), findsOneWidget, reason: 'the id made for this person is shown');
      await tester.enterText(find.byKey(const ValueKey('intro-name')), 'Sokrates');
      await tap(tester, find.byKey(const ValueKey('intro-next')));

      expect(find.text('What will you use Notation for?'), findsOneWidget);
      expect(find.byKey(const ValueKey('intro-everything-on')), findsOneWidget, reason: 'nothing chosen yet: everything stays on');
      await tap(tester, find.byKey(const ValueKey('area-humanities')));
      expect(find.byKey(const ValueKey('intro-everything-on')), findsNothing);
      await tap(tester, find.byKey(const ValueKey('area-languages')));
      await tap(tester, find.byKey(const ValueKey('intro-next')));

      // the tools that follow from it, which can be changed
      expect(find.text('Your tools'), findsOneWidget);
      Switch switchOf(Feature f) => tester.widget<Switch>(find.descendant(of: find.byKey(ValueKey('tool-${f.name}')), matching: find.byType(Switch)));
      expect(switchOf(Feature.lookup).value, isTrue);
      expect(switchOf(Feature.flashcards).value, isTrue);
      expect(switchOf(Feature.solve).value, isFalse, reason: 'not for a philosopher');
      expect(switchOf(Feature.plots).value, isFalse);
      await tap(tester, find.byKey(const ValueKey('tool-solve')));
      expect(switchOf(Feature.solve).value, isTrue, reason: 'they can have it anyway');
      await tap(tester, find.byKey(const ValueKey('tool-lookup')));
      expect(switchOf(Feature.lookup).value, isFalse);

      expect(profile.introDone, isFalse);
      await tap(tester, find.byKey(const ValueKey('intro-next')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(profile.introDone, isTrue);
      expect(profile.name, 'Sokrates');
      expect(store.values['collab_name'], 'Sokrates');
      expect(Authorship.current, '${profile.id}:Sokrates');
      expect(features.on(Feature.solve), isTrue);
      expect(features.on(Feature.lookup), isFalse);
      expect(features.on(Feature.mathInk), isFalse);
      expect(features.on(Feature.assistant), isTrue);
      expect(features.areas, {UseArea.humanities, UseArea.languages});
    });

    testWidgets('"show me everything" and "skip" leave every tool on; the name can stay empty; back goes back', (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await start(tester);
      await tester.pumpWidget(MaterialApp(home: IntroScreen(profile: profile, features: features)));
      await tap(tester, find.byKey(const ValueKey('intro-next')));
      await tap(tester, find.byKey(const ValueKey('intro-next'))); // no name
      await tap(tester, find.byKey(const ValueKey('area-maths')));
      await tap(tester, find.byKey(const ValueKey('intro-everything')));
      expect(find.byKey(const ValueKey('intro-everything-on')), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('intro-back')));
      expect(find.text('What should we call you?'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('intro-next')));
      await tap(tester, find.byKey(const ValueKey('intro-next')));
      await tap(tester, find.byKey(const ValueKey('intro-next')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(profile.introDone, isTrue);
      expect(profile.name, '');
      expect(features.allOn, isTrue);
    });

    testWidgets('skipping at the start leaves everything on and the intro done', (tester) async {
      await start(tester);
      await tester.pumpWidget(MaterialApp(home: IntroScreen(profile: profile, features: features)));
      await tap(tester, find.byKey(const ValueKey('intro-skip')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(profile.introDone, isTrue);
      expect(features.allOn, isTrue);
      expect(store.values.containsKey(FeatureSettings.enabledKey), isFalse, reason: 'nothing chosen, nothing saved');
    });
  });

  group('the settings', () {
    testWidgets('who you are: the name is changed here, the id is shown, and the intro can be asked for again', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await start(tester);
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory(), profile: profile, features: features)));
      expect(find.byKey(const ValueKey('profile-id')), findsOneWidget);
      expect(find.textContaining(profile.id), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('profile-name')), 'Platon');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(profile.name, 'Platon');

      await profile.finishIntro();
      await tap(tester, find.byKey(const ValueKey('profile-intro')));
      expect(profile.introDone, isFalse);
    });

    testWidgets('the tools: a use sets them up, "only the basics" and "show everything" are presets, every tool has a switch', (tester) async {
      tester.view.physicalSize = const Size(1000, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await start(tester);
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory(), profile: profile, features: features)));
      await tester.tap(find.byKey(const ValueKey('settings-tab-Tools and writing')));
      await tester.pumpAndSettle();
      expect(find.byType(SwitchListTile).evaluate().length, greaterThanOrEqualTo(Feature.values.length));
      for (final f in Feature.values) {
        expect(find.byKey(ValueKey('tool-${f.name}')), findsOneWidget, reason: f.name);
      }
      final all = tester.widget<FilledButton>(find.byKey(const ValueKey('tools-all')));
      expect(all.onPressed, isNull, reason: 'everything is on already');

      await tap(tester, find.byKey(const ValueKey('area-maths')));
      expect(features.on(Feature.plots), isTrue);
      expect(features.on(Feature.lookup), isFalse);
      expect(features.areas, {UseArea.maths});
      await tap(tester, find.byKey(const ValueKey('area-humanities')));
      expect(features.on(Feature.plots), isTrue);
      expect(features.on(Feature.lookup), isTrue);
      await tap(tester, find.byKey(const ValueKey('area-maths')));
      expect(features.on(Feature.plots), isFalse, reason: 'taking a use away takes its tools');
      expect(features.on(Feature.lookup), isTrue);

      await tap(tester, find.byKey(const ValueKey('tool-plots')));
      expect(features.on(Feature.plots), isTrue);

      await tap(tester, find.byKey(const ValueKey('tools-basics')));
      expect(features.enabled, FeaturePresets.basics);
      await tap(tester, find.byKey(const ValueKey('tools-all')));
      expect(features.allOn, isTrue);
    });
  });

  group('the app follows the tools', () {
    testWidgets('the calendar and the automations leave the menu when they are off, and come back', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await start(tester);
      late NoteRepository notes;
      late TaskRepository tasks;
      late SettingsRepository settings;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        notes = NoteRepository(db);
        tasks = TaskRepository(db);
        settings = SettingsRepository(db);
      });
      await tester.pumpWidget(MaterialApp(
        home: MainShellNavigation(services: AppServices(
          repository: notes,
          tasks: tasks,
          caldav: CalDavService(settings, tasks),
          device: DeviceCalendarService(settings),
          style: StyleService.inMemory(),
          appTheme: AppTheme.inMemory(),
          features: features,
          profile: profile,
        )),
      ));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      Finder inMenu(String label) => find.descendant(of: find.byType(NavigationRail), matching: find.text(label));
      for (final label in ['Dashboard', 'Folders', 'Calendar', 'Active Canvas', 'Automations', 'Settings']) {
        expect(inMenu(label), findsOneWidget, reason: label);
      }

      await tester.runAsync(() => features.set(Feature.calendar, false));
      await tester.pumpAndSettle();
      expect(inMenu('Calendar'), findsNothing);
      expect(inMenu('Automations'), findsOneWidget);
      await tester.runAsync(() => features.set(Feature.automations, false));
      await tester.pumpAndSettle();
      expect(inMenu('Automations'), findsNothing);

      // the places that are left still go where they say
      await tap(tester, inMenu('Settings'));
      expect(find.byType(SettingsScreen), findsOneWidget);
      await tester.tap(inMenu('Folders'));
      await tester.pump(const Duration(milliseconds: 300)); // (the folders load: no settling)
      expect(find.byType(SettingsScreen), findsNothing);

      await tester.runAsync(() => features.showAll());
      await tester.pump(const Duration(milliseconds: 300));
      expect(inMenu('Calendar'), findsOneWidget);
      expect(inMenu('Automations'), findsOneWidget);
      // (what the screens read from the database finishes before the test ends: a query left waiting keeps a timer of sqflite)
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    });

    testWidgets('the editor shows the tools that are on and not the ones that are off', (tester) async {
      tester.view.physicalSize = const Size(1600, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await start(tester);
      late NoteRepository repo;
      late String id;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        repo = NoteRepository(db);
        id = await repo.createNote();
      });
      Future<void> open() async {
        await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: UniqueKey(), noteId: id, repository: repo, features: features)));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Draw'));
        await tester.tap(find.text('Draw'));
        await tester.pumpAndSettle();
      }

      await open();
      expect(find.byKey(const ValueKey('add-table')), findsOneWidget);
      expect(find.byTooltip('Add a picture'), findsOneWidget);
      expect(find.byTooltip('Highlighter (see-through, in the chosen color)'), findsOneWidget);
      expect(find.byKey(const ValueKey('straighten-toggle')), findsOneWidget);
      expect(find.byKey(const ValueKey('empty-plot')), findsOneWidget);
      expect(find.text('Import PDF'), findsOneWidget);
      expect(find.text('Export PDF'), findsOneWidget);
      expect(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'), findsOneWidget);

      await tester.runAsync(() => features.apply(FeaturePresets.forAreas({UseArea.humanities})..remove(Feature.highlighter)..remove(Feature.pdf)..remove(Feature.images)..remove(Feature.lasso)));
      await open();
      expect(find.byKey(const ValueKey('add-table')), findsNothing, reason: 'tables are not for the humanities');
      expect(find.byKey(const ValueKey('empty-plot')), findsNothing);
      expect(find.byKey(const ValueKey('straighten-toggle')), findsNothing);
      expect(find.byTooltip('Add a picture'), findsNothing);
      expect(find.byTooltip('Highlighter (see-through, in the chosen color)'), findsNothing);
      expect(find.byTooltip('Lasso: draw around drawings, text boxes and pictures to select them'), findsNothing);
      expect(find.text('Import PDF'), findsNothing);
      expect(find.text('Export PDF'), findsNothing);
      // what is always there is there
      expect(find.byKey(const ValueKey('add-text-box')), findsOneWidget);
      expect(find.byTooltip('Eraser (drawings only)'), findsOneWidget);
      expect(find.byKey(const ValueKey('undo-button')), findsOneWidget);
    });
  });

  group('toolbar profiles in the intro', () {
    test('uses of different kinds are unrelated, the ones that share their tools and working with others are not', () {
      expect(UseArea.unrelated({UseArea.maths, UseArea.arts}), isTrue);
      expect(UseArea.unrelated({UseArea.maths, UseArea.humanities}), isTrue);
      expect(UseArea.unrelated({UseArea.maths, UseArea.sciences, UseArea.computing}), isFalse);
      expect(UseArea.unrelated({UseArea.humanities, UseArea.languages}), isFalse);
      expect(UseArea.unrelated({UseArea.arts}), isFalse);
      expect(UseArea.unrelated({UseArea.maths, UseArea.together}), isFalse, reason: 'working with others is not a way of working of its own');
      expect(UseArea.unrelated(const <UseArea>{}), isFalse);
    });

    test('each use gets a profile with the tools of the basics and of that use, and nothing of the others', () {
      final made = profilesForAreas({UseArea.arts, UseArea.maths, UseArea.together}, (a) => a.shortTitle);
      expect(made.map((p) => p.name), ['Maths', 'Art and design'], reason: 'in the order of the list of uses, without the one for working together');
      final maths = made.first, art = made.last;
      expect(maths.tools, containsAll([Feature.plots, Feature.solve, Feature.favorites, Feature.live]));
      expect(maths.tools, isNot(contains(Feature.brushes)));
      expect(art.tools, containsAll([Feature.brushes, Feature.symmetry, Feature.favorites, Feature.live]));
      expect(art.tools, isNot(contains(Feature.plots)));
      expect(maths.tools, everyElement(isIn(toolbarTools)));
    });

    late SettingsRepository settings;

    Future<void> openIntro(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await start(tester);
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        await db.delete('settings');
        settings = SettingsRepository(db);
      });
      await tester.pumpWidget(MaterialApp(home: ListenableBuilder(listenable: profile, builder: (context, _) => IntroScreen(profile: profile, features: features, settings: settings))));
      await tap(tester, find.byKey(const ValueKey('intro-next')));
      await tap(tester, find.byKey(const ValueKey('intro-next')));
    }

    Future<String?> savedProfiles(WidgetTester tester) async => (await tester.runAsync<String?>(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return settings.get('toolbar_profiles');
        }));

    testWidgets('unrelated uses are offered a profile each, and saying yes makes them', (tester) async {
      await openIntro(tester);
      await tap(tester, find.byKey(const ValueKey('area-maths')));
      expect(find.byKey(const ValueKey('intro-profiles-offer')), findsNothing, reason: 'one use: nothing to switch between');
      await tap(tester, find.byKey(const ValueKey('area-sciences')));
      expect(find.byKey(const ValueKey('intro-profiles-offer')), findsNothing, reason: 'maths and the sciences are used together');
      await tap(tester, find.byKey(const ValueKey('area-arts')));
      expect(find.byKey(const ValueKey('intro-profiles-offer')), findsOneWidget);
      expect(find.text('Do you use these one at a time?'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('intro-profiles'))).value, isFalse, reason: 'a suggestion, not a decision made for them');
      await tap(tester, find.byKey(const ValueKey('intro-profiles')));
      await tap(tester, find.byKey(const ValueKey('intro-next')));
      expect(find.byKey(const ValueKey('intro-profiles-note')), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('intro-next')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();

      expect(features.on(Feature.plots), isTrue, reason: 'the settings have the tools of both uses');
      expect(features.on(Feature.brushes), isTrue);
      final read = decodeToolbarProfiles(await savedProfiles(tester));
      expect(read.profiles.map((p) => p.name), ['Maths', 'Sciences', 'Art and design']);
      expect(read.active, read.profiles.first.id);
      expect(read.profiles.last.tools, contains(Feature.brushes));
      expect(read.profiles.last.tools, isNot(contains(Feature.plots)));
    });

    testWidgets('without saying yes, or with uses that go together, no profiles are made', (tester) async {
      await openIntro(tester);
      await tap(tester, find.byKey(const ValueKey('area-maths')));
      await tap(tester, find.byKey(const ValueKey('area-arts')));
      await tap(tester, find.byKey(const ValueKey('intro-next')));
      await tap(tester, find.byKey(const ValueKey('intro-next')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(await savedProfiles(tester), isNull);
    });

    testWidgets('profiles the person has already stay, and the new ones are added to them (the intro again, from the settings)', (tester) async {
      await openIntro(tester);
      final mine = ToolbarProfile(id: 'mine', name: 'Mine', top: const ['edit'], bottom: const [], hidden: const {}, tools: {Feature.shapes});
      final old = ToolbarProfile(id: 'area-maths', name: 'Old maths', top: const [], bottom: const [], hidden: const {}, tools: {Feature.solve});
      await tester.runAsync(() => settings.set('toolbar_profiles', encodeToolbarProfiles([mine, old], 'mine')));
      await tap(tester, find.byKey(const ValueKey('area-maths')));
      await tap(tester, find.byKey(const ValueKey('area-arts')));
      await tap(tester, find.byKey(const ValueKey('intro-profiles')));
      await tap(tester, find.byKey(const ValueKey('intro-next')));
      await tap(tester, find.byKey(const ValueKey('intro-next')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      final read = decodeToolbarProfiles(await savedProfiles(tester));
      expect(read.profiles.map((p) => p.name), ['Mine', 'Maths', 'Art and design'], reason: 'the profile of an earlier intro for the same use is made again, the person\'s own stays');
      expect(read.profiles.first.tools, {Feature.shapes}, reason: 'untouched');
      expect(read.active, 'mine', reason: 'the one in use stays in use');
    });
  });
}
