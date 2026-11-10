import 'package:flutter/material.dart';

import '../ai/ai_service.dart';
import '../ai/creative_ideas.dart';
import '../ai/text_provider.dart';
import '../ink/ink_recognizer.dart' show DownloadableModel;
import '../l10n/language.dart';
import '../style/platform_dialog.dart';

/// What the person took from the ideas: colours for the palette, or a text for the note.
class IdeasResult {
  final List<Color> colours;
  final String? text;

  const IdeasResult({this.colours = const [], this.text});
}

/// Asks the assistant for a palette (for a mood or a subject) or for ideas (a drawing, a character, a story, a song, a design) and
/// shows what it came up with: a tap on a colour keeps that one, "Add all" keeps them all; an idea can be added to the note, or all
/// of them. Answers with what was taken, or null.
Future<IdeasResult?> showIdeasDialog(BuildContext context, AiService ai) => showDialog<IdeasResult>(context: context, builder: (_) => IdeasDialog(ai: ai));

enum _Stage { download, input, working, done, failed }

class IdeasDialog extends StatefulWidget {
  final AiService ai;

  const IdeasDialog({super.key, required this.ai});

  @override
  State<IdeasDialog> createState() => _IdeasDialogState();
}

class _IdeasDialogState extends State<IdeasDialog> {
  final _topic = TextEditingController();
  var _cancel = AiCancel();
  _Stage _stage = _Stage.input;
  bool _colours = true;
  IdeaKind _kind = IdeaKind.drawing;
  List<Color> _palette = const [];
  List<String> _ideas = const [];
  String _partial = '';
  String? _error;

  TextModelProvider get _provider => widget.ai.provider!;

  @override
  void initState() {
    super.initState();
    final state = _provider.state;
    if (state == ProviderState.unavailable) {
      _stage = _Stage.failed;
      _error = _provider.reason ?? tr('This provider cannot be used here.');
    } else if (state != ProviderState.ready) {
      _stage = _Stage.download;
    }
  }

  @override
  void dispose() {
    _cancel.cancel(); // closing the dialog stops the work
    _topic.dispose();
    super.dispose();
  }

