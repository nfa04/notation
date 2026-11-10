import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/images/picture_edit.dart';
import 'package:notes/images/subject_service.dart';
import 'package:notes/screens/picture_edit_dialog.dart';
import 'package:path/path.dart' as p;

/// A model that says the left half is the subject, and keeps what it was asked.
class _FakeModel implements SubjectModel {
  final inputs = <Float32List>[];
  var closed = false;

  @override
  Future<Float32List> run(Float32List input) async {
    inputs.add(input);
    const side = subjectModelSide;
    return Float32List.fromList([for (var y = 0; y < side; y++) for (var x = 0; x < side; x++) x < side / 2 ? 0.9 : 0.1]);
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  late Directory dir;
  late _FakeModel model;
  late List<String> downloads;

  SubjectService service({bool failDownload = false, String? checksum}) => SubjectService(
        model: (path) => model,
        checksum: checksum,
        modelDirectory: () async => Directory(p.join(dir.path, 'subject')),
        download: (url, path, progress) async {
          downloads.add(url);
          if (failDownload) throw const SocketException('no network');
          progress(0.5);
          await File(path).writeAsBytes([1, 2, 3]);
          progress(1);
        },
      );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('subject');
    model = _FakeModel();
    downloads = [];
  });
  tearDown(() => dir.delete(recursive: true));

  group('the service', () {
    test('without the model it finds nothing, and installing it fetches the one small file, after which it works', () async {
      final s = service();
      await s.load();
      expect(s.installed, isFalse);
      expect(await s.find(RgbaPicture.filled(8, 8, 1, 2, 3)), isNull);
      expect(s.sizeMb, 5);

      await s.install();
      expect(s.installed, isTrue);
      expect(downloads, [SubjectService.url]);
      expect(SubjectService.url, contains('u2netp.onnx'));
      expect(SubjectService.url, kIsWeb ? SubjectService.hubUrl : SubjectService.githubUrl);
      expect(SubjectService.hubUrl, 'https://huggingface.co/nfa04/u2netp-onnx/resolve/main/u2netp.onnx');
      final matte = (await s.find(RgbaPicture.filled(40, 20, 9, 9, 9)))!;
      expect((matte.width, matte.height), (subjectModelSide, subjectModelSide));
      expect(model.inputs.single.length, 3 * subjectModelSide * subjectModelSide);
      expect(matte.values.first, 1);
      expect(matte.values.last, 0);
    });

    test('a download that matches the checksum is kept, one that does not is thrown away with the reason', () async {
      final good = sha256.convert([1, 2, 3]).toString(); // (the fake download writes these three bytes)
      final ok = service(checksum: good);
      await ok.load();
      await ok.install();
      expect(ok.installed, isTrue);
      expect(ok.error, isNull);

      final bad = service(checksum: sha256.convert([9]).toString());
      await bad.remove();
      await bad.load();
      await bad.install();
      expect(bad.installed, isFalse);
      expect(bad.error, contains('checksum'));
      expect(await File(p.join(dir.path, 'subject', SubjectService.fileName)).exists(), isFalse);
    });

    test('the published checksum is a SHA-256', () {
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(SubjectService.checksum), isTrue);
    });

    test('a download that fails leaves it not installed, with the reason, and nothing half written', () async {
      final s = service(failDownload: true);
      await s.load();
      await s.install();
      expect(s.installed, isFalse);
      expect(s.error, contains('no network'));
      final files = await Directory(p.join(dir.path, 'subject')).list().toList();
      expect(files.where((f) => f.path.endsWith('.part') || f.path.endsWith('.onnx')), isEmpty);
    });

    test('removing it lets the model go and takes the file away; what is on the device is found again by load', () async {
      final s = service();
      await s.install();
      await s.find(RgbaPicture.filled(8, 8, 1, 2, 3));
      final again = service();
      await again.load();
      expect(again.installed, isTrue);
      await s.remove();
      expect(model.closed, isTrue);
      expect(s.installed, isFalse);
      await again.load();
      expect(again.installed, isFalse);
    });
  });

  group('in the picture panel', () {
    PictureEditResult? result;
    var answered = false;

    // the picture is made into an image by the engine, which takes a moment of real time
    Future<void> work(WidgetTester tester, {int rounds = 8}) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    Future<void> open(WidgetTester tester, SubjectService? subject) async {
      result = null;
      answered = false;
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final png = encodePicture(RgbaPicture.filled(24, 12, 200, 50, 50));
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<PictureEditResult>(
                  context: context, builder: (_) => PictureEditDialog(source: png, subject: subject, decoder: (b) async => decodePicture(b, maxSide: pictureEditPreviewSide), renderer: (s, e, m) async => applyPictureEdit(s, e, subject: m)));
              answered = true;
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await work(tester, rounds: 3);
    }

    Future<void> choose(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.pump();
      await tester.tap(find.byKey(ValueKey(key)));
      await work(tester);
    }

    testWidgets('without a service there is no such option', (tester) async {
      await open(tester, null);
      await tester.ensureVisible(find.byKey(const ValueKey('pe-bg-fromEdges')));
      expect(find.byKey(const ValueKey('pe-bg-fromEdges')), findsOneWidget);
      expect(find.byKey(const ValueKey('pe-bg-subject')), findsNothing);
    });

    testWidgets('without the model the panel offers to download it, and finds the subject once it is there', (tester) async {
      final s = service();
      await tester.runAsync(s.load);
      await open(tester, s);
      await choose(tester, 'pe-bg-subject');
      expect(find.byKey(const ValueKey('pe-subject-download')), findsOneWidget);
      expect(find.byKey(const ValueKey('pe-subject-cut')), findsNothing, reason: 'nothing to set before it works');
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('pe-apply'))).onPressed, isNull, reason: 'without a subject there is nothing to apply');

      await tester.ensureVisible(find.byKey(const ValueKey('pe-subject-download')));
      await tester.tap(find.byKey(const ValueKey('pe-subject-download')));
      await work(tester, rounds: 24); // (the file is written and moved, the model is asked, the answer is shown)
      expect(s.installed, isTrue);
      expect(model.inputs, hasLength(1), reason: 'the model was asked once, as soon as it was there');
      expect(find.byKey(const ValueKey('pe-subject-download')), findsNothing);
      expect(find.byKey(const ValueKey('pe-subject-cut')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('pe-apply'))).onPressed, isNotNull);

      // a change of the cut does not ask the model again
      await tester.ensureVisible(find.byKey(const ValueKey('pe-subject-cut')));
      await tester.drag(find.byKey(const ValueKey('pe-subject-cut')), const Offset(40, 0));
      await work(tester);
      expect(model.inputs, hasLength(1));

      await tester.ensureVisible(find.byKey(const ValueKey('pe-apply')));
      await tester.tap(find.byKey(const ValueKey('pe-apply')));
      await tester.pumpAndSettle();
      expect(answered, isTrue);
      expect(result!.edit.background, BackgroundRemoval.subject);
      expect(result!.subject, isNotNull, reason: 'what the model said goes with the edit, for the picture at its full size');
      expect(result!.edit.subjectCut, isNot(0.5));
    });

    testWidgets('with the model there, choosing it asks at once; another option answers without the matte', (tester) async {
      final s = service();
      await tester.runAsync(s.install);
      await open(tester, s);
      await choose(tester, 'pe-bg-subject');
      await work(tester, rounds: 6); // (the model is asked, then the answer made into a picture)
      expect(model.inputs, hasLength(1));
      expect(find.byKey(const ValueKey('pe-subject-download')), findsNothing);
      await choose(tester, 'pe-bg-everywhere');
      await tester.ensureVisible(find.byKey(const ValueKey('pe-apply')));
      await tester.tap(find.byKey(const ValueKey('pe-apply')));
      await tester.pumpAndSettle();
      expect(result!.edit.background, BackgroundRemoval.everywhere);
      expect(result!.subject, isNull);
    });
  });
}
