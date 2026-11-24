import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../ai/openai_provider.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';

/// The services that speak the OpenAI chat API, as a plain list: the one that answers is marked, a tap on another makes it the one,
/// the pencil edits one, and "Add a service" sets up another. Everything about one service is in one dialog ([_ServiceEditor]).
class OpenAiProvidersSection extends StatelessWidget {
  final OpenAiProvider provider;

  const OpenAiProvidersSection({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: provider,
      builder: (context, _) {
        final profiles = provider.profiles;
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Your services'), style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            for (final p in profiles)
              _ServiceRow(
                key: ValueKey('openai-service-${p.id}'),
                profile: p,
                active: p.id == provider.activeProfile.id,
                hasKey: provider.profileHasKey(p.id),
                onUse: () => provider.selectProfile(p.id),
                onEdit: () => showDialog<void>(context: context, builder: (_) => _ServiceEditor(provider: provider, profile: p)),
              ),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              OutlinedButton.icon(
                key: const ValueKey('openai-add-service'),
                icon: const Icon(Symbols.add, size: 18),
                label: Text(tr('Add a service')),
                onPressed: () => showDialog<void>(context: context, builder: (_) => _ServiceEditor(provider: provider)),
              ),
              if (!provider.config.complete)
                Text(tr('Set up a service to use it.'), style: TextStyle(color: scheme.error, fontSize: 12)),
            ]),
          ]),
        );
      },
    );
  }
}

class _ServiceRow extends StatelessWidget {
  final OpenAiProfile profile;
  final bool active;
  final bool hasKey;
  final VoidCallback onUse;
  final VoidCallback onEdit;

  const _ServiceRow({super.key, required this.profile, required this.active, required this.hasKey, required this.onUse, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = profile.config;
    final host = Uri.tryParse(c.baseUrl.trim())?.host ?? '';
    final String detail = c.model.trim().isEmpty ? tr('No model chosen yet') : '${c.model.trim()} · $host';
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onUse,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Icon(active ? Symbols.radio_button_checked : Symbols.radio_button_unchecked, size: 20, color: active ? scheme.primary : null),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text.verbatim(profile.title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                if (active)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(tr('In use'), style: TextStyle(fontSize: 12, color: scheme.primary)),
                  ),
              ]),
              Text.verbatim(detail, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.complete ? scheme.onSurfaceVariant : scheme.error)),
            ]),
          ),
          if (hasKey) Icon(Symbols.vpn_key, size: 16, color: scheme.onSurfaceVariant),
          IconButton(key: ValueKey('openai-edit-${profile.id}'), tooltip: tr('Edit'), icon: const Icon(Symbols.edit, size: 20), onPressed: onEdit),
        ]),
      ),
    );
  }
}

/// Well-known services: tapping one fills in the address (and the name, when there is none).
const _presets = <(String, String)>[
  ('OpenAI', 'https://api.openai.com/v1'),
  ('OpenRouter', 'https://openrouter.ai/api/v1'),
  ('Groq', 'https://api.groq.com/openai/v1'),
  ('Gemini', 'https://generativelanguage.googleapis.com/v1beta/openai'),
  ('Ollama', 'http://localhost:11434/v1'),
  ('LM Studio', 'http://localhost:1234/v1'),
];

/// One service: add it ([profile] null) or change it. Nothing is kept until Save.
class _ServiceEditor extends StatefulWidget {
  final OpenAiProvider provider;
  final OpenAiProfile? profile;

  const _ServiceEditor({required this.provider, this.profile});

  @override
  State<_ServiceEditor> createState() => _ServiceEditorState();
}

class _ServiceEditorState extends State<_ServiceEditor> {
  late final _name = TextEditingController(text: widget.profile?.name ?? '');
  late final _url = TextEditingController(text: widget.profile == null ? '' : widget.profile!.config.baseUrl);
  late final _model = TextEditingController(text: widget.profile?.config.model ?? '');
  late final _pause = TextEditingController(text: (widget.profile?.config.pauseSeconds ?? 0) == 0 ? '' : '${widget.profile!.config.pauseSeconds}');
  late final _key = TextEditingController(text: widget.profile == null ? '' : widget.provider.keyOf(widget.profile!.id));
  bool _hidden = true;
  bool _testing = false;
  bool _confirmDelete = false;
  String? _result;
  bool _ok = false;

  @override
  void dispose() {
    for (final c in [_name, _url, _model, _pause, _key]) {
      c.dispose();
    }
    super.dispose();
  }

  OpenAiConfig get _edited => OpenAiConfig(
        baseUrl: _url.text.trim(),
        model: _model.text.trim(),
        pauseSeconds: (int.tryParse(_pause.text.trim()) ?? 0).clamp(0, OpenAiConfig.maxPauseSeconds),
      );

  void _preset(String name, String url) {
    final known = _presets.any((p) => p.$1 == _name.text.trim());
    setState(() {
      _url.text = url;
      if (_name.text.trim().isEmpty || known) _name.text = name;
      _result = null;
    });
  }

