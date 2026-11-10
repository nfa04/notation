import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/collab/replica.dart';
import 'package:notes/collab/session.dart';
import 'package:notes/collab/transport.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';

DrawingStroke line(double y) => DrawingStroke(color: Colors.black, width: 3, points: [for (var i = 0; i < 6; i++) Offset(10.0 + i * 5, y + i)]);

Future<void> settle() async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory dir;
  late LoopbackHub hub;
  late NoteRepository hostRepo, guestRepo;
  late CollabService hostService, guestService;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('collab_service_');
    hub = LoopbackHub();
    hostRepo = NoteRepository(await AppDatabase.open(path: '${dir.path}/host.db'));
    guestRepo = NoteRepository(await AppDatabase.open(path: '${dir.path}/guest.db'));
    hostService = CollabService(hostRepo, builtInServer: '',
        hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/h')..createSync());
    guestService = CollabService(guestRepo, builtInServer: '',
        hostTransport: (_) async => hub.host, joinTransport: (_) => hub.guest, supportDirectory: () async => Directory('${dir.path}/g')..createSync());
    await hostService.load();
    await guestService.load();
    await hostService.setServer('ws://localhost:8787');
    await hostService.setName('Anna');
    await guestService.setName('Ben');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  CollabBinding bindingFor(NoteData note, void Function() onChange) => CollabBinding(
        note: () => note,
        change: (f) {
          f();
          onChange();
        },
        makeBox: (id) => TextBoxWidgetModel(id: id, position: Offset.zero),
        saveImage: hostService.saveImage,
        onNoteField: (f, d) => Replica.applyNoteField(note, f, d),
      );

  test('a picture of a peer is saved inside the images folder whatever extension it names', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final images = p.join(dir.path, 'h', 'images');
    for (final ext in ['png', '/../../escape', '..\\..\\escape', 'png/../x', '', 'toolongextension']) {
      final path = hostService.saveImage('pic/../1', bytes, ext);
      expect(p.dirname(path), images, reason: ext);
      expect(File(path).readAsBytesSync(), bytes);
    }
    expect(hostService.saveImage('a', bytes, 'JPG'), endsWith('live_a.jpg'));
    expect(File(p.join(dir.path, 'escape')).existsSync(), isFalse);
  });

  test('the settings are kept, and a server given without a scheme is made secure', () async {
    expect(hostService.server, 'ws://localhost:8787');
    await hostService.setServer('signal.example.org/live');
    expect(hostService.server, 'wss://signal.example.org/live');
    await hostService.setServer('');
    expect(hostService.server, isNull);
    final again = CollabService(hostRepo, builtInServer: '', supportDirectory: () async => Directory('${dir.path}/h'));
    await again.load();
    expect((again.server, again.nameSetting), (null, 'Anna'));
    await hostService.setServer('ws://a:1');
    await again.load();
    expect(again.server, 'ws://a:1');
  });

  test('hosting without a server says what is missing', () async {
    await hostService.setServer(null);
    final note = NoteData(id: 'x');
    await expectLater(hostService.startHosting('x', bindingFor(note, () {})), throwsA(predicate((e) => '$e'.contains('signalling server'))));
  });

  test('from an invite to a note on the other device, and live changes both ways', () async {
    final hostNote = NoteData(id: 'h', title: 'Study group')..strokes[0] = [line(10)];
    final hostId = await hostRepo.createNote(title: 'Study group');
    final session = await hostService.startHosting(hostId, bindingFor(hostNote, () {}), title: 'Study group');
    final invite = hostService.inviteFor(hostId)!;
    expect(SessionInvite.parse(invite.toLink())!.from, 'Anna');

    final attempt = guestService.join(invite);
    await settle();
    expect(hostService.requests.single.request.name, 'Ben');
    expect(hostService.requests.single.noteTitle, 'Study group');
    expect(attempt.session!.verificationCode, hostService.requests.single.request.code);
    await session.approve(hostService.requests.single.request.id);
    await settle();

    expect(attempt.noteId, isNotNull);
    final made = (await guestRepo.loadNote(attempt.noteId!))!; // a note of its own on the other device
    expect(made.title, 'Study group');
    expect(made.strokes[0]!.single.id, hostNote.strokes[0]!.single.id);
    expect(guestService.sessionFor(attempt.noteId!), same(attempt.session));

    // the editor opens it and takes the session over
    var redraws = 0;
    attempt.session!.attach(bindingFor(made, () => redraws++));
    hostNote.strokes[0]!.add(line(60));
    session.localChanged();
    await settle();
    expect(made.strokes[0]!.length, 2);
    expect(redraws, greaterThan(0));
    made.title = 'Renamed by Ben';
    attempt.session!.localChanged();
    await settle();
    expect(hostNote.title, 'Renamed by Ben');

    await hostService.end(hostId);
    await settle();
    expect(attempt.session!.state, SessionState.ended);
  });

  test('a refused join says so, and no note is made', () async {
    final hostNote = NoteData(id: 'h');
    final hostId = await hostRepo.createNote(title: 'Private');
    final session = await hostService.startHosting(hostId, bindingFor(hostNote, () {}));
    final attempt = guestService.join(hostService.inviteFor(hostId)!);
    await settle();
    await session.deny(hostService.requests.single.request.id);
    await settle();
    expect(attempt.error, contains('did not accept'));
    expect(attempt.noteId, isNull);
    expect(await guestRepo.listNotes(), isEmpty);
  });

  test('joining where nobody hosts reports it', () async {
    final attempt = guestService.join(SessionInvite.create('ws://localhost:8787'));
    await settle();
    expect(attempt.error, contains('nobody is hosting'));
  });
}
