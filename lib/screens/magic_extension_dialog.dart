import 'package:flutter/material.dart' hide Text;

import 'extension_docs_dialog.dart';
import 'extension_review.dart';

import '../ai/ai_service.dart';
import '../ai/text_provider.dart';
import '../automations/automation_service.dart';
import '../extensions/extension_service.dart';
import '../extensions/magic_extension.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';

/// What *Create with AI* made, when the person installed it (for the message afterwards).
class MagicInstalled {
  final String name;
  final bool allowed;
  final int rules;
  const MagicInstalled(this.name, this.allowed, this.rules);

  String get message {
    final base = allowed
        ? tr('{name} is installed and switched on.', {'name': name})
        : tr('Installed {name}. It is off until you switch it on in Settings > Extensions.', {'name': name});
    return rules == 0 ? base : '$base ${trCount(rules, 'One automation was added.', '{n} automations were added.')}${allowed ? '' : ' ${tr('They are off.')}'}';
  }
}

/// *Create with AI*: the person says in their own words what they want, the AI makes an extension (and the automations that use it),
/// and they read it and decide before anything is installed.
Future<MagicInstalled?> showMagicExtension(BuildContext context, {required AiService ai, required ExtensionService extensions, AutomationService? automations}) =>
    showDialog<MagicInstalled>(
      context: context,
      barrierDismissible: false,
      builder: (context) => MagicExtensionDialog(magic: MagicExtension(ai, extensions), extensions: extensions, automations: automations),
    );

class MagicExtensionDialog extends StatefulWidget {
  final MagicExtension magic;
  final ExtensionService extensions;
  final AutomationService? automations;

  const MagicExtensionDialog({super.key, required this.magic, required this.extensions, this.automations});

  @override
  State<MagicExtensionDialog> createState() => _MagicExtensionDialogState();
}

enum _Stage { asking, working, reading }

class _MagicExtensionDialogState extends State<MagicExtensionDialog> {
  final _request = TextEditingController();
  final _change = TextEditingController();
  _Stage _stage = _Stage.asking;
  MagicDraft? _draft;
  String _asked = '';
  String _partial = '';
  String? _problem;
  String? _failure;
  AiCancel? _cancel;
  bool _busy = false;

  @override
  void dispose() {
    _cancel?.cancel();
    _request.dispose();
    _change.dispose();
    super.dispose();
  }

  Future<void> _make({MagicDraft? previous, String? change}) async {
    final request = previous == null ? _request.text.trim() : _asked;
    if (request.isEmpty) return;
    _asked = request;
    final cancel = _cancel = AiCancel();
    setState(() {
      _stage = _Stage.working;
      _partial = '';
      _problem = null;
      _failure = null;
    });
    try {
      final draft = await widget.magic.draft(
        request,
        previous: previous,
        change: change,
        cancel: cancel,
        onPartial: (p) {
          if (mounted) setState(() => _partial = p);
        },
        onProblem: (p) {
          if (mounted) setState(() => _problem = p);
        },
      );
      if (!mounted || cancel.cancelled) return;
      _change.clear();
      setState(() {
        _draft = draft;
        _stage = _Stage.reading;
      });
    } catch (e) {
      if (!mounted || cancel.cancelled) return;
      setState(() {
        _failure = '$e'.replaceFirst('Bad state: ', '');
        _stage = previous == null ? _Stage.asking : _Stage.reading;
      });
    }
  }

