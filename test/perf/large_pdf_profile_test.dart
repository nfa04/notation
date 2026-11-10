// Measures what big PDFs cost the app: opening, rendering, keeping pages in memory, reading their text, changing their pages, sending
// them to a live session and exporting them. Not part of the normal run (it takes minutes and prints numbers instead of checking
// anything). Run it with
//
//   PROFILE_PDF=1 LD_LIBRARY_PATH=build/linux/x64/debug/bundle/lib flutter test test/perf/large_pdf_profile_test.dart
//
// The PDFs it makes are kept in ~/.cache/pdf-profile (not /tmp: that is memory), delete the folder when done. PROFILE_TEXT_PAGES
// and PROFILE_SCAN_PAGES change their sizes. Debug builds of the Dart code are slower than a release build, so read the numbers
// as relative ones; the PDFium work is native and the same in both.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:notes/collab/compression.dart';
import 'package:notes/collab/secure_box.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/file_digest.dart';
import 'package:notes/data/pdf_note.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/pdf_models.dart';
import 'package:notes/pdf/page_cache.dart';
import 'package:notes/pdf/pdf_page_loader.dart';
import 'package:notes/pdf/pdf_pages.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_overlay/pdf_overlay.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _on = Platform.environment['PROFILE_PDF'] == '1';
int _mb(int bytes) => bytes ~/ (1 << 20);
int get _rss => ProcessInfo.currentRss;

void say(String line) => stdout.writeln('PERF  $line');

Future<T> timed<T>(String what, Future<T> Function() body, {String Function(T)? note}) async {
  final before = _rss;
  final sw = Stopwatch()..start();
  final r = await body();
  sw.stop();
  say('${what.padRight(58)} ${sw.elapsedMilliseconds.toString().padLeft(7)} ms   rss ${_mb(before)} -> ${_mb(_rss)} MB${note == null ? '' : '   ${note(r)}'}');
  return r;
}

/// Runs [body] and says how long the isolate it runs on was stopped at the longest (a timer that should fire every 10 ms came late):
/// that is the time the screen would have frozen.
Future<void> stalled(String what, Future<void> Function() body) async {
  var last = Stopwatch()..start();
  var worst = 0;
  final ticker = Timer.periodic(const Duration(milliseconds: 10), (_) {
    worst = max(worst, last.elapsedMilliseconds);
    last = Stopwatch()..start();
  });
  final sw = Stopwatch()..start();
  await body();
  ticker.cancel();
  worst = max(worst, last.elapsedMilliseconds);
  say('${what.padRight(58)} ${sw.elapsedMilliseconds.toString().padLeft(7)} ms   screen frozen for up to ${worst.toString().padLeft(5)} ms');
}

