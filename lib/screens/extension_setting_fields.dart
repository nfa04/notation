import 'package:flutter/material.dart' hide Text;

import '../extensions/extension_doors.dart';
import '../extensions/extension_service.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';

/// The settings an extension lists in its manifest, drawn with the app's own controls and kept as they are changed. A secret (a key, a
/// token) is only ever set or removed here: its value is not shown again.
class ExtensionSettingFields extends StatefulWidget {
  final ExtensionService service;
  final InstalledExtension extension;
  const ExtensionSettingFields({super.key, required this.service, required this.extension});

  @override
  State<ExtensionSettingFields> createState() => _ExtensionSettingFieldsState();
}

class _ExtensionSettingFieldsState extends State<ExtensionSettingFields> {
  Map<String, Object?> _values = const {};
  final _secret = <String, bool>{};
  final _controllers = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final values = await widget.service.settingsOf(widget.extension.id);
    final secrets = <String, bool>{
      for (final f in widget.extension.manifest.settings)
        if (f.type == FieldType.secret) f.id: await widget.service.hasSecret(widget.extension.id, f.id),
    };
    if (!mounted) return;
    setState(() {
      _values = values;
      _secret
        ..clear()
        ..addAll(secrets);
    });
  }

  Future<void> _set(String field, Object? value) async {
    await widget.service.setSetting(widget.extension.id, field, value);
    if (!mounted) return;
    setState(() => _values = {..._values, field: value});
  }

  Future<void> _askSecret(ExtensionField f) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: Text.verbatim(f.title),
        content: TextField(key: ValueKey('setting-secret-input-${f.id}'), controller: controller, obscureText: true, autofocus: true, decoration: InputDecoration(helperText: tr('It is kept in the secure storage of this device and never shown again.'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('setting-secret-save'), onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    try {
      await widget.service.setSetting(widget.extension.id, f.id, value);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim('$e')));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final fields = widget.extension.manifest.settings;
    if (fields.isEmpty) return const SizedBox.shrink();
    final id = widget.extension.id;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 8),
      Text(tr('Settings'), style: Theme.of(context).textTheme.labelLarge),
      for (final f in fields)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: switch (f.type) {
            FieldType.boolean => SwitchListTile.adaptive(
                key: ValueKey('setting-$id-${f.id}'), dense: true, contentPadding: EdgeInsets.zero, title: Text.verbatim(f.title), value: _values[f.id] == true, onChanged: (v) => _set(f.id, v)),
            FieldType.choice => DropdownButtonFormField<String>(
                key: ValueKey('setting-$id-${f.id}'),
                initialValue: f.choices.containsKey(_values[f.id]) ? _values[f.id] as String : null,
                decoration: InputDecoration(labelText: f.title, isDense: true),
                items: [for (final c in f.choices.entries) DropdownMenuItem(value: c.key, child: Text.verbatim(c.value))],
                onChanged: (v) => _set(f.id, v),
              ),
            FieldType.secret => ListTile(
                key: ValueKey('setting-$id-${f.id}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text.verbatim(f.title),
                subtitle: Text(_secret[f.id] == true ? tr('Set') : tr('Not set')),
                trailing: Wrap(children: [
                  TextButton(onPressed: () => _askSecret(f), child: Text(_secret[f.id] == true ? tr('Replace') : tr('Set'))),
                  if (_secret[f.id] == true)
                    TextButton(
                      key: ValueKey('setting-remove-$id-${f.id}'),
                      onPressed: () async {
                        await widget.service.setSetting(id, f.id, null);
                        await _load();
                      },
                      child: const Text('Remove'),
                    ),
                ]),
              ),
            _ => TextFormField(
                key: ValueKey('setting-$id-${f.id}'),
                controller: _controllers[f.id] ??= TextEditingController(text: _values[f.id] == null ? '' : '${_values[f.id]}'),
                keyboardType: f.type == FieldType.number ? TextInputType.number : TextInputType.text,
                decoration: InputDecoration(labelText: f.title, isDense: true, hintText: f.type == FieldType.date ? 'YYYY-MM-DD' : null),
                onChanged: (v) => _set(f.id, v.isEmpty ? null : (f.type == FieldType.number ? num.tryParse(v) : v)),
              ),
          },
        ),
    ]);
  }
}