  Future<void> _chooseModel() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _ModelPicker(load: () => widget.provider.listModelsAt(_url.text, _key.text), current: _model.text.trim()),
    );
    if (picked != null) setState(() => _model.text = picked);
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      final answer = await widget.provider.tryOut(_edited, _key.text);
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

  Future<void> _save() async {
    final p = widget.provider;
    try {
      final id = widget.profile?.id ?? (await p.addProfile()).id;
      await p.save(_edited, _key.text, name: _name.text, id: id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      // (a keystore that cannot save is shown, not lost)
      if (!mounted) return;
      setState(() {
        _ok = false;
        _result = '$e'.replaceFirst('Bad state: ', '');
      });
    }
  }

  Future<void> _delete() async {
    await widget.provider.removeProfile(widget.profile!.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final editing = widget.profile != null;
    return PlatformAlertDialog(
      title: Text(tr(editing ? 'Edit service' : 'Add a service')),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Start from'), style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Wrap(spacing: 6, runSpacing: 0, children: [
            for (final (name, url) in _presets)
              ActionChip(key: ValueKey('openai-preset-$name'), label: Text.verbatim(name), visualDensity: VisualDensity.compact, onPressed: () => _preset(name, url)),
          ]),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('openai-name'),
            controller: _name,
            decoration: InputDecoration(labelText: tr('Name'), helperText: tr('Only for you, to tell your services apart.'), border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('openai-url'),
            controller: _url,
            onChanged: (_) => setState(() => _result = null),
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: tr('Address'),
              helperText: tr('Up to and including the version, e.g. https://api.openai.com/v1'),
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('openai-key'),
            controller: _key,
            onChanged: (_) => setState(() => _result = null),
            obscureText: _hidden,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: tr('API key'),
              helperText: tr('Kept in this device\'s keystore. Servers on your own machine often need none: leave it empty.'),
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: tr(_hidden ? 'Show the key' : 'Hide the key'),
                icon: Icon(_hidden ? Symbols.visibility : Symbols.visibility_off),
                onPressed: () => setState(() => _hidden = !_hidden),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('openai-model'),
            controller: _model,
            onChanged: (_) => setState(() => _result = null),
            autocorrect: false,
            decoration: InputDecoration(
              labelText: tr('Model'),
              helperText: tr('Type a name (gpt-4o-mini, llama3.2) or choose one the service offers.'),
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                key: const ValueKey('openai-choose-model'),
                tooltip: tr('Choose from the service\'s models'),
                icon: const Icon(Symbols.list),
                onPressed: _url.text.trim().isEmpty ? null : _chooseModel,
              ),
            ),
          ),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const ValueKey('openai-advanced'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: Text(tr('Advanced'), style: Theme.of(context).textTheme.labelLarge),
              children: [
                TextField(
                  key: const ValueKey('openai-pause'),
                  controller: _pause,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: tr('Pause between requests (seconds)'),
                    helperText: tr('Empty: none. Raise it if the service says there were too many requests (the free plan of Gemini allows only a few a minute).'),
                    helperMaxLines: 4,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text.verbatim(_result!, key: const ValueKey('openai-result'), style: TextStyle(color: _ok ? scheme.primary : scheme.error)),
            ),
        ]),
      ),
      actions: [
        if (editing)
          TextButton(
            key: const ValueKey('openai-delete'),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: _confirmDelete ? _delete : () => setState(() => _confirmDelete = true),
            child: Text(tr(_confirmDelete ? 'Really delete?' : 'Delete')),
          ),
        OutlinedButton(
          key: const ValueKey('openai-test'),
          onPressed: _testing || !_edited.complete ? null : _test,
          child: Text(tr(_testing ? 'Trying...' : 'Test')),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Cancel'))),
        FilledButton(key: const ValueKey('openai-save'), onPressed: _edited.complete ? _save : null, child: Text(tr('Save'))),
      ],
    );
  }
}

/// The models a service offers, with a filter; pops the one that is tapped.
class _ModelPicker extends StatefulWidget {
  final Future<List<String>> Function() load;
  final String current;

  const _ModelPicker({required this.load, required this.current});

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  late Future<List<String>> _models = widget.load();
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    return PlatformAlertDialog(
      title: Text(tr('Choose a model')),
      content: SizedBox(
        width: 420,
        height: 400,
        child: FutureBuilder<List<String>>(
          future: _models,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            if (snap.hasError) {
              return Column(mainAxisSize: MainAxisSize.min, children: [
                Text.verbatim('${snap.error}'.replaceFirst('Bad state: ', '')),
                const SizedBox(height: 8),
                Text(tr('Not every service lists its models. You can still type the name.')),
                TextButton(onPressed: () => setState(() { _models = widget.load(); }), child: Text(tr('Try again'))),
              ]);
            }
            final all = snap.data!;
            final shown = all.where((m) => m.toLowerCase().contains(_filter.toLowerCase())).toList();
            return Column(children: [
              TextField(
                key: const ValueKey('openai-model-filter'),
                autofocus: true,
                decoration: InputDecoration(prefixIcon: const Icon(Symbols.search), hintText: tr('Search {count} models', {'count': all.length})),
                onChanged: (v) => setState(() => _filter = v),
              ),
              Expanded(
                child: ListView(children: [
                  for (final m in shown)
                    ListTile(
                      dense: true,
                      title: Text.verbatim(m),
                      trailing: m == widget.current ? const Icon(Symbols.check, size: 18) : null,
                      onTap: () => Navigator.of(context).pop(m),
                    ),
                ]),
              ),
            ]);
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Cancel')))],
    );
  }
}