String _stats(List<int> micros) {
  final s = [...micros]..sort();
  final avg = s.fold<int>(0, (a, b) => a + b) / s.length;
  return 'avg ${(avg / 1000).toStringAsFixed(0)} ms, p95 ${(s[(s.length * 0.95).floor().clamp(0, s.length - 1)] / 1000).toStringAsFixed(0)} ms, max ${(s.last / 1000).toStringAsFixed(0)} ms';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final pdfium = File('build/native_assets/linux/libpdfium.so');
  final skip = !_on || !pdfium.existsSync() ? 'set PROFILE_PDF=1 (and build the app once for PDFium)' : null;

  final dir = Directory('${Platform.environment['HOME']}/.cache/pdf-profile');
  final textPages = int.parse(Platform.environment['PROFILE_TEXT_PAGES'] ?? '1500');
  final scanPages = int.parse(Platform.environment['PROFILE_SCAN_PAGES'] ?? '200');
  late File text, scan;

  setUpAll(() async {
    if (skip != null) return;
    Pdfrx.pdfiumModulePath = pdfium.absolute.path;
    AppDatabase.initFfi();
    dir.createSync(recursive: true);
    text = File('${dir.path}/text-$textPages.pdf');
    scan = File('${dir.path}/scan-$scanPages.pdf');
    if (!text.existsSync()) {
      await timed('make a PDF of $textPages pages of text', () async {
        final words = 'the quick brown fox jumps over a lazy dog while notes about integrals and graphs pile up in the margin'.split(' ');
        final rnd = Random(1);
        final doc = pw.Document(compress: true);
        for (var p = 0; p < textPages; p++) {
          final lines = [for (var l = 0; l < 52; l++) [for (var w = 0; w < 14; w++) words[rnd.nextInt(words.length)]].join(' ')];
          doc.addPage(pw.Page(
            pageFormat: pdf.PdfPageFormat.a4,
            build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('Page ${p + 1}', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
              for (final line in lines) pw.Text(line, style: const pw.TextStyle(fontSize: 9)),
            ]),
          ));
        }
        text.writeAsBytesSync(await doc.save());
      });
    }
    if (!scan.existsSync()) {
      await timed('make a PDF of $scanPages scanned pages', () async {
        final rnd = Random(2);
        // (a scan: a full page of grey paper and noise, as a JPEG of 200 dpi; a few different ones, taken in turn)
        final variants = <Uint8List>[];
        for (var v = 0; v < 12; v++) {
          final image = img.Image(width: 1654, height: 2339);
          for (final px in image) {
            final n = 200 + rnd.nextInt(40);
            px
              ..r = n
              ..g = n
              ..b = n - 8;
          }
          for (var i = 0; i < 40; i++) {
            img.drawLine(image, x1: 100, y1: 150 + i * 50 + v, x2: 1500, y2: 150 + i * 50 + v, color: img.ColorRgb8(20, 20, 20), thickness: 3);
          }
          variants.add(Uint8List.fromList(img.encodeJpg(image, quality: 80)));
        }
        final doc = pw.Document(compress: false);
        for (var p = 0; p < scanPages; p++) {
          final image = pw.MemoryImage(Uint8List.fromList(variants[p % variants.length]));
          doc.addPage(pw.Page(pageFormat: pdf.PdfPageFormat.a4, margin: pw.EdgeInsets.zero, build: (_) => pw.Image(image, fit: pw.BoxFit.fill)));
        }
        scan.writeAsBytesSync(await doc.save());
      });
    }
    say('text.pdf ${_mb(text.lengthSync())} MB, scan.pdf ${_mb(scan.lengthSync())} MB, cores ${Platform.numberOfProcessors}');
  });

  for (final kind in ['text', 'scan']) {
    group(kind, () {
      File file() => kind == 'text' ? text : scan;

      test('import: copy, hash, open', skip: skip, () async {
        final bytes = await timed('[$kind] read the file', () => file().readAsBytes(), note: (b) => '${_mb(b.length)} MB');
        final copy = File('${dir.path}/$kind-copy.pdf');
        await timed('[$kind] write the copy', () => copy.writeAsBytes(bytes));
        await timed('[$kind] sha256 on the UI isolate', () async => sha256.convert(bytes).toString());
        final doc = await timed('[$kind] PdfDocument.openFile', () => PdfDocument.openFile(copy.path), note: (d) => '${d.pages.length} pages');
        await timed('[$kind] page sizes of all pages (_applyPageSizes)', () async {
          var sum = 0.0;
          for (final page in doc.pages) {
            sum += page.width / page.height;
          }
          return sum;
        });
        await doc.dispose();
        copy.deleteSync();
      });

      test('rendering pages and keeping them', skip: skip, () async {
        final doc = await PdfDocument.openFile(file().path);
        addTearDown(doc.dispose);
        const dpi = 250.0; // what a device with 6 GB or more gets
        // the stages of reading a page, one by one
        final render = <int>[], create = <int>[], encode = <int>[], extract = <int>[], decode = <int>[];
        var pngBytes = 0;
        final sample = [for (var i = 0; i < 30; i++) (i * doc.pages.length / 30).floor()];
        for (final i in sample) {
          final page = doc.pages[i];
          final scale = (dpi / 72).clamp(0.1, 2400 / page.width);
          final sw = Stopwatch()..start();
          final image = await page.render(fullWidth: page.width * scale, fullHeight: page.height * scale, backgroundColor: 0xFFFFFFFF);
          render.add(sw.elapsedMicroseconds);
          sw.reset();
          final ui.Image uiImage = await image!.createImage();
          create.add(sw.elapsedMicroseconds);
          sw.reset();
          final png = (await uiImage.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
          encode.add(sw.elapsedMicroseconds);
          pngBytes += png.length;
          uiImage.dispose();
          image.dispose();
          sw.reset();
          final structured = await page.loadStructuredText();
          extract.add(sw.elapsedMicroseconds);
          structured.fragments.length;
          sw.reset();
          // (what showing the page costs when the widget builds: the PNG is read again into a picture)
          final codec = await ui.instantiateImageCodec(png);
          final frame = await codec.getNextFrame();
          decode.add(sw.elapsedMicroseconds);
          frame.image.dispose();
          codec.dispose();
        }
        say('[$kind] per page at ${dpi.toInt()} dpi (${(pngBytes / sample.length / 1024).toStringAsFixed(0)} KB PNG on average):');
        say('[$kind]   render (PDFium)        ${_stats(render)}');
        say('[$kind]   createImage            ${_stats(create)}');
        say('[$kind]   PNG encode             ${_stats(encode)}');
        say('[$kind]   structured text        ${_stats(extract)}');
        say('[$kind]   PNG decode (per build) ${_stats(decode)}');

        // a page as the editor reads it (its picture for a screen 1200 pixels across, then its words), with the pages kept as the editor keeps them (see _trimPages): a long read through
        final kept = <int, PdfPageData>{};
        final scroll = min(doc.pages.length, 400);
        final started = _rss;
        var peakHeld = 0, peakRss = 0;
        final sw = Stopwatch()..start();
        final each = <int>[];
        for (var i = 0; i < scroll; i++) {
          final one = Stopwatch()..start();
          kept[i] = await loadPdfPicture(doc.pages[i], pagePixelWidth(screenPixels: 1200, pageWidth: doc.pages[i].width, dpi: dpi.toInt()));
          await loadPdfWords(doc.pages[i]);
          each.add(one.elapsedMicroseconds);
          for (final page in pagesToDrop({for (final e in kept.entries) e.key: e.value.bytes}, near: max(0, i - 2), keep: pagesKeptAround + 4)) {
            kept.remove(page)!.release();
          }
          peakHeld = max(peakHeld, kept.values.fold<int>(0, (a, d) => a + d.bytes));
          peakRss = max(peakRss, _rss);
        }
        say('[$kind]   $scroll pages read through, ${kept.length} kept at the end: ${_stats(each)} per page, ${(sw.elapsedMilliseconds / scroll).toStringAsFixed(0)} ms in all per page');
        say('[$kind]   most the pages kept took: ${_mb(peakHeld)} MB; rss at the highest ${_mb(peakRss)} MB (it was ${_mb(started)} MB before)');
        for (final d in kept.values) {
          d.release();
        }
      });

      test('loading several pages at once (the prefetch does one after the other)', skip: skip, () async {
        final doc = await PdfDocument.openFile(file().path);
        addTearDown(doc.dispose);
        const n = 12;
        for (final parallel in [1, 2, 3, 4]) {
          final first = parallel * 20; // (other pages each time: nothing is warm)
          final sw = Stopwatch()..start();
          var next = 0;
          Future<void> worker() async {
            while (next < n) {
              final i = first + next++;
              final page = doc.pages[i % doc.pages.length];
              (await loadPdfPicture(page, pagePixelWidth(screenPixels: 1200, pageWidth: page.width, dpi: 250))).release();
              await loadPdfWords(page);
            }
          }
          await Future.wait([for (var w = 0; w < parallel; w++) worker()]);
          say('[$kind] $n pages, $parallel at a time: ${sw.elapsedMilliseconds} ms (${(sw.elapsedMilliseconds / n).toStringAsFixed(0)} ms per page)');
        }
      });

      test('reading the text for the search (PdfIndexer)', skip: skip, () async {
        final doc = await PdfDocument.openFile(file().path);
        addTearDown(doc.dispose);
        final n = min(doc.pages.length, 600);
        final pages = await timed('[$kind] loadText of $n pages', () async {
          final out = <String>[];
          for (var i = 0; i < n; i++) {
            out.add((await doc.pages[i].loadText())?.fullText ?? '');
          }
          return out;
        }, note: (p) => '${p.fold<int>(0, (a, s) => a + s.length) ~/ 1024} KB of text');
        final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        final id = await repo.createNote();
        await timed('[$kind] savePdfText of $n pages', () => repo.text.savePdfText(id, pages));
      });

      test('changing the pages (arrangePdfFile)', skip: skip, () async {
        final bytes = await file().readAsBytes();
        final doc = await PdfDocument.openFile(file().path);
        final count = doc.pages.length;
        await doc.dispose();
        final copy = File('${dir.path}/$kind-arr.pdf')..writeAsBytesSync(bytes);
        // swap the first two pages, as _movePage does
        final order = <int?>[for (var i = 0; i < count; i++) i];
        order[0] = 1;
        order[1] = 0;
        await timed('[$kind] move one page ($count pages)', () => arrangePdfFile(copy.path, order, fileName: '$kind-arr2.pdf'));
        await timed('[$kind] add one blank page', () => arrangePdfFile(copy.path, [null, ...order.sublist(0, count)], fileName: '$kind-arr3.pdf'));
        await timed('[$kind] delete one page', () => arrangePdfFile(copy.path, order.sublist(1), fileName: '$kind-arr4.pdf'));
        for (final f in ['arr', 'arr2', 'arr3', 'arr4']) {
          File('${dir.path}/$kind-$f.pdf').deleteSync();
        }
      });

      test('sending it to a live session', skip: skip, () async {
        final bytes = await file().readAsBytes();
        final key = Uint8List.fromList(List.generate(32, (i) => i));
        // what session.dart does for a welcome or announcePdf: JSON with base64, UTF-8, packed, sealed, in this order, on this isolate
        final b64 = await timed('[$kind] base64Encode (${_mb(bytes.length)} MB)', () async => base64Encode(bytes));
        final json = await timed('[$kind] jsonEncode + utf8.encode', () async => Uint8List.fromList(utf8.encode(jsonEncode({'t': 'pdf', 'f': {'bytes': b64}}))));
        final packed = await timed('[$kind] packMessage (zlib, on another isolate)', () => packMessage(json), note: (p) => 'to ${_mb(p.length)} MB');
        final sealed = await timed('[$kind] SecureBox.seal on the UI isolate (as _Peer.send)', () => SecureBox(key).seal(packed), note: (s) => '${_mb(s.length)} MB');
        await timed('[$kind] sealApart (another isolate, as folder_sync does)', () => sealApart(key, packed));
        await timed('[$kind] SecureBox.open on the UI isolate', () => SecureBox(key).open(sealed));
        await timed('[$kind] base64Decode of it again', () async => base64Decode(b64));
      });

      test('how long the screen stops (before and after moving work to another isolate)', skip: skip, () async {
        final bytes = await file().readAsBytes();
        final key = Uint8List.fromList(List.generate(32, (i) => i));
        await stalled('[$kind] sha256.convert, as it was', () async => sha256.convert(bytes));
        await stalled('[$kind] sha256OfFile', () => sha256OfFile(file().path));
        await stalled('[$kind] sha256Of(bytes)', () => sha256Of(bytes));
        final slice = Uint8List.sublistView(bytes, 0, min(bytes.length, 64 << 20));
        await stalled('[$kind] SecureBox.seal of ${_mb(slice.length)} MB, as it was', () => SecureBox(key).seal(slice));
        await stalled('[$kind] sealApart (compute) of ${_mb(slice.length)} MB', () => sealApart(key, slice));
        final repo = NoteRepository(await AppDatabase.open(path: inMemoryDatabasePath));
        final copyDir = Directory('${dir.path}/import')..createSync(recursive: true);
        await stalled('[$kind] createNoteFromPdf (${_mb(file().lengthSync())} MB)', () async {
          await createNoteFromPdf(repo, file().path, directory: copyDir);
        });
        copyDir.deleteSync(recursive: true);
      });

      test('exporting with annotations (mergeOverlay)', skip: skip, () async {
        final original = Uint8List.fromList(await file().readAsBytes());
        final doc = await PdfDocument.openFile(file().path);
        final count = doc.pages.length;
        await doc.dispose();
        final targets = [for (var i = 0; i < count; i += max(1, count ~/ 20)) i];
        final overlay = pw.Document();
        for (final _ in targets) {
          overlay.addPage(pw.Page(pageFormat: pdf.PdfPageFormat.a4, build: (_) => pw.Center(child: pw.Text('ink'))));
        }
        final overlayBytes = await overlay.save();
        final merged = await timed('[$kind] mergeOverlay, ${targets.length} annotated pages of $count (UI isolate)', () async => mergeOverlay(original, overlayBytes, targetPages: targets),
            note: (m) => 'out ${_mb(m.length)} MB');
        await timed('[$kind] the same in compute()', () => compute((_) => mergeOverlay(original, overlayBytes, targetPages: targets), null));
        expect(merged.length, greaterThan(original.length ~/ 2));
      });
    });
  }

  tearDownAll(() => say('peak rss of the run: ${_mb(ProcessInfo.maxRss)} MB'));
}
