part of 'settings_screen.dart';

/// Which AI provider answers, and what the summary prompt says.
class _AiSettings extends StatefulWidget {
  final AiService ai;

  const _AiSettings({required this.ai});

  @override
  State<_AiSettings> createState() => _AiSettingsState();
}

class _AiSettingsState extends State<_AiSettings> {
  late final _system = TextEditingController(text: widget.ai.summaryConfig.system);
  late final _instruction = TextEditingController(text: widget.ai.summaryConfig.instruction);
  late SummaryLength _length = widget.ai.summaryConfig.length;

  @override
  void dispose() {
    _system.dispose();
    _instruction.dispose();
    super.dispose();
  }

  SummaryConfig get _edited =>
      SummaryConfig(system: _system.text.trim().isEmpty ? SummaryConfig.defaultSystem : _system.text, instruction: _instruction.text.trim().isEmpty ? SummaryConfig.defaultInstruction : _instruction.text, length: _length);

  void _fill(SummaryConfig c) {
    _system.text = c.system;
    _instruction.text = c.instruction;
    _length = c.length;
  }

  @override
  Widget build(BuildContext context) {
    final ai = widget.ai;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: ai,
      builder: (context, _) {
        final changed = _edited.encode() != ai.summaryConfig.encode();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('AI assistant', style: Theme.of(context,).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            'Highlight text and choose "Summarize" (more than two words), "Tell me more" or "Ask a question"; '
            'the sparkle button in a note opens an assistant that answers questions about the whole document. '
            'Who answers is up to you; the text you highlight goes to that provider only.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 12),
          for (final p in ai.providers) _provider(context, p, p.id == ai.provider?.id),
          const SizedBox(height: 16),
          Text('Prompt for "Summarize"', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('ai-system'),
            controller: _system,
            minLines: 2,
            maxLines: 6,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: tr('Standing instructions'), border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('ai-instruction'),
            controller: _instruction,
            minLines: 2,
            maxLines: 6,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: tr('Request'),
              helperText: tr('{text} is the highlighted text, {length} how long the summary should be'),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<SummaryLength>(
            key: const ValueKey('ai-length'),
            initialValue: _length,
            decoration: InputDecoration(labelText: tr('Length'), border: OutlineInputBorder()),
            items: [for (final l in SummaryLength.values) DropdownMenuItem(value: l, child: Text(l.label))],
            onChanged: (l) => setState(() => _length = l ?? _length),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            FilledButton(
              key: const ValueKey('ai-save'),
              onPressed: changed ? () => ai.setSummaryConfig(_edited) : null,
              child: const Text('Save'),
            ),
            TextButton(
              key: const ValueKey('ai-reset'),
              onPressed: _edited.isDefault && ai.summaryConfig.isDefault
                  ? null
                  : () {
                      setState(() => _fill(SummaryConfig.defaults));
                      ai.setSummaryConfig(SummaryConfig.defaults);
                    },
              child: const Text('Back to the standard prompt'),
            ),
            if (changed) Text('not saved yet', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
          ]),
          const SizedBox(height: 24),
          _PromptEditor(ai: ai, task: AiTask.explain, title: 'Prompt for "Tell me more"', helper: '{text} is the highlighted text'),
          const SizedBox(height: 24),
          _PromptEditor(
            ai: ai,
            task: AiTask.ask,
            title: 'Prompt for "Ask a question"',
            helper: '{text} is the highlighted text, {question} what you ask',
          ),
          const SizedBox(height: 24),
          _PromptEditor(
            ai: ai,
            task: AiTask.assistant,
            title: 'Prompt for the document assistant',
            helper: '{text} is the passages of the document found for the question, {question} what you ask',
          ),
        ]);
      },
    );
  }

  /// The sizes to choose from.
  Widget _models(BuildContext context, SelectableModels models) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Model', style: Theme.of(context).textTheme.labelLarge),
        for (final o in models.modelOptions)
          InkWell(
            key: ValueKey('ai-model-${o.id}'),
            onTap: o.supported && o.id != models.selectedModelId ? () => models.selectModel(o.id) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(
                  o.id == models.selectedModelId ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 20,
                  color: o.supported ? null : scheme.outline,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      tr(o.label) + (o.installed ? tr('  (downloaded)') : ''),
                      style: TextStyle(fontWeight: FontWeight.w500, color: o.supported ? null : scheme.outline),
                    ),
                    Text(o.supported ? o.detail : (o.reason ?? o.detail),
                        key: o.supported ? null : ValueKey('ai-model-reason-${o.id}'),
                        style: TextStyle(fontSize: 12, color: o.supported ? Colors.grey[600] : scheme.error)),
                  ]),
                ),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _provider(BuildContext context, TextModelProvider p, bool chosen) {
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final download = p is DownloadableModel ? p as DownloadableModel : null;
        final state = p.state;
        return Card(
          key: ValueKey('ai-provider-${p.id}'),
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(chosen ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(p.label, style: const TextStyle(fontWeight: FontWeight.w600))),
                if (!chosen)
                  TextButton(onPressed: () => widget.ai.chooseProvider(p.id), child: const Text('Use this')),
              ]),
              const SizedBox(height: 4),
              Text(p.description, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
              if (p is SelectableModels) _models(context, p as SelectableModels),
              if (p is OpenAiProvider) _OpenAiForm(provider: p),
              const SizedBox(height: 8),
              if (state == ProviderState.unavailable)
                Text(p.reason ?? 'Not available here.', key: const ValueKey('ai-unavailable'), style: TextStyle(color: Theme.of(context).colorScheme.error))
              else if (state == ProviderState.downloading && download != null)
                Row(children: [
                  Expanded(child: LinearProgressIndicator(value: download.progress > 0 ? download.progress : null)),
                  const SizedBox(width: 12),
                  Text('${(download.progress * 100).round()}%'),
                ])
              else
                Row(children: [
                  Icon(state == ProviderState.ready ? Icons.check_circle_outline : Icons.download_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(state == ProviderState.ready
                        ? 'Ready'
                        : tr('Needs a download of about {size} GB', {'size': download == null ? '?' : (download.sizeMb / 1000).toStringAsFixed(1)})),
                  ),
                  if (download != null && state == ProviderState.ready)
                    TextButton(onPressed: download.remove, child: const Text('Remove'))
                  else if (state == ProviderState.needsDownload)
                    FilledButton(key: const ValueKey('ai-download'), onPressed: p.prepare, child: const Text('Download')),
                ]),
              if (download?.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text.verbatim(tr('Download failed: {error}', {'error': download!.error}), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
            ]),
          ),
        );
      },
    );
  }
}

