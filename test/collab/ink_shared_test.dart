import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_text_repository.dart' show InkRead;
import 'package:notes/ink/note_ink_reader.dart';
import 'package:notes/models/canvas_models.dart';

import '../ink_prefetch_test.dart' show FakeReader, until, word;
import 'session_test.dart' show settle;

/// One device: a note, a reader of its handwriting, and the binding that gives the reader what the host read.
class Device {
  final NoteData note = NoteData(id: 'n');
  late final NoteInkReader reader;
  final FakeReader hw;
  CollabSession? session;
  final saved = <String, String>{};
  late final CollabBinding binding;

  Device(Directory dir, this.hw) {
    reader = NoteInkReader(
      noteId: 'n',
      handwriting: hw,
      math: null,
      idle: const Duration(milliseconds: 20),
      strokes: () => {0: note.strokes[0] ?? []},
      visiblePage: () => 0,
      isQuiet: () => true,
      isOpen: () => true,
      isLocked: () => false,
      ready: () async {},
      indexWanted: () async => true,
      saveIndex: (id, read, alive) async => saved.addAll({for (final t in read) t.key: t.text}),
      saveReads: (id, reads) async {},
      loadSaved: (id) async => (texts: <String, String>{}, unsure: <String, String>{}, reads: <InkRead>[]),
      onProgress: () {},
      readsHere: () => session?.readsInk ?? true,
      share: (r) => session?.announceReadings(r),
    );
    binding = CollabBinding(
      note: () => note,
      change: (f) => f(),
      makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
      saveImage: (id, bytes, ext) => (File('${dir.path}/$id.$ext')..writeAsBytesSync(bytes)).path,
      onNoteField: (f, d) => Replica.applyNoteField(note, f, d),
      onReadings: reader.takeShared,
    );
  }
}

void main() {
  late Directory dir;
  late LoopbackHub hub;
  late SessionInvite invite;
  final toClose = <CollabSession>[];
  final devices = <Device>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('inkshared_');
    hub = LoopbackHub();
    invite = SessionInvite.create('ws://localhost:1', random: Random(9));
  });
  tearDown(() async {
    for (final d in devices) {
      d.reader.dispose();
    }
    devices.clear();
    for (final s in toClose) {
      await s.end();
      s.dispose();
    }
    toClose.clear();
    dir.deleteSync(recursive: true);
  });

  Device device() {
    final d = Device(dir, FakeReader((s) => 'read ${s.length}'));
    devices.add(d);
    return d;
  }

  Future<Device> guest(CollabSession host, {required Device from, String name = 'Ben'}) async {
    final g = device();
    final done = <Welcome>[];
    final s = await CollabSession.join(invite, hub.guest, name: name, onWelcome: done.add, imageSaver: g.binding.saveImage);
    toClose.add(s);
    await settle();
    await host.approve(host.pending.single.id);
    await until(() => done.isNotEmpty);
    g.note
      ..strokes = done.single.note.strokes
      ..textBoxes = done.single.note.textBoxes;
    g.session = s;
    s.attach(g.binding);
    await settle();
    return g;
  }

  Future<void> readAll(Device d) async {
    await d.reader.prepare(text: true, math: false);
    d.reader.indexInk = true;
    await d.reader.start();
  }

  test('only the host reads the handwriting; the guest has the readings without reading', () async {
    final h = device();
    h.note.strokes[0] = word('a', 100, 100) + word('b', 100, 500);
    final host = CollabSession.host(invite, hub.host, h.binding, name: 'Anna');
    toClose.add(host);
    h.session = host;
    final g = await guest(host, from: h);
    expect(g.note.strokes[0], hasLength(8));
    expect(host.readsInk, isTrue);
    expect(g.session!.readsInk, isFalse);

    await readAll(h);
    await readAll(g);
    await until(() => h.hw.calls.length >= 2);
    await until(() => g.saved.length >= 2, ms: 5000);

    expect(h.hw.calls, hasLength(2)); // (each block once)
    expect(g.hw.calls, isEmpty); // (the guest read nothing)
    expect(g.saved.values.toSet(), h.saved.values.toSet()); // (and keeps what the host read, for its search)
    expect(g.saved.keys.toSet(), h.saved.keys.toSet());
    // the guest can use it at once, as if it had read it
    expect(g.reader.prefetcher!.lookupText(g.note.strokes[0]!.take(4)), 'read 4');
  });

  test('somebody who joins later is told everything the host has read', () async {
    final h = device();
    h.note.strokes[0] = word('a', 100, 100);
    final host = CollabSession.host(invite, hub.host, h.binding, name: 'Anna');
    toClose.add(host);
    h.session = host;
    await readAll(h);
    await until(() => h.hw.calls.isNotEmpty && h.saved.isNotEmpty);

    final g = await guest(host, from: h);
    h.reader.shareAgain(); // (what the editor does when the number of people grows)
    await readAll(g);
    await until(() => g.saved.isNotEmpty, ms: 5000);
    expect(g.hw.calls, isEmpty);
    expect(g.saved.values.single, h.saved.values.single);
  });

  test('a guest whose host is gone reads for itself again', () async {
    final h = device();
    h.note.strokes[0] = word('a', 100, 100);
    final host = CollabSession.host(invite, hub.host, h.binding, name: 'Anna');
    toClose.add(host);
    h.session = host;
    final g = await guest(host, from: h);
    expect(g.session!.readsInk, isFalse);
    await host.end();
    await settle();
    expect(g.session!.readsInk, isTrue);
  });

  test('what comes from another device is only taken as texts by key', () async {
    final d = device();
    d.note.strokes[0] = word('a', 100, 100);
    d.reader.takeShared({'texts': {'k': 5, 'j': 'ok'}, 'unsure': 'nonsense', 'formulas': null});
    expect(d.reader.prefetcher, isNotNull);
  });
}
