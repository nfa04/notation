import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/models/rich_text.dart';

/// A device with a note, as in replica_test.dart, but what it sends goes through JSON (as it does over a link).
class Dev {
  final String site;
  final NoteData note = NoteData(id: 'n');
  late final Replica replica = Replica(site);
  final Directory dir;
  Map<String, Object?>? lastField;

  Dev(this.site, this.dir);

  List<CollabOp> changes() => [for (final o in replica.localChanges(note)) _wire(o)];

  static CollabOp _wire(CollabOp o) => CollabOp.fromJson(jsonDecode(jsonEncode(o.toJson())))!;

  bool take(CollabOp op) => replica.apply(
        note,
        _wire(op),
        makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
        saveImage: (id, bytes, ext) => (File('${dir.path}/$site-$id.$ext')..writeAsBytesSync(bytes)).path,
        onNoteField: (field, data) {
          lastField = data;
          Replica.applyNoteField(note, field, data);
        },
      );

  void takeAll(Iterable<CollabOp> ops) {
    for (final op in ops) {
      take(op);
    }
  }

  /// Everything of the note, for a device that has none of it.
  List<CollabOp> state() {
    replica.localChanges(note);
    return [for (final o in replica.state(note, includeDeleted: true)) _wire(o)];
  }

  TextBoxWidgetModel get box => note.textBoxes[0]!.single;
  String get text => box.controller.text;
  set text(String t) => box.controller.text = t;
  String get doc => note.documentText;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('replica_text_'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// Two devices that both have a box with [text].
  (Dev, Dev) pair(String text) {
    final a = Dev('a', dir), b = Dev('b', dir);
    a.note.textBoxes[0] = [TextBoxWidgetModel(id: 'box', position: const Offset(5, 5), initialText: text)];
    b.takeAll(a.changes());
    expect(b.text, text);
    return (a, b);
  }

  group('a text box', () {
    test('two people type in the same box at the same time: both texts are kept', () {
      final (a, b) = pair('Shopping list:\n');
      a.text = 'Shopping list:\nmilk\n';
      b.text = 'Shopping list:\neggs\n';
      final fromA = a.changes(), fromB = b.changes();
      a.takeAll(fromB);
      b.takeAll(fromA);
      expect(a.text, b.text);
      expect(a.text, contains('milk'));
      expect(a.text, contains('eggs'));
      expect(a.text, startsWith('Shopping list:\n'));
    });

    test('changes in different places of one text are all there', () {
      final (a, b) = pair('The quick brown fox jumps over the lazy dog');
      a.text = 'The very quick brown fox jumps over the lazy dog';
      b.text = 'The quick brown fox jumps over the lazy cat';
      final fromA = a.changes(), fromB = b.changes();
      a.takeAll(fromB);
      b.takeAll(fromA);
      expect(a.text, 'The very quick brown fox jumps over the lazy cat');
      expect(b.text, a.text);
    });

    test('a change that is older than what the device knows is still taken in', () {
      final (a, b) = pair('one');
      b.text = 'one two';
      final fromB = b.changes(); // b's change: a version of b's own
      // a changes the box several times: its versions are later than b's
      final fromA = <CollabOp>[];
      a.text = 'one!';
      fromA.addAll(a.changes());
      a.box.position = const Offset(50, 50);
      fromA.addAll(a.changes());
      a.text = 'one!!';
      fromA.addAll(a.changes());
      b.takeAll(fromA);
      // (b's change reaches a after a's own later ones, and twice)
      a.takeAll(fromB);
      a.takeAll(fromB);
      expect(a.text, 'one two!!');
      expect(b.text, a.text);
    });

    test('a change that arrives before the one it builds on waits for it', () {
      final (a, b) = pair('one');
      a.text = 'one!';
      final first = a.changes();
      a.text = 'one!!';
      final second = a.changes();
      b.takeAll(second); // (the first was lost on the way)
      expect(b.text, 'one'); // nothing of it shows yet
      b.takeAll(first);
      expect(b.text, 'one!!');
    });

    test('a move and a change of formatting, made at the same time by two people, are both kept', () {
      final (a, b) = pair('make this bold');
      a.box.position = const Offset(90, 90);
      b.box.controller.attributes.add(TextSpanAttribute(start: 5, end: 9, type: AttributeType.bold));
      b.text = 'make this bold!';
      final fromA = a.changes(), fromB = b.changes();
      a.takeAll(fromB);
      b.takeAll(fromA);
      for (final d in [a, b]) {
        expect(d.box.position, const Offset(90, 90));
        expect(d.text, 'make this bold!');
        expect(d.box.attributes.single.type, AttributeType.bold);
      }
    });

    test('somebody who only types does not undo the position or the formatting another gave the box', () {
      final (a, b) = pair('words');
      a.box.position = const Offset(40, 40);
      a.box.controller.attributes.add(TextSpanAttribute(start: 0, end: 5, type: AttributeType.italic));
      final fromA = a.changes();
      b.text = 'words and more'; // b has not seen a's change
      final fromB = b.changes();
      b.takeAll(fromA);
      a.takeAll(fromB);
      for (final d in [a, b]) {
        expect(d.box.position, const Offset(40, 40));
        expect(d.box.attributes.single.type, AttributeType.italic);
        expect(d.text, 'words and more');
      }
    });

    test('the later change to the box wins for position and size, whatever happens to the text', () {
      final (a, b) = pair('text');
      a.box.position = const Offset(100, 100);
      b.box.position = const Offset(200, 200);
      b.text = 'text and more';
      final fromA = a.changes(), fromB = b.changes();
      a.takeAll(fromB);
      b.takeAll(fromA);
      expect(a.box.position, b.box.position);
      expect(a.text, 'text and more');
      expect(b.text, 'text and more');
    });

    test('what was typed here and not sent yet is not lost when a change comes in', () {
      final (a, b) = pair('Hello world');
      b.text = 'Hello big world';
      final fromB = b.changes();
      a.text = 'Hello world, hi'; // typed here, the flush has not run yet
      a.takeAll(fromB);
      expect(a.text, 'Hello big world, hi');
      // and it goes out afterwards
      final fromA = a.changes();
      expect(fromA, isNotEmpty);
      b.takeAll(fromA);
      expect(b.text, 'Hello big world, hi');
    });

    test('a change that was taken in is not sent back', () {
      final (a, b) = pair('abc');
      a.text = 'abcd';
      b.takeAll(a.changes());
      expect(b.changes(), isEmpty);
      b.text = 'abcde';
      a.takeAll(b.changes());
      expect(a.changes(), isEmpty);
      expect(b.changes(), isEmpty);
    });

    test('nothing changed means nothing is sent, however often it is asked', () {
      final (a, b) = pair('abc');
      for (var i = 0; i < 5; i++) {
        expect(a.changes(), isEmpty);
        expect(b.changes(), isEmpty);
      }
    });

    test('typing one character in a long text sends a few bytes of characters, not the text', () {
      final a = Dev('a', dir);
      final long = List.generate(400, (i) => 'line number $i of a long box').join('\n');
      a.note.textBoxes[0] = [TextBoxWidgetModel(id: 'box', position: Offset.zero, initialText: long)];
      a.changes();
      a.text = '${long.substring(0, 5000)}X${long.substring(5000)}';
      final op = a.changes().single;
      expect(jsonEncode(op.data['tc']).length, lessThan(80));
    });

    test('formatting stays on its words when others write before them', () {
      final (a, b) = pair('make this bold please');
      a.box.controller.attributes.add(TextSpanAttribute(start: 5, end: 9, type: AttributeType.bold));
      b.takeAll(a.changes());
      expect(b.box.attributes.single.start, 5);
      b.text = 'Hey, make this bold please';
      a.takeAll(b.changes());
      final span = a.box.attributes.single;
      expect(a.text.substring(span.start, span.end), 'this');
      expect(a.text, 'Hey, make this bold please');
    });

    test('formatting that one person adds while another types arrives on the right words', () {
      final (a, b) = pair('one two three');
      a.box.controller.attributes.add(TextSpanAttribute(start: 4, end: 7, type: AttributeType.italic));
      b.text = 'zero one two three';
      final fromA = a.changes(), fromB = b.changes();
      a.takeAll(fromB);
      b.takeAll(fromA);
      for (final d in [a, b]) {
        expect(d.text, 'zero one two three');
        final s = d.box.attributes.single;
        expect(d.text.substring(s.start, s.end), 'two');
      }
    });

    test('the cursor stays between the same letters while others type', () {
      final (a, b) = pair('abcdef');
      a.box.controller.selection = const TextSelection.collapsed(offset: 3); // abc|def
      b.text = 'XYZabcdef';
      a.takeAll(b.changes());
      expect(a.text, 'XYZabcdef');
      expect(a.box.controller.selection.baseOffset, 6);
      expect(a.box.controller.selection.extentOffset, 6);
    });

    test('a selection of text is kept too', () {
      final (a, b) = pair('0123456789');
      a.box.controller.selection = const TextSelection(baseOffset: 2, extentOffset: 5);
      b.text = '0123456789!!';
      b.changes();
      b.text = '>>0123456789!!';
      a.takeAll(b.changes());
      final sel = a.box.controller.selection;
      expect(a.text.substring(sel.start, sel.end), '234');
    });

    test('a box that was deleted stays deleted, and one that comes back starts its text again', () {
      final (a, b) = pair('first life');
      a.note.textBoxes[0] = [];
      final deletion = a.changes();
      b.takeAll(deletion);
      expect(b.note.textBoxes[0], isEmpty);
      // a puts a box with the same id back (an undo)
      a.note.textBoxes[0] = [TextBoxWidgetModel(id: 'box', position: Offset.zero, initialText: 'second life')];
      b.takeAll(a.changes());
      expect(b.text, 'second life');
      // a late change to the old box does not bring it back or mix into the new one
      final late = Dev('c', dir);
      late.takeAll(pair('x').$1.state());
      b.text = 'second life!';
      a.takeAll(b.changes());
      expect(a.text, 'second life!');
    });

    test('a device that joins gets the text, and then takes part in the merging', () {
      final (a, b) = pair('start');
      a.text = 'start a';
      b.text = 'b start';
      final fromA = a.changes(), fromB = b.changes();
      a.takeAll(fromB);
      b.takeAll(fromA);
      final c = Dev('c', dir)..takeAll(a.state());
      expect(c.text, a.text);
      c.text = '${c.text}!';
      final fromC = c.changes();
      a.takeAll(fromC);
      b.takeAll(fromC);
      expect(a.text, c.text);
      expect(b.text, c.text);
    });

    test('a device with a state, then with the changes that were made before it: nothing happens twice', () {
      final (a, b) = pair('abc');
      final changes = <CollabOp>[];
      for (final t in ['abcd', 'abcde', 'abcdef']) {
        a.text = t;
        changes.addAll(a.changes());
      }
      final c = Dev('c', dir)..takeAll(a.state());
      c.takeAll(changes);
      c.takeAll(changes.reversed);
      expect(c.text, 'abcdef');
      b.takeAll(changes);
      expect(b.text, 'abcdef');
      expect(c.changes(), isEmpty);
    });

    test('an older device that sends the whole text replaces it, and the new ones carry on from there', () {
      final (a, b) = pair('base');
      // (what an older version sends: no characters)
      final old = CollabOp(ElementKind.box, 'box', const Version(50, 'old'), data: {
        'p': 0,
        'x': 5.0,
        'y': 5.0,
        'w': 260.0,
        'h': 0.0,
        'fs': 16.0,
        'text': 'from the old version',
        'spans': const [],
      });
      a.take(old);
      b.take(old);
      expect(a.text, 'from the old version');
      expect(b.text, 'from the old version');
      a.text = 'from the old version, and a';
      b.text = 'B: from the old version';
      final fromA = a.changes(), fromB = b.changes();
      a.takeAll(fromB);
      b.takeAll(fromA);
      expect(a.text, b.text);
      expect(a.text, 'B: from the old version, and a');
    });

    test('a change made while the owner was away replaces the text (it has no characters of its own)', () {
      final (a, _) = pair('owner text');
      final away = CollabOp(ElementKind.box, 'box', const Version(1, 'offline'), data: {
        'p': 0,
        'x': 5.0,
        'y': 5.0,
        'w': 260.0,
        'h': 0.0,
        'fs': 16.0,
        'text': 'copy text',
        'spans': const [],
      });
      // (the offline change is applied by a replica of its own, as the editor does)
      final raw = Replica('external');
      raw.apply(a.note, away, makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero), saveImage: (i, b, e) => '', onNoteField: (f, d) {});
      expect(a.text, 'copy text');
    });
  });