/// Address, model and key of the OpenAI-compatible provider, with a button that tries them.
class _OpenAiForm extends StatefulWidget {
  final OpenAiProvider provider;

  const _OpenAiForm({required this.provider});

  @override
  State<_OpenAiForm> createState() => _OpenAiFormState();
}

class _OpenAiFormState extends State<_OpenAiForm> {
  late final _url = TextEditingController(text: widget.provider.config.baseUrl);
  late final _model = TextEditingController(text: widget.provider.config.model);
  final _key = TextEditingController();
  bool _hidden = true;
  bool _testing = false;
  String? _result;
  bool _ok = false;

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  OpenAiConfig get _edited => OpenAiConfig(baseUrl: _url.text, model: _model.text);

  /// Saves; a key left empty here keeps the saved one.
  Future<void> _save() =>
      widget.provider.save(_edited, _key.text.isEmpty ? widget.provider.currentKey : _key.text);

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      // (inside the try: a keystore that cannot save is shown as the result, not lost; and the screen may be gone by the time it is done)
      await _save();
      final answer = await widget.provider.complete(
        const AiPrompt(system: 'Answer in one short sentence.', user: 'Say that the connection works.'),
        maxTokens: 30,
      );
      if (!mounted) return;
      setState(() {
        _ok = true;
        _result = answer.isEmpty ? tr('Connected (the answer was empty).') : tr('Connected: {answer}', {'answer': answer});
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _result = '$e'.replaceFirst('Bad state: ', '');
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          key: const ValueKey('openai-url'),
          controller: _url,
          onChanged: (_) => setState(() {}),
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: tr('Address'),
            helperText: tr('e.g. https://api.openai.com/v1 or http://localhost:11434/v1'),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('openai-model'),
          controller: _model,
          onChanged: (_) => setState(() {}),
          autocorrect: false,
          decoration: InputDecoration(labelText: tr('Model'), helperText: tr('e.g. gpt-4o-mini or llama3.2'), border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('openai-key'),
          controller: _key,
          obscureText: _hidden,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: tr('API key'),
            helperText: tr(widget.provider.hasKey
                ? 'A key is saved in this device\'s keystore; leave empty to keep it. Servers on your own machine often need none.'
                : 'Kept in this device\'s keystore. Servers on your own machine often need none.'),
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: tr(_hidden ? 'Show the key' : 'Hide the key'),
              icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              onPressed: () => setState(() => _hidden = !_hidden),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton(
            key: const ValueKey('openai-save'),
            onPressed: () async {
              await _save();
              _key.clear();
              if (mounted) setState(() => _result = null);
            },
            child: const Text('Save'),
          ),
          OutlinedButton(
            key: const ValueKey('openai-test'),
            onPressed: _testing || !_edited.complete ? null : _test,
            child: Text(_testing ? 'Trying...' : 'Save and try'),
          ),
          if (widget.provider.hasKey)
            TextButton(
              key: const ValueKey('openai-forget-key'),
              onPressed: () => widget.provider.save(_edited, '').then((_) => setState(() {})),
              child: const Text('Delete the key'),
            ),
        ]),
        if (_result != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_result!, key: const ValueKey('openai-result'), style: TextStyle(color: _ok ? scheme.primary : scheme.error)),
          ),
      ]),
    );
  }
}

