// A probe of the PDF editor in the browser: opens /probe.pdf (served next to the page), edits it and POSTs what happened to
// /result. Build: flutter build web -t tool/web_probe/pdf_edit_probe.dart --output build/probe --no-pub --no-wasm-dry-run
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/widgets.dart';
import 'package:notes/pdf/pdf_content_editor.dart';
import 'package:notes/pdf/pdf_stand_in_fonts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final log = <String>[];
  try {
    final response = await globalContext.callMethod<JSPromise<JSObject>>('fetch'.toJS, 'probe.pdf'.toJS).toDart;
    final bytes = (await response.callMethod<JSPromise<JSArrayBuffer>>('arrayBuffer'.toJS).toDart).toDart.asUint8List();
    log.add('pdf ${bytes.length} bytes, supported=$pdfContentEditingSupported');
    final editor = await PdfContentEditor.open(bytes, fallbackFonts: await loadStandInFonts());
    log.add('opened, page 0 is ${await editor.pageSize(0)}');
    var objects = await editor.objects(0);
    final texts = objects.where((o) => o.kind == PdfObjectKind.text).toList();
    log.add('${objects.length} objects, ${texts.length} text lines');
    for (final t in texts.take(5)) {
      log.add('  "${t.text}" ${t.fontName} ${t.fontSize?.toStringAsFixed(1)} ${t.rect}');
    }
    final first = texts.first;
    log.add('font info: ${(await editor.fontInfo(0, first)).key}');
    await editor.setText(0, first, 'Hello from the browser');
    objects = await editor.objects(0);
    log.add('after setText: ${objects.where((o) => o.kind == PdfObjectKind.text).take(3).map((o) => '"${o.text}"').join(', ')}');
    final line = objects.firstWhere((o) => o.kind == PdfObjectKind.text);
    await editor.moveObject(0, line, const Offset(30, 20));
    await editor.resizeObject(0, (await editor.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.text), const Rect.fromLTWH(60, 60, 200, 30));
    await editor.formatText(0, (await editor.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.text), color: 0xFFCC0000, underline: true);
    log.add('after move/resize/format: ${(await editor.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.text).rect}');
    await editor.formatText(0, (await editor.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.text), bold: true);
    log.add('after bold: ${(await editor.fontInfo(0, (await editor.objects(0)).firstWhere((o) => o.kind == PdfObjectKind.text))).key}');
    final edited = await editor.save();
    await editor.close();
    final check = await PdfContentEditor.open(edited);
    log.add('saved ${edited.length} bytes, starts ${String.fromCharCodes(edited.take(5))}; reopened, page 1 text: ${(await check.objects(0)).where((o) => o.kind == PdfObjectKind.text).map((o) => '"${o.text}"').join(', ')}');
    await check.arrange([null, 0], const Size(595, 842));
    final out = await check.save();
    await check.close();
    final again = await PdfContentEditor.open(out);
    log.add('after arrange: ${await again.pageSize(0)} blank first: ${(await again.objects(0)).length} objects; page 2 has ${(await again.objects(1)).where((o) => o.kind == PdfObjectKind.text).map((o) => '"${o.text}"').join(', ')}');
    await again.close();
    log.add('OK');
  } catch (e, s) {
    log.add('FAILED: $e\n$s');
  }
  await globalContext.callMethod<JSPromise<JSObject>>('fetch'.toJS, 'result'.toJS, {'method': 'POST', 'body': log.join('\n')}.jsify()).toDart;
}
