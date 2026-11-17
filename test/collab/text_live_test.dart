import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/text_crdt.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/models/canvas_models.dart';

import 'flaky_network.dart';

/// People writing in the same text box and in the same document at the same time, over links that drop, die without a sound, come back
/// and are slow.
///
/// Everybody types little tokens like `[Guest3:7]` at the places between words and now and then deletes one of their own. At the end:
///  - everybody has exactly the same text (box and document),
///  - it holds every token that was typed and not deleted, once and whole (nobody's words are cut in two or mixed into another's),
///  - and nothing else.

final _token = RegExp(r'\[[A-Za-z0-9]+:\d+\]');

void main() {
  late Directory dir;
  late LoopbackHub hub;
  late SessionInvite invite;
  late Screen hostScreen;
  late CollabSession host;
  late List<Member> members;
  late Random random;

  /// What was typed and not deleted, for the box and for the document.
  final box = <String>{}, doc = <String>{};
  final typed = <String, int>{};

  setUp(() {
    dir = Directory.systemTemp.createTempSync('textlive_');
    random = Random(2026);
    hub = LoopbackHub();
    invite = SessionInvite.create('ws://localhost:1', random: Random(9));
    hostScreen = Screen(dir);
    hostScreen.note.textBoxes[0] = [TextBoxWidgetModel(id: 'shared', position: Offset.zero, initialText: 'START ')];
    hostScreen.note.documentText = 'DOC START ';
    host = CollabSession.host(invite, SlowHost(hub.host, random), hostScreen.binding, name: 'Anna', userId: uidOf(0));
    members = [];
    box.clear();
    doc.clear();
    typed.clear();
  });

  final collectAfter = TextCrdt.collectAfter, collectEvery = CollabSession.collectEvery;
  tearDown(() async {
    TextCrdt.collectAfter = collectAfter;
    CollabSession.collectEvery = collectEvery;
    for (final m in members) {
      m.link
        ..down = true
        ..silent = false;
      await m.session.end();
      m.session.dispose();
    }
    await host.end();
    host.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> settled() => waitUntil(() => members.every((m) => m.session.state == SessionState.live) && host.participants.length == members.length + 1,
      () => 'everybody is in the session (${members.where((m) => m.session.state != SessionState.live).map((m) => '${m.name}:${m.session.state.name}').join(', ')})');

  Future<void> joinAll(int count) async {
    for (var i = 0; i < count; i++) {
      final m = Member('Guest$i', Link(hub, random), Screen(dir));
      final welcomed = Completer<Welcome>();
      m.session = await CollabSession.join(invite, m.link, name: 'Guest$i', userId: uidOf(i + 1), onWelcome: welcomed.complete, imageSaver: m.screen.binding.saveImage);
      await waitUntil(() => host.pending.length == 1, 'the request of guest $i');
      await host.approve(host.pending.single.id);
      final w = await welcomed.future.timeout(const Duration(seconds: 5));
      m.screen.note
        ..textBoxes = w.note.textBoxes
        ..documentText = w.note.documentText;
      m.session.attach(m.screen.binding);
      members.add(m);
    }
    await settled();
  }

  Future<void> everyoneBack() async {
    for (final m in members) {
      m.link
        ..down = false
        ..silent = false;
    }
    for (final m in members) {
      m.session.wake();
    }
    await settled();
  }

  TextBoxWidgetModel boxOf(Screen s) => s.note.textBoxes[0]!.single;

  /// The places between words (and the ends) of [t].
  List<int> spots(String t) => [0, for (var i = 0; i < t.length; i++) if (t[i] == ' ') i + 1];

  void type(String who, Screen s, CollabSession session, Random r, {bool document = false}) {
    final token = '[$who:${typed[who] = (typed[who] ?? 0) + 1}]';
    if (document) {
      final t = s.note.documentText;
      final at = spots(t)[r.nextInt(spots(t).length)];
      s.note.documentText = '${t.substring(0, at)}$token ${t.substring(at)}';
      doc.add(token);
    } else {
      final b = boxOf(s);
      final t = b.controller.text;
      final at = spots(t)[r.nextInt(spots(t).length)];
      b.controller.text = '${t.substring(0, at)}$token ${t.substring(at)}';
      box.add(token);
    }
    session.localChanged();
  }

  /// Deletes one token this person typed (if it is still in their text).
  void deleteOne(String who, Screen s, CollabSession session, Random r, {bool document = false}) {
    final mine = (document ? doc : box).where((t) => t.startsWith('[$who:')).toList();
    if (mine.isEmpty) return;
    final token = mine[r.nextInt(mine.length)];
    final text = document ? s.note.documentText : boxOf(s).controller.text;
    final at = text.indexOf('$token ');
    if (at < 0) return; // (not here yet: it was typed on this device, so it always is; unless it was never sent back)
    final cut = text.replaceRange(at, at + token.length + 1, '');
    if (document) {
      s.note.documentText = cut;
      doc.remove(token);
    } else {
      boxOf(s).controller.text = cut;
      box.remove(token);
    }
    session.localChanged();
  }

  String why(String name, String text, Set<String> expected) {
    final found = _token.allMatches(text).map((m) => m.group(0)!).toList();
    final missing = expected.difference(found.toSet());
    final extra = found.toSet().difference(expected);
    final twice = {for (final t in found) if (found.where((x) => x == t).length > 1) t};
    final rest = text.replaceAll(_token, '').replaceAll(RegExp(r'\s+'), ' ').trim();
    return '$name: missing ${missing.length} $missing, extra ${extra.length} $extra, twice $twice, rest "$rest"';
  }

  bool right(String text, Set<String> expected, String start) {
    final found = _token.allMatches(text).map((m) => m.group(0)!).toList();
    if (found.length != expected.length || !found.toSet().containsAll(expected)) return false;
    return text.replaceAll(_token, '').replaceAll(RegExp(r'\s+'), ' ').trim() == start;
  }

  String boxText(Screen s) => boxOf(s).controller.text;

  /// Everybody has the same text, made of exactly what was typed.
  Future<void> expectConverged([String when = '']) async {
    final all = [('host', hostScreen), for (final m in members) (m.name, m.screen)];
    bool ok() =>
        all.every((e) => boxText(e.$2) == boxText(hostScreen) && e.$2.note.documentText == hostScreen.note.documentText) &&
        right(boxText(hostScreen), box, 'START') &&
        right(hostScreen.note.documentText, doc, 'DOC START');
    String detail() => [
          why('host box', boxText(hostScreen), box),
          why('host doc', hostScreen.note.documentText, doc),
          for (final e in all)
            if (boxText(e.$2) != boxText(hostScreen)) '${e.$1}\'s box differs: ${why(e.$1, boxText(e.$2), box)}',
          for (final e in all)
            if (e.$2.note.documentText != hostScreen.note.documentText) '${e.$1}\'s document differs: ${why(e.$1, e.$2.note.documentText, doc)}',
        ].join('\n');
    await waitUntil(ok, () => 'everybody has the same text, made of what was typed $when\n${detail()}', timeout: const Duration(seconds: 40));
  }

  test('8 people type into one box at the same moment: everybody ends with the same text with every word', () async {
    await joinAll(8);
    for (var round = 0; round < 12; round++) {
      for (final m in members) {
        type(m.name, m.screen, m.session, random);
      }
      type('host', hostScreen, host, random);
      await Future<void>.delayed(Duration(milliseconds: random.nextInt(50)));
    }
    await expectConverged();
  });

  test('the box and the document are written at the same time by everybody', () async {
    await joinAll(5);
    for (var round = 0; round < 15; round++) {
      for (final m in members) {
        type(m.name, m.screen, m.session, random, document: random.nextBool());
      }
      type('host', hostScreen, host, random, document: round.isEven);
      await Future<void>.delayed(Duration(milliseconds: random.nextInt(40)));
    }
    await expectConverged();
  });

  test('two people write into the same place of the box while a third is away; the third comes back and has it all, and adds its own', () async {
    await joinAll(3);
    final away = members.last;
    away.link.down = true;
    await away.link.cut();
    await waitUntil(() => host.participants.length == 3, 'the host sees one go');
    for (var i = 0; i < 6; i++) {
      type(members[0].name, members[0].screen, members[0].session, random);
      type(members[1].name, members[1].screen, members[1].session, random);
      type(away.name, away.screen, away.session, random); // (alone: nobody gets it until it is back)
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await everyoneBack();
    await expectConverged('after the third came back');
    // and it goes on
    type(away.name, away.screen, away.session, random);
    await expectConverged('and still live');
  });

  test('a guest that was away for a long time and wrote a lot, and an equally long time of writing by the others: nothing is lost on either side', () async {
    await joinAll(4);
    final away = members.take(2).toList();
    for (final m in away) {
      m.link.down = true;
      await m.link.cut();
    }
    await waitUntil(() => host.participants.length == 3, 'the host sees two go');
    for (var round = 0; round < 25; round++) {
      for (final m in members) {
        type(m.name, m.screen, m.session, random, document: round % 3 == 0);
      }
      type('host', hostScreen, host, random);
      if (round % 4 == 0) deleteOne(members.last.name, members.last.screen, members.last.session, random);
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    await everyoneBack();
    await expectConverged('after the long time away');
  });

  test('links die without a sound while people type: what was typed in the silence reaches everybody', () async {
    await joinAll(6);
    for (final m in members.take(3)) {
      m.link.silent = true;
    }
    for (var i = 0; i < 4; i++) {
      for (final m in members) {
        type(m.name, m.screen, m.session, random);
      }
      type('host', hostScreen, host, random);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    for (final m in members.take(3)) {
      m.link.silent = false;
      await m.link.cut();
    }
    for (final m in members) {
      m.session.wake();
    }
    await settled();
    await expectConverged('after the silent ones were cut');
  });

  test('the host loses every link at once while 8 people are typing', () async {
    await joinAll(8);
    for (var round = 0; round < 6; round++) {
      for (final m in members) {
        type(m.name, m.screen, m.session, random);
      }
      if (round == 2) await hub.cut();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    for (final m in members) {
      m.session.wake();
    }
    await settled();
    await expectConverged('after the host cut every link');
  });

  test('a guest whose app was closed and opened again (a new session) gets the text of the others and its own words are not doubled', () async {
    await joinAll(2);
    type(members[0].name, members[0].screen, members[0].session, random);
    type(members[1].name, members[1].screen, members[1].session, random);
    await expectConverged();
    // (the second guest's device restarts: it has the note as saved, and joins again)
    final old = members[1];
    old.link.down = true;
    await old.link.cut();
    await old.session.end();
    old.session.dispose();
    members.removeLast();
    await waitUntil(() => host.participants.length == 2, 'the host sees it go');
    type(members[0].name, members[0].screen, members[0].session, random);
    final back = Member('Guest1', Link(hub, random), Screen(dir));
    final welcomed = Completer<Welcome>();
    back.session = await CollabSession.join(invite, back.link, name: 'Guest1', userId: uidOf(2), onWelcome: welcomed.complete, imageSaver: back.screen.binding.saveImage);
    await waitUntil(() => host.pending.length == 1, 'it asks again');
    await host.approve(host.pending.single.id);
    final w = await welcomed.future.timeout(const Duration(seconds: 5));
    back.screen.note
      ..textBoxes = w.note.textBoxes
      ..documentText = w.note.documentText;
    back.session.attach(back.screen.binding);
    members.add(back);
    await settled();
    type(back.name, back.screen, back.session, random);
    await expectConverged('after the restart');
  });

  for (final seed in [1, 2, 3, 4]) {
    test('7 people write into the box and the document for 40 rounds, links dropping, dying silently and coming back at random (seed $seed)', () async {
      final r = Random(seed);
      await joinAll(7);
      for (var round = 0; round < 40; round++) {
        for (final m in members) {
          final x = r.nextInt(100);
          if (x < 50) {
            type(m.name, m.screen, m.session, r, document: r.nextInt(3) == 0);
          } else if (x < 58) {
            deleteOne(m.name, m.screen, m.session, r, document: r.nextBool());
          } else if (x < 64 && !m.link.down) {
            m.link.down = true;
            await m.link.cut();
          } else if (x < 69 && !m.link.down && !m.link.silent) {
            m.link.silent = true;
          } else if (x < 86 && (m.link.down || m.link.silent)) {
            m.link.down = false;
            if (m.link.silent) {
              m.link.silent = false;
              await m.link.cut();
            }
            m.session.wake();
          }
        }
        if (r.nextInt(100) < 50) type('host', hostScreen, host, r, document: r.nextBool());
        if (r.nextInt(100) < 6) await hub.cut();
        await Future<void>.delayed(Duration(milliseconds: 15 + r.nextInt(50)));
      }
      for (final m in members) {
        if (m.link.silent) {
          m.link.silent = false;
          await m.link.cut();
        }
      }
      await everyoneBack();
      await expectConverged('after 40 rounds (seed $seed): ${box.length} words in the box, ${doc.length} in the document');
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  group('what was deleted is collected while people write', () {
    for (final seed in [11, 12, 13]) {
      test('6 people write and delete, links dropping and coming back (seed $seed)', () async {
        TextCrdt.collectAfter = 12;
        CollabSession.collectEvery = const Duration(milliseconds: 40);
        final r = Random(seed);
        await joinAll(5);
        var collected = 0;
        for (var round = 0; round < 40; round++) {
          for (final m in members) {
            final x = r.nextInt(100);
            if (x < 40) {
              type(m.name, m.screen, m.session, r, document: r.nextInt(3) == 0);
            } else if (x < 60) {
              deleteOne(m.name, m.screen, m.session, r, document: r.nextBool());
            } else if (x < 64 && !m.link.down) {
              m.link.down = true;
              await m.link.cut();
            } else if (x < 80 && m.link.down) {
              m.link.down = false;
              m.session.wake();
            }
          }
          if (r.nextInt(100) < 40) type('host', hostScreen, host, r, document: r.nextBool());
          if (r.nextInt(100) < 25) deleteOne('host', hostScreen, host, r, document: r.nextBool());
          // now and then nobody types for a moment (so that everybody can be at the same point)
          await Future<void>.delayed(Duration(milliseconds: round % 8 == 7 ? 400 : 15 + r.nextInt(40)));
          collected = host.replica.textCollections;
        }
        await everyoneBack();
        await expectConverged('after 40 rounds (seed $seed)');
        expect(collected, greaterThan(0), reason: 'the host collected while they wrote');
        // and, once all is quiet, everything that is deleted is collected everywhere
        TextCrdt.collectAfter = 1;
        final all = [host, for (final m in members) m.session];
        await waitUntil(() => all.every((s) => s.replica.deletedInTexts == 0),
            () => 'no deleted characters left: ${[for (final s in all) s.replica.deletedInTexts]}', timeout: const Duration(seconds: 20));
        await expectConverged('after the last collection');
        // and it goes on
        for (final m in members) {
          type(m.name, m.screen, m.session, r);
        }
        deleteOne('host', hostScreen, host, r);
        await expectConverged('writing after the collection');
      }, timeout: const Timeout(Duration(minutes: 3)));
    }
  });

  group('devices of an older version of the app (whole texts only)', () {
    /// [m] becomes an app of the older version: it says so when it joins again.
    Future<void> makeOld(Member m) async {
      m.session.replica.mergesTexts = false;
      m.link.down = true;
      await m.link.cut();
      await waitUntil(() => host.participants.length == members.length, 'the host sees it go');
      m.link.down = false;
      m.session.wake();
      await settled();
    }

    test('a guest of the older version writes with guests of the newer one: nobody loses words, nobody gets lines being drawn', () async {
      await joinAll(4);
      final old = members[0];
      await makeOld(old);
      expect(old.session.replica.wholeTexts, isTrue);
      expect(members[1].session.replica.wholeTexts, isFalse, reason: 'the newer ones send no whole texts: the host gives them to the old one');
      for (var round = 0; round < 10; round++) {
        for (final m in members.skip(1)) {
          type(m.name, m.screen, m.session, random, document: round.isOdd);
        }
        type('host', hostScreen, host, random);
        // (an app of the older version sends at once what it has: it would lose its own words to a text that comes meanwhile anyway)
        type(old.name, old.screen, old.session, random, document: round % 3 == 0);
        old.session.flush();
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      await expectConverged('with an app of the older version');
      // a line drawn by a newer one is seen growing by the newer ones only
      members[1].session.drawing(0, DrawingStroke(id: 'wet1', color: const Color(0xff000000), width: 3, points: const [Offset(1, 1), Offset(5, 5)]));
      await waitUntil(() => members[2].session.wet.on(0).isNotEmpty, 'the newer ones see the line growing');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(old.session.wet.on(0), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a host of the older version: the newer guests do as it does, and the text is the same everywhere', () async {
      host.replica
        ..mergesTexts = false
        ..wholeTexts = true;
      await joinAll(3);
      for (final m in members) {
        expect(m.session.replica.mergesTexts, isFalse);
      }
      // (whole texts: the last change wins, so one person at a time)
      for (var round = 0; round < 4; round++) {
        for (final (name, screen, session) in [('host', hostScreen, host), for (final m in members) (m.name, m.screen, m.session)]) {
          type(name, screen, session, random, document: round.isOdd);
          await expectConverged('after $name wrote');
        }
      }
    });
  });
}
