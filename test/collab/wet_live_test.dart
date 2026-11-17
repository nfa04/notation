import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/collab/wet_ink.dart';
import 'package:notes/models/canvas_models.dart';

import 'flaky_network.dart';

/// Lines that others see while they are being drawn ("wet ink"), over links that are slow, drop and come back.
///
/// What a person would notice: the line of somebody else grows on the screen as it is drawn; when the pen is lifted it is a line of the
/// note like any other, the same everywhere, and nothing of the growing line is left behind; a line that was not kept goes away; and
/// nothing of a line being drawn is ever stored as a change of the note before it is finished.

void main() {
  late Directory dir;
  late LoopbackHub hub;
  late SessionInvite invite;
  late Screen hostScreen;
  late CollabSession host;
  late List<Member> members;
  late Random random;
  final staleBefore = WetBook.staleAfter, endedBefore = WetBook.endedFor;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('wetlive_');
    random = Random(7);
    hub = LoopbackHub();
    invite = SessionInvite.create('ws://localhost:1', random: Random(9));
    hostScreen = Screen(dir);
    host = CollabSession.host(invite, SlowHost(hub.host, random), hostScreen.binding, name: 'Anna', userId: uidOf(0));
    members = [];
  });

  tearDown(() async {
    WetBook.staleAfter = staleBefore;
    WetBook.endedFor = endedBefore;
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

  Future<void> settled() => waitUntil(() => members.every((m) => m.session.state == SessionState.live) && host.participants.length == members.length + 1, 'everybody is in the session');

  Future<void> joinAll(int count) async {
    for (var i = 0; i < count; i++) {
      final m = Member('Guest$i', Link(hub, random), Screen(dir));
      final welcomed = Completer<Welcome>();
      m.session = await CollabSession.join(invite, m.link, name: 'Guest$i', userId: uidOf(i + 1), onWelcome: welcomed.complete, imageSaver: m.screen.binding.saveImage);
      await waitUntil(() => host.pending.length == 1, 'the request of guest $i');
      await host.approve(host.pending.single.id);
      final w = await welcomed.future.timeout(const Duration(seconds: 5));
      m.screen.note.strokes = w.note.strokes;
      m.session.attach(m.screen.binding);
      members.add(m);
    }
    await settled();
  }

  void end(Screen screen, CollabSession session, DrawingStroke stroke, {int page = 0, bool kept = true}) {
    if (!kept) screen.note.strokes[page]!.remove(stroke);
    session.drawingEnded(stroke.id, kept: kept);
  }

  /// Somebody drawing a line by hand: the pen goes down, moves [steps] times ([every] apart), and is lifted (when [lift]).
  Future<DrawingStroke> draw(Screen screen, CollabSession session, String id, {int page = 0, int steps = 30, Duration every = const Duration(milliseconds: 8), bool lift = true, bool kept = true, double y = 0}) async {
    final stroke = DrawingStroke(id: id, color: Colors.blue, width: 3, points: [Offset(0, y)]);
    (screen.note.strokes[page] ??= []).add(stroke);
    session.drawing(page, stroke);
    for (var i = 1; i <= steps; i++) {
      stroke.points.add(Offset(i * 3.0, y + sin(i / 3) * 10));
      session.drawing(page, stroke);
      await Future<void>.delayed(every);
    }
    if (lift) end(screen, session, stroke, page: page, kept: kept);
    return stroke;
  }

  /// The points as they travel (as 32-bit numbers).
  List<Offset> sent(List<Offset> points) => [for (final p in points) Offset(Float32List.fromList([p.dx])[0], Float32List.fromList([p.dy])[0])];

  int wetPoints(CollabSession s, String id) => s.wet[id]?.stroke.points.length ?? 0;
  bool hasStroke(Screen s, String id) => s.note.strokes.values.any((l) => l.any((x) => x.id == id));
  DrawingStroke strokeOf(Screen s, String id) => s.note.strokes.values.expand((l) => l).firstWhere((x) => x.id == id);

  test('the line the host draws grows on the guests\' screens, and is a line of their note once the pen is lifted', () async {
    await joinAll(2);
    final growth = <int>[];
    void watch() => growth.add(wetPoints(members[0].session, 'h1'));
    members[0].session.wet.addListener(watch);
    final stroke = await draw(hostScreen, host, 'h1', steps: 40, lift: false);
    await waitUntil(() => wetPoints(members[0].session, 'h1') == 41 && wetPoints(members[1].session, 'h1') == 41, 'both guests see the whole line growing');
    // seen as it grew, in several steps, not only at the end
    expect(growth.toSet().length, greaterThan(3), reason: 'growth seen: $growth');
    expect(members[0].session.wet.on(0, except: members[0].session.site).single.points, sent(stroke.points));
    // nothing of it is a change of the note yet
    for (final m in members) {
      expect(hasStroke(m.screen, 'h1'), isFalse);
    }
    end(hostScreen, host, stroke);
    await waitUntil(() => members.every((m) => hasStroke(m.screen, 'h1')), 'the finished line arrives');
    for (final m in members) {
      expect(strokeOf(m.screen, 'h1').points, sent(stroke.points));
      await waitUntil(() => m.session.wet['h1'] == null, 'and its wet form is gone');
    }
    members[0].session.wet.removeListener(watch);
  });

  test('a guest\'s line reaches the host and the other guests while it is drawn (passed on by the host)', () async {
    await joinAll(3);
    final drawer = members[0];
    final stroke = await draw(drawer.screen, drawer.session, 'g1', steps: 25, lift: false);
    await waitUntil(
        () => wetPoints(host, 'g1') == 26 && members.skip(1).every((m) => wetPoints(m.session, 'g1') == 26),
        () => 'everybody sees the guest\'s line: host ${wetPoints(host, 'g1')}, ${[for (final m in members.skip(1)) wetPoints(m.session, 'g1')]}');
    expect(drawer.session.wet.on(0, except: drawer.session.site), isEmpty, reason: 'the drawer is not shown its own line twice');
    end(drawer.screen, drawer.session, stroke);
    await waitUntil(() => hasStroke(hostScreen, 'g1') && members.every((m) => hasStroke(m.screen, 'g1')), 'the finished line is everywhere');
    await waitUntil(() => host.wet.isEmpty && members.every((m) => m.session.wet.isEmpty), 'no wet ink is left anywhere');
  });

  test('a line that is not kept (a tap) goes from the other screens and never becomes a line of the note', () async {
    await joinAll(1);
    final stroke = await draw(hostScreen, host, 'tap', steps: 3, lift: false);
    await waitUntil(() => wetPoints(members[0].session, 'tap') == 4, 'the guest sees it');
    end(hostScreen, host, stroke, kept: false);
    await waitUntil(() => members[0].session.wet['tap'] == null, 'it goes at once');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(hasStroke(members[0].screen, 'tap'), isFalse);
  });

  test('many people draw at the same time: every line is seen growing and ends the same everywhere', () async {
    await joinAll(5);
    final all = <String>{};
    final drawing = <Future<DrawingStroke>>[
      for (final m in members) draw(m.screen, m.session, '${m.name}-a', steps: 20, y: 10.0 * members.indexOf(m)),
      draw(hostScreen, host, 'host-a', steps: 20),
    ];
    final strokes = await Future.wait(drawing);
    all.addAll(strokes.map((s) => s.id));
    final screens = [hostScreen, for (final m in members) m.screen];
    await waitUntil(() => screens.every((s) => all.every((id) => hasStroke(s, id))), 'every line is everywhere');
    for (final s in screens) {
      for (final id in all) {
        expect(strokeOf(s, id).points.length, 21);
      }
    }
    await waitUntil(() => host.wet.isEmpty && members.every((m) => m.session.wet.isEmpty), 'no wet ink is left');
  });

  test('on a slow link the line comes in fewer, bigger pieces, and in the end it is exactly the line', () async {
    await joinAll(2);
    final slow = members[0];
    slow.link.slowMs = 120; // (each message from this guest takes 120 ms more)
    var updates = 0;
    void count() => updates++;
    host.wet.addListener(count);
    final stroke = await draw(slow.screen, slow.session, 'slow', steps: 100, every: const Duration(milliseconds: 4), lift: false);
    await waitUntil(() => wetPoints(host, 'slow') == 101, () => 'the host gets all of it (${wetPoints(host, 'slow')})');
    expect(updates, lessThan(20), reason: '100 moves of the pen came in $updates messages');
    expect(host.wet['slow']!.stroke.points, sent(stroke.points));
    await waitUntil(() => wetPoints(members[1].session, 'slow') == 101, 'and the other guest too');
    end(slow.screen, slow.session, stroke);
    await waitUntil(() => hasStroke(hostScreen, 'slow') && hasStroke(members[1].screen, 'slow'), 'the finished line arrives');
    host.wet.removeListener(count);
  });

  test('the link of the person drawing breaks in the middle of the line: when it is back, the others get all of the line', () async {
    await joinAll(2);
    final drawer = members[0];
    final stroke = await draw(drawer.screen, drawer.session, 'cut', steps: 10, lift: false);
    await waitUntil(() => wetPoints(host, 'cut') == 11, 'the host sees the start');
    drawer.link.down = true;
    await drawer.link.cut();
    for (var i = 0; i < 30; i++) {
      stroke.points.add(Offset(100.0 + i, 50));
      drawer.session.drawing(0, stroke);
    }
    drawer.link.down = false;
    drawer.session.wake();
    await settled();
    await waitUntil(() => wetPoints(host, 'cut') == 41 && wetPoints(members[1].session, 'cut') == 41,
        () => 'the whole line arrives after the break: host ${wetPoints(host, 'cut')}, other guest ${wetPoints(members[1].session, 'cut')}');
    end(drawer.screen, drawer.session, stroke);
    await waitUntil(() => hasStroke(hostScreen, 'cut') && hasStroke(members[1].screen, 'cut'), 'and the finished line');
    expect(strokeOf(members[1].screen, 'cut').points, sent(stroke.points));
  });

  test('the person drawing goes away in the middle of a line: the others do not keep a half line on the screen', () async {
    WetBook.staleAfter = const Duration(milliseconds: 400);
    await joinAll(2);
    final drawer = members[0];
    await draw(drawer.screen, drawer.session, 'gone', steps: 10, lift: false);
    await waitUntil(() => wetPoints(members[1].session, 'gone') == 11, 'the other guest sees it');
    drawer.link
      ..down = true
      ..silent = true;
    await drawer.link.cut();
    await waitUntil(() => members[1].session.wet['gone'] == null && host.wet['gone'] == null, 'the half line goes after a while', timeout: const Duration(seconds: 5));
  });

  test('a line being drawn is not given to somebody who joins as a part of the note, but shown to them as it goes on', () async {
    await joinAll(1);
    final stroke = await draw(hostScreen, host, 'long', steps: 10, lift: false);
    final late = Member('Late', Link(hub, random), Screen(dir));
    final welcomed = Completer<Welcome>();
    late.session = await CollabSession.join(invite, late.link, name: 'Late', userId: uidOf(9), onWelcome: welcomed.complete, imageSaver: late.screen.binding.saveImage);
    await waitUntil(() => host.pending.length == 1, 'the late one asks');
    await host.approve(host.pending.single.id);
    final w = await welcomed.future.timeout(const Duration(seconds: 5));
    expect(w.note.strokes.values.expand((l) => l).where((s) => s.id == 'long'), isEmpty, reason: 'the half line is not in the note');
    late.screen.note.strokes = w.note.strokes;
    late.session.attach(late.screen.binding);
    members.add(late);
    stroke.points.add(const Offset(200, 200));
    host.drawing(0, stroke);
    await waitUntil(() => wetPoints(late.session, 'long') == 12, () => 'the late one sees the whole line growing (${wetPoints(late.session, 'long')})');
    end(hostScreen, host, stroke);
    await waitUntil(() => hasStroke(late.screen, 'long'), 'and the finished line');
  });

  for (final seed in [1, 2, 3]) {
    test('6 people draw for 25 rounds while links drop, die silently and come back: in the end every line is everywhere, once, and no wet ink is left (seed $seed)', () async {
      WetBook.staleAfter = const Duration(milliseconds: 800);
      WetBook.endedFor = const Duration(milliseconds: 600);
      final r = Random(seed);
      await joinAll(6);
      final all = <String, DrawingStroke>{};
      var n = 0;
      for (var round = 0; round < 25; round++) {
        final pending = <Future<void>>[];
        for (final m in members) {
          final x = r.nextInt(100);
          if (x < 50) {
            final id = '${m.name}-${n++}';
            pending.add(draw(m.screen, m.session, id, page: r.nextInt(3), steps: 5 + r.nextInt(20), every: Duration(milliseconds: 2 + r.nextInt(6)), y: r.nextDouble() * 300).then((s) {
              all[id] = s;
            }));
          } else if (x < 58 && !m.link.down) {
            m.link.down = true;
            await m.link.cut();
          } else if (x < 63 && !m.link.down && !m.link.silent) {
            m.link.silent = true;
          } else if (x < 80 && (m.link.down || m.link.silent)) {
            m.link.down = false;
            if (m.link.silent) {
              m.link.silent = false;
              await m.link.cut();
            }
            m.session.wake();
          } else if (x < 85) {
            m.link.slowMs = r.nextInt(80);
          }
        }
        if (r.nextBool()) {
          final id = 'host-${n++}';
          pending.add(draw(hostScreen, host, id, steps: 10).then((s) {
            all[id] = s;
          }));
        }
        if (r.nextInt(100) < 5) await hub.cut();
        await Future.wait(pending);
        await Future<void>.delayed(Duration(milliseconds: 10 + r.nextInt(40)));
      }
      for (final m in members) {
        m.link.slowMs = 0;
        if (m.link.silent) {
          m.link.silent = false;
          await m.link.cut();
        }
        m.link.down = false;
        m.session.wake();
      }
      await settled();
      final screens = {'host': hostScreen, for (final m in members) m.name: m.screen};
      String lack() => [
            for (final e in screens.entries)
              if (!all.keys.every((id) => hasStroke(e.value, id))) '${e.key} lacks ${all.keys.where((id) => !hasStroke(e.value, id)).length}',
          ].join(', ');
      await waitUntil(() => lack().isEmpty, () => 'every line is everywhere (seed $seed, ${all.length} lines): ${lack()}', timeout: const Duration(seconds: 40));
      for (final e in screens.entries) {
        final ids = [for (final l in e.value.note.strokes.values) for (final s in l) s.id];
        expect(ids.length, ids.toSet().length, reason: '${e.key}: no line twice');
        for (final id in all.keys) {
          expect(strokeOf(e.value, id).points, e.value == hostScreen && id.startsWith('host') || id.startsWith('${e.key}-') ? all[id]!.points : sent(all[id]!.points), reason: '${e.key}: $id is the line as it was drawn');
        }
      }
      await waitUntil(() => host.wet.isEmpty && members.every((m) => m.session.wet.isEmpty),
          () => 'no wet ink is left: host ${host.wet.all.map((w) => w.id).toList()}, ${[for (final m in members) m.session.wet.all.map((w) => w.id).toList()]}',
          timeout: const Duration(seconds: 10));
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
