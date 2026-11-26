import 'package:flutter/material.dart' hide Text;

import '../extensions/door_results.dart';
import '../extensions/extension_doors.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';

/// The questions an extension may ask (`notation.ui.confirm`, `choose`, `form`), drawn by the app so that every extension's question
/// looks like one of the app's own and says which extension asks. [kind] and [args] are what `ExtensionRuntime` checked. The answer
/// is `true`/`false` for a confirmation, the chosen text (null: cancelled) for a choice, and the values by field id (null:
/// cancelled) for a form.
Future<Object?> askPersonDialog(BuildContext context, String extensionName, String kind, Map<String, Object?> args) async {
  switch (kind) {
    case 'confirm':
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => PlatformAlertDialog(
          title: Text.verbatim(extensionName),
          content: Text.verbatim('${args['text']}'),
          actions: [
            TextButton(key: const ValueKey('ask-no'), onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(key: const ValueKey('ask-yes'), onPressed: () => Navigator.pop(context, true), child: const Text('OK')),
          ],
        ),
      );
      return ok == true;
    case 'choose':
      return showDialog<String>(
        context: context,
        builder: (context) => PlatformAlertDialog(
          title: Text.verbatim('$extensionName: ${args['title']}'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final item in (args['items'] as List).cast<String>()) ListTile(key: ValueKey('ask-choice-$item'), title: Text.verbatim(item), onTap: () => Navigator.pop(context, item)),
              ]),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
        ),
      );
    case 'form':
      final fields = [
        for (final f in (args['fields'] as List).cast<Map>())
          ExtensionField(
            f['id'] as String,
            f['title'] as String,
            FieldType.byId(f['type']) ?? FieldType.text,
            initial: f['default'],
            choices: {for (final c in (f['choices'] as List? ?? const []).cast<String>()) c: c},
          ),
      ];
      return showDialog<Map<String, Object?>>(
        context: context,
        builder: (context) => _FormDialog(title: '$extensionName: ${args['title']}', fields: fields),
      );
  }
  return null;
}

class _FormDialog extends StatefulWidget {
  final String title;
  final List<ExtensionField> fields;
  const _FormDialog({required this.title, required this.fields});

  @override
  State<_FormDialog> createState() => _FormDialogState();
}

class _FormDialogState extends State<_FormDialog> {
  late final Map<String, Object?> _values = {for (final f in widget.fields) f.id: f.initial ?? (f.type == FieldType.boolean ? false : (f.type == FieldType.choice ? f.choices.keys.first : ''))};
  late final Map<String, TextEditingController> _controllers = {
    for (final f in widget.fields)
      if (f.type == FieldType.text || f.type == FieldType.number || f.type == FieldType.date) f.id: TextEditingController(text: '${_values[f.id]}'),
  };

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, Object?> _result() => {
        for (final f in widget.fields)
          f.id: switch (f.type) {
            FieldType.number => num.tryParse(_controllers[f.id]!.text.trim()),
            FieldType.text || FieldType.date => _controllers[f.id]!.text,
            _ => _values[f.id],
          },
      };

  @override
  Widget build(BuildContext context) => PlatformAlertDialog(
        title: Text.verbatim(widget.title),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final f in widget.fields)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: switch (f.type) {
                    FieldType.boolean => SwitchListTile(key: ValueKey('ask-field-${f.id}'), contentPadding: EdgeInsets.zero, title: Text.verbatim(f.title), value: _values[f.id] == true, onChanged: (v) => setState(() => _values[f.id] = v)),
                    FieldType.choice => DropdownButtonFormField<String>(
                        key: ValueKey('ask-field-${f.id}'),
                        initialValue: '${_values[f.id]}',
                        decoration: InputDecoration(labelText: f.title),
                        items: [for (final c in f.choices.entries) DropdownMenuItem(value: c.key, child: Text.verbatim(c.value))],
                        onChanged: (v) => setState(() => _values[f.id] = v),
                      ),
                    _ => TextField(
                        key: ValueKey('ask-field-${f.id}'),
                        controller: _controllers[f.id],
                        keyboardType: f.type == FieldType.number ? TextInputType.number : TextInputType.text,
                        decoration: InputDecoration(labelText: f.title, hintText: f.type == FieldType.date ? 'YYYY-MM-DD' : null),
                      ),
                  },
                ),
            ]),
          ),
        ),
        actions: [
          TextButton(key: const ValueKey('ask-cancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('ask-ok'), onPressed: () => Navigator.pop(context, _result()), child: const Text('OK')),
        ],
      );
}

/// What a place passes an extension so that its questions are asked in dialogs on [context]; [extensionName] says who asks.
InteractiveApi interactiveApiFor(BuildContext context, String extensionName, {void Function(String text, double? fraction)? onProgress}) => InteractiveApi(
      onMessage: (text) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(text)));
      },
      onAsk: (kind, args) async {
        if (!context.mounted) return null;
        return askPersonDialog(context, extensionName, kind, args);
      },
      onProgress: onProgress,
    );
