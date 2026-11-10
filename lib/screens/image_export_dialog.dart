import 'package:flutter/material.dart' hide Text;

import '../export/image_export.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';

/// What the person chose for the pictures of the pages.
class ImageExportChoice {
  final ImagePreset preset;

  /// All the pages (else the one in view).
  final bool allPages;

  /// Leave the paper out: the picture is see-through where the page is empty.
  final bool seeThrough;

  const ImageExportChoice(this.preset, {this.allPages = false, this.seeThrough = false});
}

/// Asks in which size the pages are made into pictures (and which pages, and whether the paper is left out). [pageSize] is the size
/// of the page in view in the editor's page space, to say how big each choice makes the picture; [pages] how many pages there are.
Future<ImageExportChoice?> showImageExportDialog(BuildContext context, {required Size pageSize, required int pages, ImagePreset? last}) =>
    showDialog<ImageExportChoice>(context: context, builder: (_) => ImageExportDialog(pageSize: pageSize, pages: pages, initial: last));

class ImageExportDialog extends StatefulWidget {
  final Size pageSize;
  final int pages;
  final ImagePreset? initial;

  const ImageExportDialog({super.key, required this.pageSize, required this.pages, this.initial});

  @override
  State<ImageExportDialog> createState() => _ImageExportDialogState();
}

class _ImageExportDialogState extends State<ImageExportDialog> {
  late ImagePreset _preset = widget.initial ?? ImagePreset.screen;
  bool _all = false;
  bool _seeThrough = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PlatformAlertDialog(
      title: const Text('Export as pictures'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Size', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.bold)),
            RadioGroup<ImagePreset>(
              groupValue: _preset,
              onChanged: (v) => setState(() => _preset = v ?? _preset),
              child: Column(children: [
                for (final p in ImagePreset.values)
                  RadioListTile<ImagePreset>.adaptive(
                    key: ValueKey('export-preset-${p.name}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: p,
                    title: Text(p.label),
                    subtitle: Text.verbatim('${tr(p.hint)}\n${planImage(p, widget.pageSize)} px'),
                    isThreeLine: true,
                  ),
              ]),
            ),
            if (widget.pages > 1) ...[
              const SizedBox(height: 8),
              Text('Pages', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              SegmentedButton<bool>(
                key: const ValueKey('export-pages'),
                showSelectedIcon: false,
                segments: [
                  const ButtonSegment(value: false, label: Text('This page')),
                  ButtonSegment(value: true, label: Text.verbatim(tr('All {n} pages', {'n': widget.pages}))),
                ],
                selected: {_all},
                onSelectionChanged: (s) => setState(() => _all = s.first),
              ),
            ],
            SwitchListTile.adaptive(
              key: const ValueKey('export-see-through'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _seeThrough,
              onChanged: (v) => setState(() => _seeThrough = v),
              title: const Text('See-through background'),
              subtitle: const Text('Leave the white paper and its lines out, so that only what is on the page shows'),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('export-images-go'),
          onPressed: () => Navigator.pop(context, ImageExportChoice(_preset, allPages: _all, seeThrough: _seeThrough)),
          child: const Text('Export'),
        ),
      ],
    );
  }
}
