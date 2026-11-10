import 'package:flutter/material.dart' hide Text;

import '../automations/automation_service.dart';
import '../automations/rule_writer.dart';
import '../data/note_data.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';

/// "Describe a rule": the person says what they want in their own words, the assistant writes the rule, and here it is looked at before
/// it is added: in a sentence, with what it would have touched. Rules are added switched off, unless the person switches them on here.
Future<void> showRuleWriter(BuildContext context, {required AutomationService service, required List<FolderEntry> folders}) => showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680), child: _RuleWriter(service: service, folders: folders)),
      ),
    );

class _RuleWriter extends StatefulWidget {
  final AutomationService service;
  final List<FolderEntry> folders;

  const _RuleWriter({required this.service, required this.folders});

  @override
  State<_RuleWriter> createState() => _RuleWriterState();
}

class _RuleWriterState extends State<_RuleWriter> {
  final _request = TextEditingController();
  bool _writing = false;
  String? _problem;
  RuleDrafts? _drafts;
  final _added = <String>{};
  final _previews = <String, RulePreview>{};

  @override
  void dispose() {
    _request.dispose();
    super.dispose();
  }

  String _folderName(String? id) => widget.folders.where((f) => f.id == id).firstOrNull?.name ?? tr('a folder that is gone');

  Future<void> _write() async {
    final text = _request.text.trim();
    if (text.isEmpty || _writing) return;
    setState(() {
      _writing = true;
      _problem = null;
      _drafts = null;
      _added.clear();
      _previews.clear();
    });
    try {
      final drafts = await widget.service.writeRules(text);
      if (!mounted) return;
      setState(() => _drafts = drafts);
      for (final d in drafts.rules) {
        final p = await widget.service.preview(d.rule).catchError((Object _) => RulePreview(tr('It could not be looked at.'), const []));
        if (mounted) setState(() => _previews[d.rule.id] = p);
      }
    } catch (e) {
      if (mounted) setState(() => _problem = '$e'.replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  Future<void> _add(RuleDraft d, {required bool on}) async {
    await widget.service.add(d.rule.copyWith(enabled: on));
    if (mounted) setState(() => _added.add(d.rule.id));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final drafts = _drafts;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Describe a rule'), style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(tr('Say what should happen by itself, in your own words. The assistant writes the rule; you look at it, and at what it would have touched, before it is switched on.'),
            style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('rule-request'),
          controller: _request,
          minLines: 2,
          maxLines: 4,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(border: const OutlineInputBorder(), hintText: tr('For example: when I close a note in Physics, give it the tag lecture')),
        ),
        const SizedBox(height: 8),
        Row(children: [
          FilledButton(
            key: const ValueKey('rule-write'),
            onPressed: _writing || _request.text.trim().isEmpty ? null : _write,
            child: Text(tr('Write the rule')),
          ),
          if (_writing) const Padding(padding: EdgeInsets.only(left: 12), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator.adaptive(strokeWidth: 2))),
          const Spacer(),
          TextButton(key: const ValueKey('rule-close'), onPressed: () => Navigator.pop(context), child: Text(tr('Close'))),
        ]),
        if (_problem != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text.verbatim(_problem!, key: const ValueKey('rule-problem'), style: TextStyle(color: scheme.error))),
        if (drafts != null)
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              if (drafts.rules.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(tr('The assistant could not make a rule of that with what automations can do. Try saying it another way.'), key: const ValueKey('rule-none')),
                ),
              for (final d in drafts.rules)
                Card(
                  key: ValueKey('rule-draft-${d.rule.id}'),
                  margin: const EdgeInsets.only(top: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text.verbatim(describeRule(d.rule, folderName: _folderName), style: const TextStyle(fontWeight: FontWeight.w600)),
                      for (final n in d.notes) Padding(padding: const EdgeInsets.only(top: 4), child: Text.verbatim(tr(n), style: TextStyle(color: scheme.error, fontSize: 12))),
                      const SizedBox(height: 8),
                      if (_previews[d.rule.id] case final p?) ...[
                        Text.verbatim(p.headline, key: ValueKey('rule-preview-${d.rule.id}')),
                        if (p.examples.isNotEmpty) Text.verbatim(p.examples.join(', '), style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                      ] else
                        Text(tr('Looking at what it would touch...'), style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                      const SizedBox(height: 8),
                      if (_added.contains(d.rule.id))
                        Text(tr('Added: see the list of automations.'), key: ValueKey('rule-added-${d.rule.id}'))
                      else
                        Wrap(spacing: 8, children: [
                          OutlinedButton(key: ValueKey('rule-add-off-${d.rule.id}'), onPressed: () => _add(d, on: false), child: Text(tr('Add, switched off'))),
                          FilledButton(key: ValueKey('rule-add-on-${d.rule.id}'), onPressed: d.notes.isEmpty ? () => _add(d, on: true) : null, child: Text(tr('Add and switch on'))),
                        ]),
                    ]),
                  ),
                ),
              if (drafts.rejected.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(trCount(drafts.rejected.length, '{n} line was left out', '{n} lines were left out')),
                  children: [for (final r in drafts.rejected) Align(alignment: Alignment.centerLeft, child: Text.verbatim(r, style: const TextStyle(fontSize: 12)))],
                ),
            ]),
          ),
      ]),
    );
  }
}
