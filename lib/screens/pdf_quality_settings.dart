import 'package:flutter/material.dart' hide Text;

import '../data/note_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../pdf/pdf_page_loader.dart';

/// How sharply PDF pages are drawn: sharper pages take more memory and time to load.
class PdfQualitySettings extends StatefulWidget {
  final NoteRepository repository;
  const PdfQualitySettings({super.key, required this.repository});

  @override
  State<PdfQualitySettings> createState() => _PdfQualitySettingsState();
}

class _PdfQualitySettingsState extends State<PdfQualitySettings> {
  int? _dpi; // null: the device decides
  int _auto = 200;

  @override
  void initState() {
    super.initState();
    () async {
      final saved = int.tryParse(await widget.repository.settings.get('pdf_dpi') ?? '');
      final auto = await defaultPdfDpi();
      if (mounted) {
        setState(() {
          _dpi = saved;
          _auto = auto;
        });
      }
    }();
  }

  Future<void> _set(int? dpi) async {
    setState(() => _dpi = dpi);
    await widget.repository.settings.set('pdf_dpi', dpi?.toString() ?? '');
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('PDF sharpness', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text(
        'The most PDF pages are drawn at. On screen a page is drawn as sharp as the screen shows it, up to this; zoomed in, the part on screen is drawn sharper. Pictures of pages that are exported use it as it is. Higher is sharper but uses more memory and loads slower. Automatic picks 250 dpi on a device with plenty of memory and 200 dpi on others. It applies to PDFs opened from now on.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
      ),
      const SizedBox(height: 10),
      DropdownMenu<int?>(
        key: const ValueKey('pdf-dpi'),
        initialSelection: _dpi,
        onSelected: _set,
        dropdownMenuEntries: [
          DropdownMenuEntry(value: null, label: tr('Automatic ({dpi} dpi on this device)', {'dpi': _auto})),
          for (final d in pdfDpiChoices) DropdownMenuEntry(value: d, label: '$d dpi'),
        ],
      ),
    ]);
  }
}
