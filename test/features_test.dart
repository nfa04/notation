import 'package:flutter_test/flutter_test.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/models/authorship.dart';
import 'package:notes/profile/user_profile.dart';

/// A place to keep settings, as strings.
class Store {
  final values = <String, String>{};
  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  tearDown(() {
    Authorship.set(null);
    Authorship.setId(null);
  });

  group('the tools and the presets', () {
    test('every tool says what it is, and is in a group', () {
      for (final f in Feature.values) {
        expect(f.title, isNotEmpty, reason: f.name);
        expect(f.description.length, greaterThan(15), reason: f.name);
        expect(FeatureGroup.values, contains(f.group));
      }
      expect({for (final f in Feature.values) f.group}, FeatureGroup.values.toSet(), reason: 'no group is empty');
      expect(Feature.byId('tables'), Feature.tables);
      expect(Feature.byId('a tool from the future'), isNull);
    });

    test('no uses: the basics; a use adds its tools to them', () {
      expect(FeaturePresets.forAreas(const []), FeaturePresets.basics);
      final maths = FeaturePresets.forAreas({UseArea.maths});
      expect(maths, containsAll([...FeaturePresets.basics, Feature.solve, Feature.plots, Feature.mathInk]));
      expect(FeaturePresets.forAreas({UseArea.maths, UseArea.together}), containsAll([...maths, Feature.live]));
    });

    test('someone who studies philosophy never gets the maths tools; a mathematician keeps no language tools they did not ask for', () {
      final philosophy = FeaturePresets.forAreas({UseArea.humanities});
      for (final f in Feature.values.where((f) => f.group == FeatureGroup.maths)) {
        expect(philosophy, isNot(contains(f)), reason: f.name);
      }
      expect(philosophy, containsAll([Feature.lookup, Feature.assistant, Feature.flashcards]));
      final maths = FeaturePresets.forAreas({UseArea.maths});
      expect(maths, isNot(contains(Feature.lookup)));
      expect(maths, isNot(contains(Feature.flashcards)));
    });

    test('every use has some tools of its own, and the presets are made of known tools only', () {
      for (final a in UseArea.values) {
        expect(a.features, isNotEmpty, reason: a.name);
        expect(a.title, isNotEmpty);
        expect(a.description, isNotEmpty);
      }
      expect(FeaturePresets.everything.length, Feature.values.length);
      expect(FeaturePresets.basics.difference(FeaturePresets.everything), isEmpty);
      expect(FeaturePresets.minimal.length, lessThan(FeaturePresets.basics.length));
    });

    test('the uses together reach every tool that is not in the basics (so "everything" is never the only way to a tool)', () {
      final reached = {for (final a in UseArea.values) ...a.features, ...FeaturePresets.basics};
      expect(Feature.values.toSet().difference(reached), isEmpty);
    });
  });

  group('which tools are on', () {
    late Store store;
    late FeatureSettings features;
    setUp(() async {
      store = Store();
      features = FeatureSettings(store.read, store.write);
      await features.load();
    });

    test('with nothing saved every tool is on (the app as it was), and "show everything" is not needed', () {
      expect(features.allOn, isTrue);
      for (final f in Feature.values) {
        expect(features.on(f), isTrue, reason: f.name);
      }
      expect(features.areas, isEmpty);
    });

    test('a tool can be switched off and on, and it is remembered', () async {
      var heard = 0;
      features.addListener(() => heard++);
      await features.set(Feature.tables, false);
      expect(features.on(Feature.tables), isFalse);
      expect(features.on(Feature.shapes), isTrue);
      expect(features.allOn, isFalse);
      expect(heard, 1);
      await features.set(Feature.tables, false);
      expect(heard, 1, reason: 'no change, nothing to tell');

      final again = FeatureSettings(store.read, store.write);
      await again.load();
      expect(again.on(Feature.tables), isFalse);
      expect(again.on(Feature.shapes), isTrue);
      await again.set(Feature.tables, true);
      expect(again.allOn, isTrue);
    });

    test('a preset switches on exactly its tools and remembers the uses it came from', () async {
      await features.apply(FeaturePresets.forAreas({UseArea.humanities}), areas: {UseArea.humanities});
      expect(features.on(Feature.lookup), isTrue);
      expect(features.on(Feature.solve), isFalse);
      expect(features.areas, {UseArea.humanities});

      final again = FeatureSettings(store.read, store.write);
      await again.load();
      expect(again.enabled, features.enabled);
      expect(again.areas, {UseArea.humanities});

      await again.showAll();
      expect(again.allOn, isTrue);
      expect(again.areas, isEmpty);
    });

    test('flashcards need the assistant', () async {
      expect(features.on(Feature.flashcards), isTrue);
      await features.set(Feature.assistant, false);
      expect(features.on(Feature.flashcards), isFalse, reason: 'the switch is on but there is no assistant to make them');
      expect(features.enabled, contains(Feature.flashcards));
      await features.set(Feature.assistant, true);
      expect(features.on(Feature.flashcards), isTrue);
    });

    test('a saved tool this version does not know is ignored, and a damaged saving means everything is on', () async {
      store.values[FeatureSettings.enabledKey] = '["tables","a tool from the future"]';
      final f = FeatureSettings(store.read, store.write);
      await f.load();
      // (citations, diagrams, the creative tools and the buttons of the note came after such a list was saved, so the person never chose against them)
      expect(f.enabled, {Feature.tables, Feature.citations, Feature.diagrams, Feature.brushes, Feature.symmetry, Feature.stabiliser, Feature.layers, Feature.pictureEdit, Feature.guides, Feature.arrange, Feature.stamps, Feature.flipbook, Feature.ideas, Feature.exportImages, Feature.alignLines, Feature.favorites, Feature.lock, Feature.reminders, Feature.outline, Feature.echoes, Feature.present, Feature.audio, Feature.translate, Feature.dictate, Feature.readAloud, Feature.colorPicker, Feature.fillBucket});
      store.values[FeatureSettings.enabledKey] = 'not json';
      final g = FeatureSettings(store.read, store.write);
      await g.load();
      expect(g.allOn, isTrue);
    });
  });