  group('the written document', () {
    test('two people write in the document at the same time', () {
      final a = Dev('a', dir), b = Dev('b', dir);
      a.note.documentText = '# Notes\n\nfirst paragraph\n';
      b.takeAll(a.changes());
      expect(b.doc, a.doc);
      a.note.documentText = '# Notes\n\nfirst paragraph\n\nfrom a\n';
      b.note.documentText = '# Notes, 2024\n\nfirst paragraph\n';
      final fromA = a.changes(), fromB = b.changes();
      a.takeAll(fromB);
      b.takeAll(fromA);
      expect(a.doc, b.doc);
      expect(a.doc, '# Notes, 2024\n\nfirst paragraph\n\nfrom a\n');
    });

    test('the editor is told where a place in the document went', () {
      final a = Dev('a', dir), b = Dev('b', dir);
      a.note.documentText = 'hello world';
      b.takeAll(a.changes());
      b.note.documentText = 'Well, hello world';
      a.takeAll(b.changes());
      final map = a.lastField!['_map'] as int Function(int);
      expect(map(5), 11); // after "hello"
      expect(map(0), inInclusiveRange(0, 6)); // (never out of the text)
      expect(map(11), 17);
    });

    test('formatting of the document follows its words', () {
      final a = Dev('a', dir), b = Dev('b', dir);
      a.note.documentText = 'one two three';
      a.note.documentSpans = [TextSpanAttribute(start: 4, end: 7, type: AttributeType.bold)];
      b.takeAll(a.changes());
      expect(b.note.documentSpans.single.start, 4);
      b.note.documentText = 'zero one two three';
      b.note.documentSpans = [TextSpanAttribute(start: 9, end: 12, type: AttributeType.bold)];
      a.takeAll(b.changes());
      expect(a.doc, 'zero one two three');
      final s = a.note.documentSpans.single;
      expect(a.doc.substring(s.start, s.end), 'two');
    });

    test('an old change to the document is taken in too', () {
      final a = Dev('a', dir), b = Dev('b', dir);
      a.note.documentText = 'abc';
      b.takeAll(a.changes());
      b.note.documentText = 'abc from b';
      final fromB = b.changes();
      a.note.documentText = 'abc!';
      a.changes();
      a.note.documentText = 'abc!!';
      a.changes();
      a.takeAll(fromB);
      expect(a.doc, contains('from b'));
      expect(a.doc, contains('!!'));
    });
  });

