import 'package:flutter/material.dart' hide Text;
import '../l10n/language.dart';
import '../l10n/text.dart';
import 'package:flutter/services.dart';

import '../ai/ai_prompt.dart' show AiTask;
import '../ai/ai_service.dart';
import '../ai/text_provider.dart';
import '../ink/ink_recognizer.dart' show DownloadableModel;
import '../style/platform_dialog.dart';

/// Writes a summary of [text] (or, for another [task], an explanation of it, or
/// the answer to a question about it) with the AI provider of [ai] and shows it:
/// the download first if the provider needs one, then (for a question) the
/// question, then the text as it grows (with a way to stop), then the finished
/// text to edit. Pops the text the person wants added to the note, or null.
class AiSummaryDialog extends StatefulWidget {
  final AiService ai;
  final String text;

  /// null is the summary.
  final AiTask? task;

  const AiSummaryDialog({super.key, required this.ai, required this.text, this.task});

  @override
  State<AiSummaryDialog> createState() => _AiSummaryDialogState();
}

enum _Stage { download, question, working, done, failed }

class _AiSummaryDialogState extends State<AiSummaryDialog> {
  final _result = TextEditingController();
  final _cancel = AiCancel();
  _Stage _stage = _Stage.working;
  String? _error;
  final _question = TextEditingController();

  bool get _asking => widget.task == AiTask.ask;

  String get _title => switch (widget.task) {
        AiTask.explain => 'Tell me more',
        AiTask.ask || AiTask.assistant => 'Ask a question',
        null => 'Summary',
      };

  TextModelProvider get _provider => widget.ai.provider!;

  @override
  void initState() {
    super.initState();
    final state = _provider.state;
    if (state == ProviderState.unavailable) {
      _stage = _Stage.failed;
      _error = _provider.reason ?? 'This provider cannot be used here.';
    } else if (state != ProviderState.ready) {
      _stage = _Stage.download;
    } else {
      _begin();
    }
  }

  /// A question is asked first; the others start at once.
  void _begin() {
    if (_asking) {
      setState(() => _stage = _Stage.question);
    } else {
      _run();
    }
  }

  @override
  void dispose() {
    _cancel.cancel(); // closing the dialog stops the work
    _result.dispose();
    _question.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    setState(() => _stage = _Stage.working);
    await _provider.prepare();
    if (!mounted) return;
    if (_provider.state != ProviderState.ready) {
      final problem = _provider is DownloadableModel ? (_provider as DownloadableModel).error : null;
      setState(() {
        _stage = _Stage.failed;
        _error = problem == null ? tr('The download did not finish.') : tr('The download failed: {error}', {'error': problem});
      });
      return;
    }
    _begin();
  }

  Future<void> _run() async {
    setState(() {
      _stage = _Stage.working;
      _result.clear();
    });
    try {
      void partial(String text) {
        if (mounted) _result.text = text;
      }

      final text = switch (widget.task) {
        AiTask.explain => await widget.ai.explain(widget.text, cancel: _cancel, onPartial: partial),
        AiTask.ask || AiTask.assistant => await widget.ai.ask(widget.text, _question.text, cancel: _cancel, onPartial: partial),
        null => await widget.ai.summarize(widget.text, cancel: _cancel, onPartial: partial),
      };
      if (!mounted) return;
      _result.text = text;
      setState(() => _stage = _Stage.done);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider;
    final scheme = Theme.of(context).colorScheme;
    return PlatformAlertDialog(
      title: Text(_title),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_stage == _Stage.download) ...[
              Text('${provider.label}: ${provider.description}'),
              const SizedBox(height: 12),
              Text(provider is DownloadableModel
                  ? tr('It needs a download of about {size} GB, once.', {'size': ((provider as DownloadableModel).sizeMb / 1000).toStringAsFixed(1)})
                  : 'It needs setting up first.'),
            ],
            if (_stage == _Stage.question) ...[
              Text.verbatim(widget.text.length > 240 ? '${widget.text.substring(0, 240)}...' : widget.text,
                  maxLines: 4, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('ask-question'),
                controller: _question,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _question.text.trim().isEmpty ? null : _run(),
                decoration: InputDecoration(labelText: tr('Your question'), border: OutlineInputBorder()),
              ),
            ],
            if (_stage == _Stage.working && provider.state == ProviderState.downloading)
              ListenableBuilder(
                listenable: provider,
                builder: (context, _) {
                  final p = provider is DownloadableModel ? (provider as DownloadableModel).progress : 0.0;
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Downloading the model...'),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: p > 0 ? p : null),
                  ]);
                },
              ),
            if (_stage == _Stage.working && provider.state != ProviderState.downloading) ...[
              Row(children: [
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator.adaptive(strokeWidth: 2)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(_result.text.isEmpty ? (_asking ? 'Thinking about it...' : 'Reading the text...') : 'Writing...',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
              ]),
              if (_result.text.isNotEmpty) ...[
                const SizedBox(height: 12),
                ListenableBuilder(listenable: _result, builder: (context, _) => Text.verbatim(_result.text)),
              ],
            ],
            if (_stage == _Stage.done)
              TextField(
                key: const ValueKey('summary-text'),
                controller: _result,
                minLines: 3,
                maxLines: 14,
                decoration: InputDecoration(helperText: tr('Check it and change what you want.'), border: OutlineInputBorder()),
              ),
            if (_stage == _Stage.failed)
              Text(_error ?? 'Something went wrong.', style: TextStyle(color: scheme.error)),
          ]),
        ),
      ),
      actions: switch (_stage) {
        _Stage.download => [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(key: const ValueKey('summary-download'), onPressed: _download, child: const Text('Download')),
          ],
        _Stage.question => [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              key: const ValueKey('ask-send'),
              onPressed: _question.text.trim().isEmpty ? null : _run,
              child: const Text('Ask'),
            ),
          ],
        _Stage.working => [
            TextButton(
              key: const ValueKey('summary-stop'),
              onPressed: provider.state == ProviderState.downloading ? null : _cancel.cancel,
              child: const Text('Stop'),
            ),
          ],
        _Stage.done => [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
            TextButton(
              key: const ValueKey('summary-copy'),
              onPressed: () => Clipboard.setData(ClipboardData(text: _result.text)),
              child: const Text('Copy'),
            ),
            FilledButton(
              key: const ValueKey('summary-add'),
              onPressed: _result.text.trim().isEmpty ? null : () => Navigator.pop(context, _result.text.trim()),
              child: const Text('Add to the note'),
            ),
          ],
        _Stage.failed => [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
      },
    );
  }
}
