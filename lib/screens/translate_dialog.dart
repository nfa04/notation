import 'package:flutter/material.dart' hide Text;

import '../ai/text_provider.dart';
import '../ai/translation.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import 'lookup_panel.dart' show translateLanguages;
import '../style/platform_dialog.dart';

/// Asks which language a note is translated into. The answer is the code ([translationTargets]), null when cancelled.
/// [pieces] is how many separate texts there are (text boxes and the written document), [pdf] whether the text of the PDF is translated
/// too, [ready] whether a model can do it now.
Future<String?> askTranslationLanguage(BuildContext context, {required int pieces, required bool ready, String? initial, bool pdf = false}) => showDialog<String>(
      context: context,
      builder: (context) => _TranslateDialog(pieces: pieces, pdf: pdf, ready: ready, initial: initial),
    );

class _TranslateDialog extends StatefulWidget {
  final int pieces;
  final bool pdf;
  final bool ready;
  final String? initial;

  const _TranslateDialog({required this.pieces, required this.pdf, required this.ready, this.initial});

  @override
  State<_TranslateDialog> createState() => _TranslateDialogState();
}

class _TranslateDialogState extends State<_TranslateDialog> {
  late String _code = translationTargets.containsKey(widget.initial) ? widget.initial! : (AppLanguage.instance.code == 'en' ? 'de' : 'en');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PlatformAlertDialog(
      title: const Text('Translate this note'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.pieces == 0 && !widget.pdf)
            Text('This note has no text boxes or written document to translate. Handwriting is not translated.', style: TextStyle(color: scheme.onSurfaceVariant))
          else ...[
            if (widget.pieces > 0)
              Text.verbatim(
                tr('The {n} texts in this note are replaced by their translation, in place. A version of the note is kept first, and the change can be taken back with Undo.', {'n': widget.pieces}),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            if (widget.pdf)
              Padding(
                padding: EdgeInsets.only(top: widget.pieces > 0 ? 8 : 0),
                child: Text(
                  'The text of the PDF is rewritten in its translation, page by page. Longer lines are set smaller, and a line that cannot be shown stays as it was. A version of the note is kept first, and the change can be taken back with Undo.',
                  key: const ValueKey('translate-pdf-note'),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: const ValueKey('translate-language'),
              initialValue: _code,
              decoration: InputDecoration(labelText: tr('Translate into')),
              items: [for (final e in translateLanguages.entries) if (translationTargets.containsKey(e.key)) DropdownMenuItem(value: e.key, child: Text.verbatim(e.value))],
              onChanged: (c) => setState(() => _code = c ?? _code),
            ),
            if (!widget.ready)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('The assistant is not ready. Set up a model in the Settings first.', key: const ValueKey('translate-not-ready'), style: TextStyle(color: scheme.error)),
              ),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('translate-start'), onPressed: widget.ready && (widget.pieces > 0 || widget.pdf) ? () => Navigator.pop(context, _code) : null, child: const Text('Translate')),
      ],
    );
  }
}

/// Progress of a translation, with a Stop button. Close it by popping the route it is shown on.
class TranslateProgress extends StatelessWidget {
  final ValueNotifier<(int done, int total)> progress;
  final AiCancel cancel;

  const TranslateProgress({super.key, required this.progress, required this.cancel});

  @override
  Widget build(BuildContext context) => PlatformAlertDialog(
        title: const Text('Translating...'),
        content: ValueListenableBuilder<(int, int)>(
          valueListenable: progress,
          builder: (context, p, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            LinearProgressIndicator(value: p.$2 == 0 ? null : p.$1 / p.$2),
            const SizedBox(height: 8),
            Text.verbatim(tr('{done} of {total}', {'done': p.$1, 'total': p.$2}), key: const ValueKey('translate-progress')),
          ]),
        ),
        actions: [TextButton(key: const ValueKey('translate-stop'), onPressed: cancel.cancel, child: const Text('Stop'))],
      );
}