  Future<void> _install(bool allow) async {
    final draft = _draft;
    if (draft == null) return;
    setState(() => _busy = true);
    try {
      final rules = await widget.magic.install(draft, allow: allow, automations: widget.automations);
      if (mounted) Navigator.pop(context, MagicInstalled(draft.manifest.name, allow, rules));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failure = tr('Could not install it: {error}', {'error': '$e'});
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PlatformAlertDialog(
      title: Row(children: [const Icon(Icons.auto_fix_high, size: 22), const SizedBox(width: 10), Text('Create with AI')]),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: switch (_stage) {
            _Stage.asking => _asking(context),
            _Stage.working => _working(context),
            _Stage.reading => _reading(context),
          },
        ),
      ),
      actions: switch (_stage) {
        _Stage.asking => [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton.icon(key: const ValueKey('magic-create'), onPressed: _make, icon: const Icon(Icons.auto_awesome, size: 18), label: const Text('Create')),
          ],
        _Stage.working => [
            TextButton(
              key: const ValueKey('magic-stop'),
              onPressed: () {
                _cancel?.cancel();
                setState(() => _stage = _draft == null ? _Stage.asking : _Stage.reading);
              },
              child: const Text('Stop'),
            ),
          ],
        _Stage.reading => [
            TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
            OutlinedButton(key: const ValueKey('magic-install'), onPressed: _busy ? null : () => _install(false), child: const Text('Install (off)')),
            FilledButton(key: const ValueKey('magic-install-allow'), onPressed: _busy ? null : () => _install(true), child: const Text('Install and allow')),
          ],
      },
    );
  }

  Widget _asking(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(
        'Say what you want in your own words: a tool for selected text, or something that should happen by itself. The AI writes the extension, '
        'you read it, and only then is it installed.',
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
      ),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('magic-request'),
        controller: _request,
        autofocus: true,
        minLines: 3,
        maxLines: 6,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          hintText: tr('e.g. A tool that turns the selected lines into a checklist. Or: when a note has not been opened for a month, add a task to look at it.'),
        ),
      ),
      const SizedBox(height: 10),
      Text(
        'What is sent to the AI you chose in Settings: the description of the extension API and your request. No notes, no files. '
        'With an AI in the cloud that leaves this device.',
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(key: const ValueKey('magic-docs'), onPressed: () => showExtensionDocs(context), icon: const Icon(Icons.menu_book_outlined, size: 18), label: const Text('Read the documentation')),
      ),
      if (_failure != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text.verbatim(_failure!, key: const ValueKey('magic-failure'), style: TextStyle(color: scheme.error))),
    ]);
  }

  Widget _working(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tail = _partial.length > 400 ? '...${_partial.substring(_partial.length - 400)}' : _partial;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      const LinearProgressIndicator(key: ValueKey('magic-working')),
      const SizedBox(height: 12),
      Text(_problem == null ? tr('The AI is writing it...') : tr('The first try had a problem, the AI tries again: {problem}', {'problem': _problem}), style: TextStyle(color: scheme.onSurfaceVariant)),
      if (tail.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text.verbatim(tail, maxLines: 10, overflow: TextOverflow.fade, style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: scheme.onSurfaceVariant)),
        ),
    ]);
  }

  Widget _reading(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = _draft!;
    final m = d.manifest;
    Widget heading(String text) => Padding(padding: const EdgeInsets.only(top: 14, bottom: 4), child: Text(text, style: Theme.of(context).textTheme.labelLarge));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text.verbatim(m.name, style: Theme.of(context).textTheme.titleMedium),
      if (d.explanation.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text.verbatim(d.explanation, key: const ValueKey('magic-explanation'))),
      if (m.tools.isNotEmpty) ...[
        heading(tr('Tools (in the menu of selected text)')),
        for (final t in m.tools) Text.verbatim('• ${m.name}: ${t.title}'),
      ],
      if (m.actions.isNotEmpty) ...[
        heading(tr('Actions (for automations)')),
        for (final a in m.actions) Text.verbatim('• ${a.title}'),
      ],
      heading(tr('It asks to be allowed to:')),
      ...permissionLines(context, m),
      if (d.added.isNotEmpty)
        Text.verbatim(tr('The script uses {what}, which the AI had not asked for; it was added.', {'what': d.added.map((p) => p.id).join(', ')}), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      if (d.automations.isNotEmpty) ...[
        heading(tr('Automations it adds')),
        for (final a in d.automations)
          Text.verbatim('• ${a.event.label}${a.weeks == null ? '' : ' (${tr('{weeks} weeks', {'weeks': a.weeks})})'}${a.contains == null ? '' : ', ${tr('notes with {words} in the title', {'words': a.contains})}'}: ${m.actions.firstWhere((x) => x.id == a.action).title}'),
      ],
      Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const ValueKey('magic-script'),
          tilePadding: EdgeInsets.zero,
          title: Text(tr('The script')),
          children: [
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 260),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
              child: SingleChildScrollView(child: SelectableText(d.script, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('magic-change'),
            controller: _change,
            decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), hintText: tr('Something to change? Say it here')),
            onSubmitted: (_) => _askChange(d),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(key: const ValueKey('magic-change-go'), onPressed: () => _askChange(d), child: const Text('Change it')),
      ]),
      const SizedBox(height: 8),
      Text(
        'Install puts it in the list switched off and without any permission. Install and allow also switches it on and gives it the permissions above.',
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      if (_failure != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text.verbatim(_failure!, key: const ValueKey('magic-failure'), style: TextStyle(color: scheme.error))),
    ]);
  }

  void _askChange(MagicDraft d) {
    final change = _change.text.trim();
    if (change.isEmpty) return;
    _make(previous: d, change: change);
  }
}