  group('whatever order, however often, however much is lost', () {
    String describe(Dev d) => '${d.text}|${[for (final s in d.box.attributes) '${s.start}-${s.end}${s.type.name}'].join(',')}';

    void run(int seed, {int devices = 3, int rounds = 80, double loss = 0.25, double twice = 0.25}) {
      final r = Random(seed);
      final ds = [for (var i = 0; i < devices; i++) Dev('d$i', dir)];
      ds[0].note.textBoxes[0] = [TextBoxWidgetModel(id: 'box', position: Offset.zero, initialText: 'The beginning of a shared text. ')];
      final first = ds[0].changes();
      for (var i = 1; i < devices; i++) {
        ds[i].takeAll(first);
      }
      final inbox = [for (var i = 0; i < devices; i++) <CollabOp>[]];
      String word() => String.fromCharCodes([for (var i = 1 + r.nextInt(5); i > 0; i--) 97 + r.nextInt(26)]);

      for (var round = 0; round < rounds; round++) {
        for (var i = 0; i < devices; i++) {
          if (r.nextInt(3) == 0) {
            final t = ds[i].text;
            final at = r.nextInt(t.length + 1);
            switch (r.nextInt(4)) {
              case 0:
                ds[i].text = '${t.substring(0, at)}${word()} ${t.substring(at)}';
              case 1:
                final to = min(t.length, at + 1 + r.nextInt(4));
                ds[i].text = t.replaceRange(at, to, '');
              case 2:
                final to = min(t.length, at + r.nextInt(6));
                ds[i].text = t.replaceRange(at, to, word());
              default:
                if (t.length > 4) {
                  final s = r.nextInt(t.length - 2);
                  ds[i].box.controller.attributes.add(TextSpanAttribute(start: s, end: min(t.length, s + 1 + r.nextInt(5)), type: AttributeType.values[r.nextInt(3)]));
                }
            }
          }
          if (r.nextInt(8) == 0) ds[i].box.position = Offset(r.nextInt(300).toDouble(), r.nextInt(300).toDouble());
          final ops = ds[i].changes();
          for (final op in ops) {
            for (var j = 0; j < devices; j++) {
              if (j == i || r.nextDouble() < loss) continue;
              inbox[j].add(op);
              if (r.nextDouble() < twice) inbox[j].add(op);
            }
          }
        }
        for (var j = 0; j < devices; j++) {
          inbox[j].shuffle(r);
          for (var k = r.nextInt(inbox[j].length + 1); k > 0; k--) {
            ds[j].take(inbox[j].removeLast());
          }
        }
      }
      for (var j = 0; j < devices; j++) {
        inbox[j].shuffle(r);
        ds[j].takeAll(inbox[j]);
      }
      // a link that was made again: everybody gets everybody's state (twice, in different orders)
      for (var pass = 0; pass < 2; pass++) {
        final states = [for (final d in ds) d.state()];
        for (var j = 0; j < devices; j++) {
          final order = [for (var i = 0; i < devices; i++) if (i != j) i]..shuffle(r);
          for (final i in order) {
            ds[j].takeAll(states[i]);
          }
        }
      }
      // (what the devices answer to the states goes out too, until nothing is left)
      for (var settle = 0; settle < 3; settle++) {
        final out = [for (final d in ds) d.changes()];
        for (var j = 0; j < devices; j++) {
          for (var i = 0; i < devices; i++) {
            if (i != j) ds[j].takeAll(out[i]);
          }
        }
      }
      for (var j = 1; j < devices; j++) {
        expect(ds[j].text, ds[0].text, reason: 'seed $seed: device $j');
        expect(describe(ds[j]), describe(ds[0]), reason: 'seed $seed: device $j (formatting)');
        expect(ds[j].box.position, ds[0].box.position, reason: 'seed $seed: position');
      }
      for (final d in ds) {
        expect(d.changes(), isEmpty, reason: 'seed $seed: nothing left to say');
      }
    }

    for (var seed = 0; seed < 20; seed++) {
      test('3 devices typing, formatting and moving (seed $seed)', () => run(seed));
    }

    test('5 devices, half of what is sent is lost', () => run(77, devices: 5, rounds: 100, loss: 0.5));
  });

