// Command-line demo:
//
//   dart run example/merge.dart original.pdf overlay.pdf out.pdf [targetPage,targetPage,...]
//
// Overlay page k is placed on original page targetPage[k] (zero-based; default k).
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf_overlay/pdf_overlay.dart';

void main(List<String> args) {
  if (args.length < 3) {
    stderr.writeln(
        'usage: dart run example/merge.dart original.pdf overlay.pdf out.pdf [pages]');
    exit(64);
  }
  final targets = args.length > 3
      ? args[3].split(',').map(int.parse).toList()
      : null;
  try {
    final out = mergeOverlay(
      Uint8List.fromList(File(args[0]).readAsBytesSync()),
      Uint8List.fromList(File(args[1]).readAsBytesSync()),
      targetPages: targets,
    );
    File(args[2]).writeAsBytesSync(out);
    stdout.writeln('wrote ${args[2]} (${out.length} bytes)');
  } on UnsupportedPdfException catch (e) {
    stderr.writeln('cannot merge: ${e.message}');
    exit(1);
  }
}