  bool get _canAsk => !_colours || _topic.text.trim().isNotEmpty;

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
    setState(() => _stage = _Stage.input);
  }

  Future<void> _ask() async {
    _cancel = AiCancel();
    setState(() {
      _stage = _Stage.working;
      _partial = '';
    });
    try {
      final colours = _colours;
      final text = await widget.ai.generate(
        colours ? palettePrompt(_topic.text) : ideasPrompt(_kind, _topic.text, language: AppLanguage.instance.code),
        maxTokens: colours ? 160 : 450,
        cancel: _cancel,
        onPartial: (t) {
          if (mounted) setState(() => _partial = t);
        },
      );
      if (!mounted) return;
      final palette = colours ? parsePalette(text) : const <Color>[];
      final ideas = colours ? const <String>[] : parseIdeas(text);
      setState(() {
        _palette = palette;
        _ideas = ideas;
        if (palette.isEmpty && ideas.isEmpty) {
          _stage = _Stage.failed;
          _error = tr('Nothing usable came back. Try again, or use other words.');
        } else {
          _stage = _Stage.done;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _error = '$e'.replaceFirst('Bad state: ', '');
      });
    }
  }

  void _toInput() => setState(() => _stage = _Stage.input);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final provider = _provider;
    return PlatformAlertDialog(
      title: Text(tr('Ideas from the assistant')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_stage == _Stage.download) ...[
              Text('${provider.label}: ${provider.description}'),
              const SizedBox(height: 12),
              Text(provider is DownloadableModel
                  ? tr('It needs a download of about {size} GB, once.', {'size': ((provider as DownloadableModel).sizeMb / 1000).toStringAsFixed(1)})
                  : tr('It needs setting up first.')),
            ],
            if (_stage == _Stage.input) ...[
              SegmentedButton<bool>(
                key: const ValueKey('ideas-mode'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: true, label: Text(tr('Colours')), tooltip: tr('A palette for a mood or a subject')),
                  ButtonSegment(value: false, label: Text(tr('Ideas')), tooltip: tr('Something to start from')),
                ],
                selected: {_colours},
                onSelectionChanged: (s) => setState(() => _colours = s.first),
              ),
              const SizedBox(height: 12),
              if (!_colours) ...[
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final k in IdeaKind.values)
                    ChoiceChip(key: ValueKey('ideas-kind-${k.name}'), label: Text(tr(k.label)), selected: _kind == k, onSelected: (_) => setState(() => _kind = k)),
                ]),
                const SizedBox(height: 12),
              ],
              TextField(
                key: const ValueKey('ideas-topic'),
                controller: _topic,
                autofocus: true,
                textInputAction: TextInputAction.send,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _canAsk ? _ask() : null,
                decoration: InputDecoration(
                  labelText: tr(_colours ? 'Mood or subject' : 'Topic (optional)'),
                  hintText: tr(_colours ? 'a quiet harbour at dawn' : 'the sea'),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
            if (_stage == _Stage.working && provider.state == ProviderState.downloading)
              ListenableBuilder(
                listenable: provider,
                builder: (context, _) {
                  final p = provider is DownloadableModel ? (provider as DownloadableModel).progress : 0.0;
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Downloading the model...')),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: p > 0 ? p : null),
                  ]);
                },
              ),
            if (_stage == _Stage.working && provider.state != ProviderState.downloading)
              Row(children: [
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator.adaptive(strokeWidth: 2)),
                const SizedBox(width: 12),
                Expanded(child: Text(tr(_partial.isEmpty ? 'Thinking...' : 'Writing...'), style: TextStyle(color: scheme.onSurfaceVariant))),
              ]),
            if (_stage == _Stage.done && _colours)
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (final (i, c) in _palette.indexed)
                  Tooltip(
                    message: '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
                    child: InkWell(
                      key: ValueKey('ideas-colour-$i'),
                      borderRadius: BorderRadius.circular(24),
                      onTap: () => Navigator.pop(context, IdeasResult(colours: [c])),
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: scheme.outlineVariant, width: 2)),
                      ),
                    ),
                  ),
              ]),
            if (_stage == _Stage.done && !_colours)
              for (final (i, idea) in _ideas.indexed)
                ListTile(
                  key: ValueKey('ideas-idea-$i'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(idea),
                  trailing: IconButton(
                    key: ValueKey('ideas-add-$i'),
                    tooltip: tr('Add to the note'),
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () => Navigator.pop(context, IdeasResult(text: idea)),
                  ),
                ),
            if (_stage == _Stage.failed) Text(_error ?? tr('Something went wrong.'), style: TextStyle(color: scheme.error)),
          ]),
        ),
      ),
      actions: switch (_stage) {
        _Stage.download => [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
            FilledButton(key: const ValueKey('ideas-download'), onPressed: _download, child: Text(tr('Download'))),
          ],
        _Stage.input => [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
            FilledButton(key: const ValueKey('ideas-go'), onPressed: _canAsk ? _ask : null, child: Text(tr('Suggest'))),
          ],
        _Stage.working => [
            TextButton(key: const ValueKey('ideas-stop'), onPressed: provider.state == ProviderState.downloading ? null : _cancel.cancel, child: Text(tr('Stop'))),
          ],
        _Stage.done => [
            TextButton(key: const ValueKey('ideas-back'), onPressed: _toInput, child: Text(tr('Back'))),
            TextButton(key: const ValueKey('ideas-again'), onPressed: _ask, child: Text(tr('Try again'))),
            FilledButton(
              key: const ValueKey('ideas-add-all'),
              onPressed: () => Navigator.pop(context, _colours ? IdeasResult(colours: _palette) : IdeasResult(text: _ideas.map((i) => '- $i').join('\n'))),
              child: Text(tr('Add all')),
            ),
          ],
        _Stage.failed => [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Close'))),
            if (provider.state == ProviderState.ready) TextButton(key: const ValueKey('ideas-back'), onPressed: _toInput, child: Text(tr('Back'))),
          ],
      },
    );
  }
}