  group('words stay whole: every change is taken in as it is made (as the editor does)', () {
    final token = RegExp(r'\[[A-Za-z0-9]+:\d+\]');
    for (var seed = 0; seed < 40; seed++) {
      test('5 devices type and delete words between words, changes lost, doubled and reordered (seed $seed)', () {
        final r = Random(seed);
        final ds = [for (var i = 0; i < 5; i++) Dev('d$i', dir)];
        ds[0].note.textBoxes[0] = [TextBoxWidgetModel(id: 'box', position: Offset.zero, initialText: 'START ')];
        final first = ds[0].changes();
        for (var i = 1; i < 5; i++) {
          ds[i].takeAll(first);
        }
        final expected = <String>{};
        final typed = <String, int>{};
        final inbox = [for (var i = 0; i < 5; i++) <CollabOp>[]];
        List<int> spots(String t) => [0, for (var i = 0; i < t.length; i++) if (t[i] == ' ') i + 1];
        for (var round = 0; round < 60; round++) {
          for (var i = 0; i < 5; i++) {
            final d = ds[i];
            final x = r.nextInt(100);
            if (x < 40) {
              final t = d.text;
              final at = spots(t)[r.nextInt(spots(t).length)];
              final tok = '[d$i:${typed[d.site] = (typed[d.site] ?? 0) + 1}]';
              d.text = '${t.substring(0, at)}$tok ${t.substring(at)}';
              expected.add(tok);
              d.replica.capture(d.note);
            } else if (x < 50) {
              final mine = expected.where((e) => e.startsWith('[d$i:')).toList();
              if (mine.isNotEmpty) {
                final tok = mine[r.nextInt(mine.length)];
                final t = d.text;
                final at = t.indexOf('$tok ');
                if (at >= 0) {
                  d.text = t.replaceRange(at, at + tok.length + 1, '');
                  expected.remove(tok);
                  d.replica.capture(d.note);
                }
              }
            }
            // (sent now and then: several changes go in one message)
            if (r.nextBool()) {
              for (final op in d.changes()) {
                for (var j = 0; j < 5; j++) {
                  if (j == i || r.nextDouble() < 0.25) continue;
                  inbox[j].add(op);
                  if (r.nextDouble() < 0.2) inbox[j].add(op);
                }
              }
            }
          }
          for (var j = 0; j < 5; j++) {
            inbox[j].shuffle(r);
            for (var k = r.nextInt(inbox[j].length + 1); k > 0; k--) {
              ds[j].take(inbox[j].removeLast());
            }
          }
        }
        for (var j = 0; j < 5; j++) {
          ds[j].takeAll(inbox[j]);
        }
        for (var pass = 0; pass < 2; pass++) {
          final states = [for (final d in ds) d.state()];
          for (var j = 0; j < 5; j++) {
            for (var i = 0; i < 5; i++) {
              if (i != j) ds[j].takeAll(states[i]);
            }
          }
        }
        final found = token.allMatches(ds[0].text).map((m) => m.group(0)!).toList();
        for (final d in ds) {
          expect(d.text, ds[0].text, reason: 'seed $seed: ${d.site}');
        }
        expect(found.toSet(), expected, reason: 'seed $seed: ${ds[0].text}');
        expect(found.length, expected.length, reason: 'seed $seed: a word twice in ${ds[0].text}');
        expect(ds[0].text.replaceAll(token, '').replaceAll(RegExp(r'\s+'), ' ').trim(), 'START', reason: 'seed $seed: ${ds[0].text}');
      });
    }
  });
}
