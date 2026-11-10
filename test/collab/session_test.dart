import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/pdf/pdf_pages.dart';

DrawingStroke line(double y) => DrawingStroke(color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, y + i)]);

/// A note on one device, as an editor would hold it.
class Screen {
  final NoteData note = NoteData(id: 'n');
  int redraws = 0;

  /// What others did to the pages of the PDF, and the PDFs they sent in its place.
  final List<PageArrangement> arrangements = [];
  final List<SharedPdf> pdfs = [];
  late final CollabBinding binding;
  Screen(Directory dir, {SharedPdf? pdf}) {
    binding = CollabBinding(
      note: () => note,
      change: (f) {
        f();
        redraws++;
      },
      makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
      saveImage: (id, bytes, ext) => (File('${dir.path}/$id.$ext')..writeAsBytesSync(bytes)).path,
      onNoteField: (f, d) => Replica.applyNoteField(note, f, d),
      pdf: pdf == null ? null : () async => pdf,
      onPages: (a) async => arrangements.add(a),
      onPdf: (f) async => pdfs.add(f),
    );
  }
}

Future<void> settle() async {
  // sealing and delivery take several turns of the event loop
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory dir;
  late LoopbackHub hub;
  late SessionInvite invite;
  late Screen hostScreen;
  late CollabSession host;
  final toClose = <CollabSession>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('session_');
    hub = LoopbackHub();
    invite = SessionInvite.create('ws://localhost:1', random: Random(9));
    hostScreen = Screen(dir);
    host = CollabSession.host(invite, hub.host, hostScreen.binding, name: 'Anna');
    toClose
      ..clear()
      ..add(host);
  });
  tearDown(() async {
    for (final s in toClose) {
      await s.end();
      s.dispose();
    }
    dir.deleteSync(recursive: true);
  });

  Future<(CollabSession, Screen, Completer<Welcome>)> join({String name = 'Ben', SessionInvite? with_}) async {
    final screen = Screen(dir);
    final welcomed = Completer<Welcome>();
    final s = await CollabSession.join(with_ ?? invite, hub.guest,
        name: name, onWelcome: welcomed.complete, imageSaver: screen.binding.saveImage);
    toClose.add(s);
    return (s, screen, welcomed);
  }

  Future<(CollabSession, Screen)> joinAndApprove({String name = 'Ben'}) async {
    final (s, screen, welcomed) = await join(name: name);
    await settle();
    await host.approve(host.pending.single.id);
    final w = await welcomed.future.timeout(const Duration(seconds: 2));
    // the guest's screen takes the note over, as the editor does after making a note of it
    screen.note
      ..title = w.note.title
      ..strokes = w.note.strokes
      ..textBoxes = w.note.textBoxes
      ..images = w.note.images
      ..highlights = w.note.highlights
      ..documentText = w.note.documentText;
    s.attach(screen.binding);
    await settle();
    return (s, screen);
  }

  test('who has which page in view is told to everyone, also to a guest who comes later', () async {
    final (ben, _) = await joinAndApprove(name: 'Ben');
    host.announcePage(2);
    ben.announcePage(5);
    await settle();
    expect(host.viewing[host.site], 2);
    expect(host.viewing[ben.site], 5);
    expect(ben.viewing[host.site], 2);
    expect(ben.viewing[ben.site], 5);

    final (cy, _) = await joinAndApprove(name: 'Cy');
    await settle();
    expect(cy.viewing[host.site], 2); // (told on arrival)
    expect(cy.viewing[ben.site], 5);
    cy.announcePage(0);
    await settle();
    expect(ben.viewing[cy.site], 0);

    await cy.end();
    await settle();
    expect(host.viewing.containsKey(cy.site), isFalse); // gone with the person
  });

  test('which sheet of a long written document someone is on goes with the page, also to a guest who comes later', () async {
    final (ben, _) = await joinAndApprove(name: 'Ben');
    ben.announcePage(0, sheet: 2);
    await settle();
    expect(host.viewing[ben.site], 0);
    expect(host.viewingSheet[ben.site], 2);

    final (cy, _) = await joinAndApprove(name: 'Cy');
    await settle();
    expect(cy.viewingSheet[ben.site], 2); // (told on arrival)

    ben.announcePage(0); // back on the first sheet: the page is the same, the sheet is news
    await settle();
    expect(host.viewingSheet[ben.site], 0);
    expect(cy.viewingSheet[ben.site], 0);
  });

  test('a guest asks, the host sees who and a code, and says yes; the guest gets the note', () async {
    hostScreen.note
      ..title = 'Group study'
      ..strokes[0] = [line(10)];
    host.replica.localChanges(hostScreen.note);

    final (guest, _, welcomed) = await join(name: 'Ben');
    await settle();
    expect(host.pending.single.name, 'Ben');
    expect(guest.state, SessionState.waiting);
    expect(guest.verificationCode, host.pending.single.code); // the same on both screens
    expect(guest.verificationCode, matches(RegExp(r'^\d{3} \d{3}$')));
    expect(welcomed.isCompleted, isFalse); // nothing is given before the host says yes

    await host.approve(host.pending.single.id);
    final w = await welcomed.future.timeout(const Duration(seconds: 2));
    expect(w.note.title, 'Group study');
    expect(w.note.strokes[0]!.single.id, hostScreen.note.strokes[0]!.single.id);
    expect(guest.state, SessionState.live);
    expect(host.pending, isEmpty);
    expect(host.participants.map((p) => p.name), ['Anna', 'Ben']);
    expect(guest.participants.map((p) => p.name), ['Anna', 'Ben']);
  });

  test('the host can say no, and the guest is told', () async {
    final (guest, _, welcomed) = await join();
    await settle();
    await host.deny(host.pending.single.id);
    await settle();
    expect(guest.state, SessionState.ended);
    expect(guest.endReason, contains('did not accept'));
    expect(welcomed.isCompleted, isFalse);
    expect(host.participants.length, 1);
  });

  test('what one draws shows on the other, both ways, and goes through the host to a third', () async {
    final (ben, benScreen) = await joinAndApprove(name: 'Ben');
    final (cleo, cleoScreen) = await joinAndApprove(name: 'Cleo');
    expect(host.participants.length, 3);

    hostScreen.note.strokes[0] = [line(10)];
    host.localChanged();
    await settle();
    expect(benScreen.note.strokes[0]!.single.id, hostScreen.note.strokes[0]!.single.id);
    expect(cleoScreen.note.strokes[0]!.length, 1);

    benScreen.note.strokes[0]!.add(line(50)); // Ben draws: Anna and Cleo see it
    ben.localChanged();
    await settle();
    expect(hostScreen.note.strokes[0]!.length, 2);
    expect(cleoScreen.note.strokes[0]!.length, 2);
    expect(cleoScreen.redraws, greaterThan(0)); // the screen was told

    cleoScreen.note.title = 'Renamed';
    cleo.localChanged();
    await settle();
    expect(hostScreen.note.title, 'Renamed');
    expect(benScreen.note.title, 'Renamed');
  });

  test('people with the same name are told apart by their id, which goes with the request and the list of who is there', () async {
    const anna = '1111111111111111', ben1 = '2222222222222222', ben2 = '3333333333333333';
    final h = CollabSession.host(SessionInvite.create('ws://localhost:1', random: Random(4)), LoopbackHub().host, hostScreen.binding, name: 'Anna', userId: anna);
    toClose.add(h);
    expect(h.participants.single.uid, anna);

    // (own hub and invite: the guests have to find this host)
    final hub2 = LoopbackHub();
    final invite2 = SessionInvite.create('ws://localhost:1', random: Random(5));
    final host2 = CollabSession.host(invite2, hub2.host, hostScreen.binding, name: 'Anna', userId: anna);
    toClose.add(host2);
    final first = await CollabSession.join(invite2, hub2.guest, name: 'Ben', userId: ben1);
    toClose.add(first);
    await settle();
    expect(host2.pending.single.name, 'Ben');
    expect(host2.pending.single.uid, ben1, reason: 'the host sees whose request it is');
    await host2.approve(host2.pending.single.id);
    final second = await CollabSession.join(invite2, hub2.guest, name: 'Ben', userId: ben2);
    toClose.add(second);
    await settle();
    await host2.approve(host2.pending.single.id);
    await settle();

    final all = host2.participants;
    expect(all.map((p) => p.uid), [anna, ben1, ben2]);
    expect(first.participants.map((p) => p.uid), [anna, ben1, ben2], reason: 'the guests are told too');
    expect([for (final p in all) Participant.labelOf(p, all)], ['Anna', 'Ben (#2222)', 'Ben (#3333)']);
    expect(Participant.labelOf(all[0], [all[0], all[1]]), 'Anna');
    expect(Participant.labelOf(all[1], [all[0], all[1]]), 'Ben', reason: 'only one Ben: no need');
  });

  test('a request with a bad id is let in without one, and an old guest without an id still works', () async {
    final (_, _) = await joinAndApprove(name: 'Ben'); // (no id at all)
    expect(host.participants.last.uid, isNull);
    final hub2 = LoopbackHub();
    final invite2 = SessionInvite.create('ws://localhost:1', random: Random(6));
    final host2 = CollabSession.host(invite2, hub2.host, hostScreen.binding, name: 'Anna');
    toClose.add(host2);
    final guest = await CollabSession.join(invite2, hub2.guest, name: 'Cleo', userId: 'not an id');
    toClose.add(guest);
    await settle();
    expect(host2.pending.single.uid, isNull, reason: 'what is not an id is not taken for one');
  });

  test('who made what goes along: with the welcome, with later changes, and through the host to a third', () async {
    DrawingStroke by(String id, double y, String? who) =>
        DrawingStroke(id: id, color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, y + i)], author: who);
    hostScreen.note
      ..strokes[0] = [by('a1', 10, 'Anna'), by('a0', 30, null)]
      ..textBoxes[0] = [TextBoxWidgetModel(id: 'ab', position: const Offset(5, 50), initialText: 'hi', author: 'Anna')];
    host.localChanged();
    await settle();

    final (ben, benScreen) = await joinAndApprove(name: 'Ben');
    final (cleo, cleoScreen) = await joinAndApprove(name: 'Cleo');
    Map<String, String?> who(NoteData n) => {
          for (final l in n.strokes.values) for (final x in l) 'stroke:${x.id}': x.author,
          for (final l in n.textBoxes.values) for (final b in l) 'box:${b.id}': b.author,
        };
    expect(who(benScreen.note), {'stroke:a1': 'Anna', 'stroke:a0': null, 'box:ab': 'Anna'}, reason: 'in the welcome');

    // Ben draws and writes: Anna and Cleo see Ben's name on it
    benScreen.note.strokes[1] = [by('b1', 70, 'Ben')];
    benScreen.note.textBoxes[0]!.add(TextBoxWidgetModel(id: 'bb', position: const Offset(5, 90), initialText: 'yo', author: 'Ben'));
    ben.localChanged();
    await settle();
    expect(who(hostScreen.note)['stroke:b1'], 'Ben');
    expect(who(hostScreen.note)['box:bb'], 'Ben');
    expect(who(cleoScreen.note)['stroke:b1'], 'Ben', reason: 'through the host');
    expect(who(cleoScreen.note)['box:bb'], 'Ben');

    // Cleo changes Anna's text box: it stays Anna's
    cleoScreen.note.textBoxes[0]!.firstWhere((b) => b.id == 'ab').controller.text = 'hi there';
    cleo.localChanged();
    await settle();
    expect(hostScreen.note.textBoxes[0]!.firstWhere((b) => b.id == 'ab').controller.text, 'hi there');
    expect(who(hostScreen.note)['box:ab'], 'Anna');
    expect(who(benScreen.note)['box:ab'], 'Anna');
  });

  test('nothing bounces back and forth: after the dust settles, no more messages are sent', () async {
    final (ben, benScreen) = await joinAndApprove();
    benScreen.note.strokes[0] = [line(5)];
    ben.localChanged();
    await settle();
    final before = hub.sent;
    await settle();
    expect(hub.sent, before);
    expect(hostScreen.note.strokes[0]!.length, 1);
  });

  test('a picture and a text box travel too, and a deletion is deleted everywhere', () async {
    final (ben, benScreen) = await joinAndApprove();
    final pic = File('${dir.path}/orig.png')..writeAsBytesSync([1, 2, 3]);
    hostScreen.note.textBoxes[0] = [TextBoxWidgetModel(id: 'b1', position: const Offset(5, 5), initialText: 'hello')];
    host.localChanged();
    await settle();
    expect(benScreen.note.textBoxes[0]!.single.controller.text, 'hello');

    benScreen.note.textBoxes[0]!.single.controller.text = 'hello Anna';
    ben.localChanged();
    await settle();
    expect(hostScreen.note.textBoxes[0]!.single.controller.text, 'hello Anna');

    hostScreen.note.textBoxes[0]!.clear();
    host.localChanged();
    await settle();
    expect(benScreen.note.textBoxes[0], isEmpty);
    expect(pic.existsSync(), isTrue);
  });

  test('a PDF goes along with the welcome', () async {
    final screen = Screen(dir, pdf: SharedPdf('slides.pdf', 'abc', 12, Uint8List.fromList([37, 80, 68, 70])));
    final h2 = CollabSession.host(SessionInvite.create('ws://x', random: Random(3)), (hub = LoopbackHub()).host, screen.binding, name: 'Anna');
    toClose.add(h2);
    final welcomed = Completer<Welcome>();
    final inv = SessionInvite.create('ws://x', random: Random(3));
    toClose.add(await CollabSession.join(inv, hub.guest, onWelcome: welcomed.complete, imageSaver: screen.binding.saveImage));
    await settle();
    await h2.approve(h2.pending.single.id);
    final w = await welcomed.future.timeout(const Duration(seconds: 2));
    expect((w.pdf!.name, w.pdf!.pages), ('slides.pdf', 12));
    expect(w.pdf!.bytes, [37, 80, 68, 70]);
  });

  test('someone with another secret is not let near: nothing is shown to the host, nothing is sent back', () async {
    final stranger = SessionInvite.create('ws://localhost:1', random: Random(77));
    final (guest, _, welcomed) = await join(with_: stranger);
    await settle();
    expect(host.pending, isEmpty);
    expect(guest.state, SessionState.ended); // the host drops a link that does not speak with the session's key
    expect(welcomed.isCompleted, isFalse);
    expect(host.participants.length, 1);
  });

  test('when the host ends the session the guests are told, and the notes stay as they are', () async {
    final (ben, benScreen) = await joinAndApprove();
    hostScreen.note.strokes[0] = [line(10)];
    host.localChanged();
    await settle();
    await host.end();
    await settle();
    expect(host.state, SessionState.ended);
    expect(ben.state, SessionState.ended);
    expect(ben.endReason, contains('host ended'));
    expect(benScreen.note.strokes[0]!.length, 1);
    // changes made after that go nowhere, and do no harm
    benScreen.note.strokes[0]!.add(line(60));
    ben.localChanged();
    await settle();
    expect(hostScreen.note.strokes[0]!.length, 1);
  });

  test('a guest that leaves is taken off the list, and the others are told', () async {
    final (ben, _) = await joinAndApprove(name: 'Ben');
    final (cleo, _) = await joinAndApprove(name: 'Cleo');
    await ben.end();
    await settle();
    expect(host.participants.map((p) => p.name), ['Anna', 'Cleo']);
    expect(cleo.participants.map((p) => p.name), ['Anna', 'Cleo']);
  });

  test('joining where nobody hosts fails clearly', () async {
    final lonely = LoopbackHub();
    await expectLater(CollabSession.join(invite, lonely.guest), throwsStateError);
  });

  test('changes made while a guest was being let in are not lost', () async {
    final (guest, screen, welcomed) = await join();
    await settle();
    hostScreen.note.strokes[0] = [line(1)];
    final approving = host.approve(host.pending.single.id);
    hostScreen.note.strokes[0]!.add(line(2)); // drawn while the welcome is on its way
    host.localChanged();
    await approving;
    final w = await welcomed.future.timeout(const Duration(seconds: 2));
    screen.note.strokes = w.note.strokes;
    guest.attach(screen.binding);
    await settle();
    expect(screen.note.strokes[0]!.length, 2);
  });

  test('changes that arrive between the welcome and the screen taking over are not lost', () async {
    hostScreen.note.strokes[0] = [line(1)];
    host.replica.localChanges(hostScreen.note);
    final (guest, screen, welcomed) = await join();
    await settle();
    await host.approve(host.pending.single.id);
    final w = await welcomed.future.timeout(const Duration(seconds: 2));
    // the note on the screen is made from the welcome (as the editor loads it from the database)...
    screen.note.strokes = {
      0: [DrawingStroke(id: w.note.strokes[0]!.single.id, color: Colors.black, width: 3, points: List.of(w.note.strokes[0]!.single.points))],
    };
    // ...and meanwhile the host draws more and erases the first stroke
    hostScreen.note.strokes[0]!.add(line(50));
    hostScreen.note.strokes[0]!.removeAt(0);
    host.localChanged();
    await settle();
    expect(screen.note.strokes[0]!.length, 1); // not yet: the screen is not attached
    guest.attach(screen.binding);
    await settle();
    expect(screen.note.strokes[0]!.length, 1);
    expect(screen.note.strokes[0]!.single.points.first.dy, 50); // the erased one is gone, the new one is there
    // and it goes on working both ways
    screen.note.strokes[0]!.add(line(90));
    guest.localChanged();
    await settle();
    expect(hostScreen.note.strokes[0]!.length, 2);
  });

  test('with the screen gone the session goes on, keeps the note up to date, and a screen can take over again', () async {
    final (ben, benScreen) = await joinAndApprove();
    benScreen.note.strokes[0] = [line(5)];
    ben.localChanged();
    await settle();

    // the person leaves the note: what was saved is what the session holds from now on
    final saved = NoteData(id: 'n', title: benScreen.note.title)
      ..strokes = {
        0: [for (final s in benScreen.note.strokes[0]!) DrawingStroke(id: s.id, color: s.color, width: s.width, points: List.of(s.points))],
      };
    ben.detach(saved);
    expect(ben.hasScreen, isFalse);
    var kept = 0;
    ben.onHeadlessChanged = (_) => kept++;

    hostScreen.note.strokes[0]!.add(line(70));
    host.localChanged();
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(saved.strokes[0]!.length, 2); // taken in without a screen
    expect(kept, greaterThan(0)); // and the owner was told to keep it
    expect(ben.state, SessionState.live);

    // the note is opened again: a screen loads what was saved earlier, and catches up
    final again = Screen(dir);
    again.note.strokes = {0: [DrawingStroke(id: saved.strokes[0]!.first.id, color: Colors.black, width: 3, points: List.of(saved.strokes[0]!.first.points))]};
    ben.attach(again.binding);
    await settle();
    expect(again.note.strokes[0]!.length, 2);
    // and the host can still be reached from it
    again.note.strokes[0]!.add(line(99));
    ben.localChanged();
    await settle();
    expect(hostScreen.note.strokes[0]!.length, 3);
  });

  test('a guest whose link broke gets back in without being asked, and catches up on both sides', () async {
    final (ben, benScreen) = await joinAndApprove(name: 'Ben');
    expect(host.participants.length, 2);

    await hub.cut(); // the app was in the background
    await settle();
    expect(ben.state, anyOf(SessionState.reconnecting, SessionState.live));

    hostScreen.note.strokes[0] = [line(10)]; // while Ben was away
    host.localChanged();
    benScreen.note.strokes[1] = [line(70)];
    ben.localChanged();

    ben.wake();
    await settle();
    expect(ben.state, SessionState.live);
    expect(host.pending, isEmpty, reason: 'no new question for the host');
    expect(host.participants.where((p) => p.name == 'Ben').length, 1);
    expect(benScreen.note.strokes[0]!.single.id, hostScreen.note.strokes[0]!.single.id);
    expect(hostScreen.note.strokes[1]!.single.id, benScreen.note.strokes[1]!.single.id);

    benScreen.note.strokes[1]!.add(line(90)); // and live again
    ben.localChanged();
    await settle();
    expect(hostScreen.note.strokes[1]!.length, 2);
  });

  test('what a guest sent just before its link died, and never arrived, reaches the host when the guest is back', () async {
    final (ben, benScreen) = await joinAndApprove(name: 'Ben');

    hub.blackhole = true; // the link is dead but nobody knows yet: what is sent seems sent
    benScreen.note.strokes[1] = [line(70)];
    ben.localChanged();
    await settle();
    expect(hostScreen.note.strokes[1], isNull, reason: 'it did not get through');

    hub.blackhole = false;
    await hub.cut();
    await settle();
    ben.wake();
    await settle();

    expect(ben.state, SessionState.live);
    expect(hostScreen.note.strokes[1]!.single.id, benScreen.note.strokes[1]!.single.id);
  });

  test('a guest that gets back in tells the host its page again, so both see each other', () async {
    final (ben, _) = await joinAndApprove(name: 'Ben');
    host.announcePage(2);
    ben.announcePage(5);
    await settle();

    await hub.cut(); // (the host sees the link go, and forgets the page with the person)
    await settle();
    ben.wake();
    await settle();

    expect(ben.state, SessionState.live);
    expect(host.viewing[ben.site], 5);
    expect(ben.viewing[host.site], 2);
  });

  test('a guest whose host app was closed and started again (a new session) carries on with the same note', () async {
    hostScreen.note.strokes[0] = [line(10)];
    host.localChanged();
    final (ben, benScreen) = await joinAndApprove(name: 'Ben');
    var welcomes = 0;
    ben.onWelcome = (_) => welcomes++;

    // the host's app is closed: its session is gone, without a goodbye
    await hub.cut();
    await host.end();
    toClose.remove(host);
    host.dispose();
    await settle();
    expect(ben.state, SessionState.reconnecting);

    benScreen.note.strokes[1] = [line(70)]; // drawn while the host was gone
    ben.localChanged();

    // the app is started again with the note as it was saved, and lets the guest in (it has the copy's link)
    final restarted = Screen(dir);
    restarted.note.strokes[0] = List.of(hostScreen.note.strokes[0]!);
    hub.hostPresent = true;
    final again = CollabSession.host(invite, hub.host, restarted.binding, name: 'Anna')..trust = (_) => true;
    toClose.add(again);
    ben.wake();
    await settle();
    await settle();

    expect(ben.state, SessionState.live);
    expect(welcomes, 0, reason: 'no second note is made of it');
    expect(restarted.note.strokes[1]?.single.id, benScreen.note.strokes[1]!.single.id, reason: 'what was drawn meanwhile reaches the host');
    expect(benScreen.note.strokes[0]!.single.id, restarted.note.strokes[0]!.single.id);

    benScreen.note.strokes[1]!.add(line(90)); // and live again
    ben.localChanged();
    await settle();
    expect(restarted.note.strokes[1]!.length, 2);
  });

  test('a fresh welcome that comes while the screen is going away waits for the note, then is merged into it', () async {
    final (ben, benScreen) = await joinAndApprove(name: 'Ben');
    await hub.cut();
    await host.end();
    toClose.remove(host);
    host.dispose();
    await settle();

    benScreen.note.strokes[1] = [line(70)];
    ben.suspend(); // the person left the note (or the app): the editor is saving it

    final restarted = Screen(dir);
    restarted.note.strokes[0] = [line(5)];
    hub.hostPresent = true;
    final again = CollabSession.host(invite, hub.host, restarted.binding, name: 'Anna')..trust = (_) => true;
    again.replica.localChanges(restarted.note);
    toClose.add(again);
    ben.wake();
    await settle();
    await settle();
    expect(ben.state, SessionState.live);

    ben.detach(benScreen.note); // saved: the session holds the note now
    await settle();
    expect(benScreen.note.strokes[0]!.single.id, restarted.note.strokes[0]!.single.id);
    expect(restarted.note.strokes[1]?.single.id, benScreen.note.strokes[1]!.single.id);
  });

  test('someone with only the link cannot use the way back', () async {
    final (ben, _) = await joinAndApprove(name: 'Ben');
    await hub.cut();
    await settle();
    // a stranger who knows the link but not Ben's token asks as Ben
    final s = await CollabSession.join(invite, hub.guest, name: 'Ben');
    toClose.add(s);
    await settle();
    expect(host.pending.length, 1, reason: 'asked like anyone else');
    expect(ben.state, isNot(SessionState.ended));
  });

  test('a host that left the note can still let someone in', () async {
    hostScreen.note.strokes[0] = [line(1)];
    host.replica.localChanges(hostScreen.note);
    final held = NoteData(id: 'n')..strokes = hostScreen.note.strokes;
    host.detach(held);
    final (guest, _, welcomed) = await join();
    await settle();
    await host.approve(host.pending.single.id);
    final w = await welcomed.future.timeout(const Duration(seconds: 2));
    expect(w.note.strokes[0]!.length, 1);
    expect(guest.state, SessionState.live);
  });

  test('pages of the PDF that somebody arranged are done on every other copy, and a PDF put in its place goes to them as it is', () async {
    final (ben, benScreen) = await joinAndApprove(name: 'Ben');
    final (_, cyScreen) = await joinAndApprove(name: 'Cy');

    ben.announcePages(const PageArrangement([null, 0, 2], 4, Size(595, 842)));
    await settle();
    for (final screen in [hostScreen, cyScreen]) {
      expect(screen.arrangements.single.order, [null, 0, 2]);
      expect((screen.arrangements.single.from, screen.arrangements.single.blank), (4, const Size(595, 842)));
    }
    expect(benScreen.arrangements, isEmpty, reason: 'it did it itself');

    final bytes = Uint8List.fromList(utf8.encode('%PDF-1.4 a PDF'));
    host.announcePdf(SharedPdf('a.pdf', 'not the hash', 3, bytes));
    await settle();
    for (final screen in [benScreen, cyScreen]) {
      // (the hash is the one of the file, not what the sender said)
      expect((screen.pdfs.single.sha256, screen.pdfs.single.pages), (sha256.convert(bytes).toString(), 3));
      expect(screen.pdfs.single.bytes, bytes);
    }
    expect(hostScreen.pdfs, isEmpty);
  });

  test('pages and PDFs that cannot be right are neither done nor passed on', () async {
    final (ben, benScreen) = await joinAndApprove(name: 'Ben');
    final (_, cyScreen) = await joinAndApprove(name: 'Cy');

    for (final bad in const [
      PageArrangement([0, 0], 2, Size(100, 100)), // a page twice
      PageArrangement([0, 5], 2, Size(100, 100)), // a page there is not
      PageArrangement([], 2, Size(100, 100)), // nothing left
      PageArrangement([0, null], 2, Size(0, 100)), // a page without size
      PageArrangement([0, null], 2, Size(1e9, 100)),
    ]) {
      ben.announcePages(bad);
    }
    // not a PDF at all
    ben.announcePdf(SharedPdf('a.pdf', '', 1, Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9])));
    await settle();
    for (final screen in [hostScreen, cyScreen]) {
      expect(screen.arrangements, isEmpty);
      expect(screen.pdfs, isEmpty);
    }
    expect(benScreen.arrangements, isEmpty);

    // and what is right still gets through afterwards
    ben.announcePages(const PageArrangement([1, 0], 2, Size(100, 100)));
    await settle();
    expect(hostScreen.arrangements.single.order, [1, 0]);
    expect(cyScreen.arrangements.single.order, [1, 0]);
  });

  test('a screen that fails to do the pages of somebody else still lets the others have them', () async {
    final (ben, _) = await joinAndApprove(name: 'Ben');
    final (_, cyScreen) = await joinAndApprove(name: 'Cy');
    final failing = Screen(dir);
    host.detach(failing.note); // (no screen: the host holds the note)
    host.onHeadlessPages = (note, a) async => throw StateError('disk full');
    ben.announcePages(const PageArrangement([1, 0], 2, Size(100, 100)));
    await settle();
    expect(cyScreen.arrangements.single.order, [1, 0]);
  });

  test('pages of the PDF that somebody arranged reach a note that is held without a screen', () async {
    final (ben, _) = await joinAndApprove(name: 'Ben');
    final held = NoteData(id: 'n');
    host.detach(held);
    final heard = <(NoteData, List<int?>)>[];
    host.onHeadlessPages = (note, a) async => heard.add((note, a.order));
    ben.announcePages(const PageArrangement([1, 0], 2, Size(100, 100)));
    await settle();
    expect(heard.single.$1, same(held));
    expect(heard.single.$2, [1, 0]);
  });
}
