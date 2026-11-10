import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide Text;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/language.dart';
import '../l10n/text.dart';

/// The pages of a document as they will be printed ([pdf]), to look through before printing or saving them. Printing hands the
/// PDF to the system: on a computer it opens in the PDF viewer, which prints; on a phone it goes to the share sheet, which has
/// the printer.
class PrintPreview extends StatelessWidget {
  final Uint8List pdf;
  final String title;

  /// Saves the PDF (asks where).
  final VoidCallback onSave;

  const PrintPreview({super.key, required this.pdf, required this.title, required this.onSave});

  static Future<void> show(BuildContext context, {required Uint8List pdf, required String title, required VoidCallback onSave}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => PrintPreview(pdf: pdf, title: title, onSave: onSave),
      ));

  Future<void> _print(BuildContext context) async {
    try {
      final dir = await getTemporaryDirectory();
      final name = '${title.isEmpty ? 'Document' : title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}.pdf';
      final file = File(p.join(dir.path, name));
      await file.writeAsBytes(pdf);
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: 'application/pdf')], title: title));
      } else if (!await launchUrl(Uri.file(file.path))) {
        throw StateError(tr('No program to open PDFs with was found.'));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Could not print: {error}', {'error': e}))));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Print preview'),
          actions: [
            TextButton.icon(key: const ValueKey('preview-save'), onPressed: onSave, icon: const Icon(Icons.save_alt), label: const Text('Save as PDF')),
            const SizedBox(width: 8),
            FilledButton.icon(key: const ValueKey('preview-print'), onPressed: () => _print(context), icon: const Icon(Icons.print), label: const Text('Print')),
            const SizedBox(width: 12),
          ],
        ),
        body: ColoredBox(
          color: Colors.grey.shade300,
          child: PdfViewer.data(pdf, sourceName: 'print-preview-${pdf.length}.pdf'),
        ),
      );
}