  group('who the person is', () {
    test('an id is made the first time, is 16 hex digits, and is the same every time after', () async {
      final store = Store();
      final a = UserProfile(store.read, store.write);
      await a.load();
      expect(a.id, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(a.shortId, a.id.substring(0, 4));
      final b = UserProfile(store.read, store.write);
      await b.load();
      expect(b.id, a.id);
      final other = UserProfile((_) async => null, (_, _) async {});
      await other.load();
      expect(other.id, isNot(a.id), reason: 'another device has another one');
    });

    test('the name is kept where the live settings always kept it, and goes on what the person adds, with the id', () async {
      final store = Store()..values['collab_name'] = 'Anna';
      final p = UserProfile(store.read, store.write);
      await p.load();
      expect(p.name, 'Anna', reason: 'a name set before is carried over');
      expect(Authorship.name, 'Anna');
      expect(Authorship.current, '${p.id}:Anna');

      await p.setName('  Ben  ');
      expect(store.values['collab_name'], 'Ben');
      expect(Authorship.current, '${p.id}:Ben');

      await p.setName('');
      expect(Authorship.name, isNull);
      expect(Authorship.current, '${p.id}:', reason: 'no name, but still who');
      expect(Author.parse(Authorship.current)!.name, '');
    });

    test('the intro is done once, and can be asked for again', () async {
      final store = Store();
      final p = UserProfile(store.read, store.write);
      await p.load();
      expect(p.introDone, isFalse);
      var heard = 0;
      p.addListener(() => heard++);
      await p.finishIntro();
      await p.finishIntro();
      expect(p.introDone, isTrue);
      expect(heard, 1);
      final again = UserProfile(store.read, store.write);
      await again.load();
      expect(again.introDone, isTrue);
      await again.resetIntro();
      expect(again.introDone, isFalse);
    });
  });

  group('authors as written with a thing', () {
    const id = '0123456789abcdef';

    test('an author is a name, with the id of the person in front of it when there is one', () {
      expect(Author.encode('Ben', id), '$id:Ben');
      expect(Author.encode('Ben', null), 'Ben');
      expect(Author.encode('', null), isNull);
      expect(Author.encode(null, null), isNull);
      expect(Author.encode('Ben', 'not an id'), 'Ben', reason: 'a bad id is left out');
      expect(Author.encode(' Ben: the 2nd ', id), '$id:Ben: the 2nd');

      final a = Author.parse('$id:Ben: the 2nd')!;
      expect(a.id, id);
      expect(a.name, 'Ben: the 2nd');
      expect(Author.parse('Ben')!.id, isNull, reason: 'from before ids');
      expect(Author.parse('Ben: the 2nd')!.name, 'Ben: the 2nd', reason: 'a colon in a name is not an id');
      expect(Author.parse(null), isNull);
    });

    test('two people with one name get the start of their id after it, and nobody else does', () {
      const other = 'fedcba9876543210';
      final labels = Author.labels(['$id:Ben', '$other:Ben', '$id:Cleo', 'Dana', null, '$other:'], unknown: 'Unknown', unnamed: 'Unnamed');
      expect(labels['$id:Ben'], 'Ben (#0123)');
      expect(labels['$other:Ben'], 'Ben (#fedc)');
      expect(labels['$id:Cleo'], 'Cleo');
      expect(labels['Dana'], 'Dana');
      expect(labels[null], 'Unknown');
      expect(labels['$other:'], 'Unnamed (#fedc)');
    });
  });
}
