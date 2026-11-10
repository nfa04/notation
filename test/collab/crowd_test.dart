import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/transport.dart';

import 'flaky_network.dart';

/// Many people in one live session (4 to 10), with links that drop, die silently, come back, and are slow now and then.
///
/// The checks are about what a person would notice: in the end everybody is in the session again, everybody has everything that
/// anybody drew (also what was drawn while the link was down), and everybody agrees on who is there and who is looking at which page.

void main() {
  late Directory dir;
  late Random random;
  late LoopbackHub hub;
  late SessionInvite invite;
  late Screen hostScreen;
  late CollabSession host;
  late List<Member> members;
  final everything = <String>{};

  setUp(() {
    dir = Directory.systemTemp.createTempSync('crowd_');
    random = Random(2026);
    hub = LoopbackHub();
    invite = SessionInvite.create('ws://localhost:1', random: Random(9));
    hostScreen = Screen(dir);
    host = CollabSession.host(invite, SlowHost(hub.host, random), hostScreen.binding, name: 'Anna', userId: uidOf(0));
    members = [];
    everything.clear();
  });

  tearDown(() async {
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

  Future<void> settledMembers() => waitUntil(() => members.every((m) => m.session.state == SessionState.live) && host.participants.length == members.length + 1,
      () => 'everybody is in the session (${members.where((m) => m.session.state != SessionState.live).map((m) => '${m.name}:${m.session.state.name}').join(', ')}; the host sees ${host.participants.length} of ${members.length + 1})');

  /// [count] people ask to join; all of them are let in, one after the other or all at once.
  Future<void> joinAll(int count, {bool allAtOnce = false}) async {
    final fresh = <Member>[];
    final welcomes = <Future<Welcome>>[];
    Future<void> ask(int i) async {
      final m = Member('Guest$i', Link(hub, random), Screen(dir));
      final welcomed = Completer<Welcome>();
      m.session = await CollabSession.join(invite, m.link,
          name: i % 3 == 0 ? 'Sam' : 'Guest$i', // (some share a name: told apart by the id)
          userId: uidOf(members.length + fresh.length + 1),
          onWelcome: welcomed.complete,
          imageSaver: m.screen.binding.saveImage);
      welcomes.add(welcomed.future.then((w) {
        m.screen.note
          ..title = w.note.title
          ..strokes = w.note.strokes
          ..textBoxes = w.note.textBoxes
          ..images = w.note.images
          ..highlights = w.note.highlights
          ..documentText = w.note.documentText;
        m.session.attach(m.screen.binding);
        return w;
      }));
      fresh.add(m);
    }

    if (allAtOnce) {
      await Future.wait([for (var i = 0; i < count; i++) ask(i)]);
      await waitUntil(() => host.pending.length == count, 'all $count requests are seen by the host');
      await Future.wait([for (final p in List.of(host.pending)) host.approve(p.id)]);
    } else {
      for (var i = 0; i < count; i++) {
        await ask(i);
        await waitUntil(() => host.pending.length == 1, 'the request of guest $i');
        await host.approve(host.pending.single.id);
        await welcomes.last.timeout(const Duration(seconds: 5));
      }
    }
    await Future.wait(welcomes).timeout(const Duration(seconds: 10));
    members.addAll(fresh);
    await settledMembers();
  }

  /// Everybody has the same strokes, and they are [everything] drawn.
  Future<void> expectConverged([String why = '']) async {
    String lack() {
      final all = [('host', hostScreen), for (final m in members) (m.name, m.screen)];
      return [
        for (final (n, s) in all)
          if (!s.strokeIds.containsAll(everything)) '$n lacks ${everything.difference(s.strokeIds).length}',
      ].join(', ');
    }

    await waitUntil(() => lack().isEmpty, () => 'everybody has all ${everything.length} strokes $why: ${lack()}');
    for (final m in members) {
      expect(m.screen.strokeIds, everything, reason: '${m.name} has nothing extra $why');
    }
    expect(hostScreen.strokeIds, everything);
  }

  /// Everybody agrees on who is there, with nobody twice.
  Future<void> expectSameCrowd() async {
    final expected = {host.site, for (final m in members) m.session.site};
    bool same(CollabSession s) => s.participants.length == expected.length && s.participants.map((p) => p.site).toSet().containsAll(expected);
    await waitUntil(() => same(host) && members.every((m) => same(m.session)),
        () => 'everybody lists the same ${expected.length} people (${[('host', host), for (final m in members) (m.name, m.session)].where((e) => !same(e.$2)).map((e) => '${e.$1}: ${e.$2.participants.length}').join(', ')})');
    expect(host.pending, isEmpty, reason: 'nobody had to be asked again');
  }

  /// Everybody has told which page they are on, and everybody knows it of everybody.
  Future<void> expectSamePages(Map<String, int> pages) async {
    final names = {host.site: 'host', for (final m in members) m.session.site: m.name};
    List<String> wrong() => [
          for (final (who, s) in [('host', host), for (final m in members) (m.name, m.session)])
            for (final e in pages.entries)
              if (s.viewing[e.key] != e.value) '$who sees ${names[e.key]} on ${s.viewing[e.key]}, not ${e.value}',
            for (final (who, s) in [('host', host), for (final m in members) (m.name, m.session)])
              for (final k in s.viewing.keys)
                if (!pages.containsKey(k)) '$who sees ${names[k] ?? k} on a page that nobody announced',
        ];
    await waitUntil(() => wrong().isEmpty, () => 'everybody knows who is on which page: ${wrong().join('; ')}');
  }

  Future<void> everyoneBack({bool wake = true}) async {
    for (final m in members) {
      m.link
        ..down = false
        ..silent = false;
    }
    if (wake) {
      for (final m in members) {
        m.session.wake();
      }
    }
    await settledMembers();
  }

  for (final count in [4, 7, 10]) {
    test('$count people, one after the other: everything that anybody draws, at the same time, reaches everybody', () async {
      await joinAll(count);
      await expectSameCrowd();
      // everybody draws on their own page and on a shared one, three times, with no pause between
      for (var round = 0; round < 3; round++) {
        everything.add(hostScreen.draw('host', round % 2, y: 5.0 * round));
        host.localChanged();
        for (final m in members) {
          everything.add(m.draw(0, y: 30));
          everything.add(m.draw(members.indexOf(m) + 1, y: 60));
        }
        await Future<void>.delayed(Duration(milliseconds: random.nextInt(60)));
      }
      await expectConverged();
      await expectSameCrowd();
    });
  }

  test('10 people asking at the same moment, and being let in at the same moment, all get in once and get the same note', () async {
    for (var i = 0; i < 5; i++) {
      everything.add(hostScreen.draw('host', i));
    }
    host.localChanged();
    await joinAll(10, allAtOnce: true);
    await expectSameCrowd();
    await expectConverged('after joining');
    // and then all of them can draw
    for (final m in members) {
      everything.add(m.draw(0));
    }
    await expectConverged('after everybody drew');
  });

  test('who is on which page is known to all 8, also after some of them were away and came back', () async {
    await joinAll(8);
    final pages = <String, int>{host.site: 0};
    host.announcePage(0);
    for (var i = 0; i < members.length; i++) {
      members[i].session.announcePage(i + 1);
      pages[members[i].session.site] = i + 1;
    }
    await expectSamePages(pages);

    // four lose the link at the same time, and one of them moves on while away
    for (final m in members.take(4)) {
      m.link.down = true;
      await m.link.cut();
    }
    await waitUntil(() => host.participants.length == 5, 'the host sees four go');
    members[0].session.announcePage(9); // (not told: no link; told when back)
    pages[members[0].session.site] = 9;
    await everyoneBack();
    await expectSamePages(pages);
    await expectSameCrowd();
  });

  test('half of the 8 lose the link at once, the others keep drawing; when the half is back everybody has everything', () async {
    await joinAll(8);
    final away = members.take(4).toList();
    for (final m in away) {
      m.link.down = true;
      await m.link.cut();
    }
    await waitUntil(() => host.participants.length == 5, 'the host sees four go');

    for (var round = 0; round < 3; round++) {
      for (final m in members) {
        everything.add(m.draw(round)); // (the ones that are away change their note too: it goes when they are back)
      }
      everything.add(hostScreen.draw('host', 5));
      host.localChanged();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    // those who stayed have what the other stayers drew, though not what the absent ones drew
    final stayers = members.skip(4).toList();
    await waitUntil(() => stayers.every((m) => m.screen.strokeIds.containsAll({for (final s in stayers) ...s.drawn})), 'the ones that stayed see each other');

    await everyoneBack();
    await expectConverged('after the four came back');
    await expectSameCrowd();
  });

  test('a link that dies without a sound (what is sent seems sent, nothing arrives) loses nothing for 3 of 6 people', () async {
    await joinAll(6);
    for (final m in members.take(3)) {
      m.link.silent = true;
    }
    for (final m in members) {
      everything.add(m.draw(0, y: 20));
      everything.add(m.draw(1, y: 40));
    }
    everything.add(hostScreen.draw('host', 2));
    host.localChanged();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    // the silent ones have not got what the others drew, and the others have not got theirs
    expect(members.first.screen.strokeIds.length, lessThan(everything.length));

    // somebody notices: the links are cut, the apps come back to the front
    for (final m in members.take(3)) {
      m.link.silent = false;
      await m.link.cut();
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final m in members) {
      m.session.wake();
    }
    await settledMembers();
    await expectConverged('after the silent ones were cut');
    await expectSameCrowd();
  });

  test('a network that is gone for a while and comes back: every guest finds its way back without anybody doing anything', () async {
    await joinAll(8);
    for (final m in members) {
      m.link.down = true;
      await m.link.cut();
    }
    await waitUntil(() => host.participants.length == 1, 'the host sees all eight go');
    await waitUntil(() => members.every((m) => m.session.state == SessionState.reconnecting), 'all try to get back');
    for (final m in members) {
      everything.add(m.draw(0, y: 70)); // alone, offline
    }
    everything.add(hostScreen.draw('host', 0));
    host.localChanged();
    await Future<void>.delayed(const Duration(milliseconds: 1500)); // (a few failed tries: the wait between them doubles)
    for (final m in members) {
      expect(m.session.state, SessionState.reconnecting);
      m.link.down = false; // no wake(): the guests try by themselves
    }
    await waitUntil(() => members.every((m) => m.session.state == SessionState.live), 'every guest got back by itself', timeout: const Duration(seconds: 30));
    await settledMembers();
    await expectConverged('after the network came back');
    await expectSameCrowd();
  });

  test('the host loses every link at once (its network changed), 10 guests come back, nobody is listed twice', () async {
    await joinAll(10);
    for (var i = 0; i < 3; i++) {
      everything.add(members[i].draw(0));
    }
    await hub.cut();
    for (final m in members.skip(5)) {
      everything.add(m.draw(1)); // (while the links are being made again)
    }
    everything.add(hostScreen.draw('host', 2));
    host.localChanged();
    for (final m in members) {
      m.session.wake();
    }
    await settledMembers();
    await expectConverged('after the host cut every link');
    await expectSameCrowd();
    for (final m in members) {
      everything.add(m.draw(3));
    }
    await expectConverged('and still live after it');
  });

  test('somebody new comes in while four others are away; the four come back and have the note of the new one too', () async {
    await joinAll(5);
    for (final m in members.take(4)) {
      m.link.down = true;
      await m.link.cut();
    }
    await waitUntil(() => host.participants.length == 2, 'the host sees four go');
    final before = members.length;
    final m = Member('Late', Link(hub, random), Screen(dir));
    final welcomed = Completer<Welcome>();
    m.session = await CollabSession.join(invite, m.link, name: 'Late', userId: uidOf(99), onWelcome: welcomed.complete, imageSaver: m.screen.binding.saveImage);
    await waitUntil(() => host.pending.length == 1, 'the late one asks');
    await host.approve(host.pending.single.id);
    final w = await welcomed.future.timeout(const Duration(seconds: 5));
    m.screen.note
      ..strokes = w.note.strokes
      ..title = w.note.title;
    m.session.attach(m.screen.binding);
    members.add(m);
    expect(members.length, before + 1);

    everything.add(m.draw(0));
    for (final x in members.take(4)) {
      everything.add(x.draw(1)); // offline
    }
    await everyoneBack();
    await expectConverged('after everybody was back');
    await expectSameCrowd();
  });

  for (final seed in [1, 2, 3]) {
    test('9 people for 40 rounds of drawing, links dropping, dying silently and coming back at random (seed $seed)', () async {
      final r = Random(seed);
      await joinAll(9);
      host.announcePage(0);
      final pages = <String, int>{host.site: 0};
      for (var round = 0; round < 40; round++) {
        for (final m in members) {
          final x = r.nextInt(100);
          if (x < 55) {
            everything.add(m.draw(r.nextInt(4), y: r.nextDouble() * 100));
          } else if (x < 62 && !m.link.down) {
            m.link.down = true;
            await m.link.cut();
          } else if (x < 67 && !m.link.down && !m.link.silent) {
            m.link.silent = true; // dies without a sound; noticed some rounds later
          } else if (x < 85 && (m.link.down || m.link.silent)) {
            m.link.down = false;
            if (m.link.silent) {
              m.link.silent = false;
              await m.link.cut();
            }
            m.session.wake();
          } else if (x < 92) {
            final p = r.nextInt(6);
            m.session.announcePage(p);
            pages[m.session.site] = p;
          }
        }
        if (r.nextInt(100) < 50) {
          everything.add(hostScreen.draw('host', r.nextInt(4)));
          host.localChanged();
        }
        if (r.nextInt(100) < 6) await hub.cut(); // and now and then the host's side has a hiccup
        await Future<void>.delayed(Duration(milliseconds: 20 + r.nextInt(60)));
      }
      // the storm is over: whoever is still cut off or silent is let back
      for (final m in members) {
        if (m.link.silent) {
          m.link.silent = false;
          await m.link.cut();
        }
      }
      await everyoneBack();
      await expectConverged('after 40 rounds (seed $seed): ${everything.length} strokes');
      await expectSameCrowd();
      await expectSamePages(pages);
    });
  }
}