/// The two texts of one task's prompt, with Save and a way back to the standard prompt.
class _PromptEditor extends StatefulWidget {
  final AiService ai;
  final AiTask task;
  final String title;
  final String helper;

  const _PromptEditor({required this.ai, required this.task, required this.title, required this.helper});

  @override
  State<_PromptEditor> createState() => _PromptEditorState();
}

class _PromptEditorState extends State<_PromptEditor> {
  late final _system = TextEditingController(text: widget.ai.template(widget.task).system);
  late final _instruction = TextEditingController(text: widget.ai.template(widget.task).instruction);

  String get _name => widget.task.name;

  @override
  void dispose() {
    _system.dispose();
    _instruction.dispose();
    super.dispose();
  }

  PromptTemplate get _edited => PromptTemplate(
        widget.task,
        system: _system.text.trim().isEmpty ? widget.task.defaultSystem : _system.text,
        instruction: _instruction.text.trim().isEmpty ? widget.task.defaultInstruction : _instruction.text,
      );

  @override
  Widget build(BuildContext context) {
    final saved = widget.ai.template(widget.task);
    final changed = _edited.encode() != saved.encode();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(widget.title, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      TextField(
        key: ValueKey('ai-$_name-system'),
        controller: _system,
        minLines: 2,
        maxLines: 6,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(labelText: tr('Standing instructions'), border: OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      TextField(
        key: ValueKey('ai-$_name-instruction'),
        controller: _instruction,
        minLines: 2,
        maxLines: 6,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(labelText: tr('Request'), helperText: tr(widget.helper), border: const OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        FilledButton(
          key: ValueKey('ai-$_name-save'),
          onPressed: changed ? () => widget.ai.setTemplate(_edited) : null,
          child: const Text('Save'),
        ),
        TextButton(
          key: ValueKey('ai-$_name-reset'),
          onPressed: _edited.isDefault && saved.isDefault
              ? null
              : () {
                  final d = PromptTemplate.defaults(widget.task);
                  setState(() {
                    _system.text = d.system;
                    _instruction.text = d.instruction;
                  });
                  widget.ai.setTemplate(d);
                },
          child: const Text('Back to the standard prompt'),
        ),
        if (changed) Text('not saved yet', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
      ]),
    ]);
  }
}

/// The kill switch for every AI feature of the app.
class _AiSwitchCard extends StatelessWidget {
  final AiSwitch aiSwitch;

  const _AiSwitchCard({required this.aiSwitch});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: aiSwitch,
      builder: (context, _) {
        final on = aiSwitch.enabled;
        return Card(
          margin: EdgeInsets.zero,
          color: on ? null : Theme.of(context).colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SwitchListTile.adaptive(
                key: const ValueKey('ai-switch'),
                contentPadding: EdgeInsets.zero,
                title: Text('AI features', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold,)),
                subtitle: Text(on ? 'On' : 'Off: nothing in the app uses AI'),
                value: on,
                onChanged: aiSwitch.setEnabled,
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  'Turn this off and every AI feature goes away at once: the assistant, summaries and questions about '
                  'highlighted text, smart task titles, reading handwriting and formulas. Nothing is run, and nothing is '
                  'sent to an AI service. Your downloads and settings below stay as they are.',
                  style: TextStyle(color: on ? Colors.grey[600] : Theme.of(context).colorScheme.onErrorContainer, fontSize: 13),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}
