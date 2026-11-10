
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide Text;

import '../extensions/extension_manifest.dart';
import '../ai/ai_service.dart';
import '../automations/automation_service.dart';
import '../extensions/extension_service.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import 'extension_docs_dialog.dart';
import 'extension_review.dart';
import 'magic_extension_dialog.dart';
import '../style/platform_dialog.dart';

const _sampleManifest = '''{
  "id": "shout",
  "name": "Shout",
  "version": "1.0.0",
  "description": "Makes the selected text LOUD, and counts its words.",
  "permissions": [],
  "tools": [
    { "id": "loud", "title": "Make it loud" },
    { "id": "count", "title": "Count the words" }
  ]
}''';

const _sampleScript = '''// The tools return a string (it replaces the selection) or an object
// { replace, insert, message }. Everything of the app is in the object "notation".
notation.tool('loud', (ctx) => ctx.text.toUpperCase() + '!');
notation.tool('count', (ctx) => ({ message: ctx.text.trim().split(/\\s+/).length + ' words' }));
''';

/// Settings: the extensions (scripts the person installed). Each runs in a sandbox, can only do what it was given leave to, and is off
/// until it is switched on.
class ExtensionSettings extends StatefulWidget {
  final ExtensionService service;

  /// The AI that makes extensions from a description ("Create with AI"); null hides the button. [automations] gets the rules it asks for.
  final AiService? ai;
  final AutomationService? automations;

  const ExtensionSettings({super.key, required this.service, this.ai, this.automations});

  @override
  State<ExtensionSettings> createState() => _ExtensionSettingsState();
}

class _ExtensionSettingsState extends State<ExtensionSettings> {
  Future<void> _guard(Future<void> Function() job) async {
    try {
      await job();
    } on ManifestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Could not install it: {error}', {'error': e.message}))));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Could not install it: {error}', {'error': e}))));
    }
  }

  /// Says it is there, and that it is off.
  void _installed(InstalledExtension e) {
    if (!mounted) return;
    final tools = e.manifest.tools.map((t) => t.title).join(', ');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text.verbatim(tools.isEmpty
          ? tr('Installed {name}. It is off until you switch it on.', {'name': e.manifest.name})
          : tr('Installed {name}. It is off until you switch it on; then its tools ({tools}) are in the menu of selected text, as "{name}: ...".', {'name': e.manifest.name, 'tools': tools})),
      duration: const Duration(seconds: 8),
    ));
  }

  Future<void> _installFile() => _guard(() async {
        final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['zip']);
        if (file == null) return;
        final bytes = await file.readAsBytes();
        final package = widget.service.inspectZip(bytes);
        if (!await _confirm(package)) return;
        _installed(await widget.service.installSource(package.manifestText, package.script));
      });

  /// Shows what the extension asks for; true when the person wants it installed.
  Future<bool> _confirm(ExtensionPackage package) async {
    if (!mounted) return false;
    return confirmInstall(context, package.manifest, before: widget.service.byId(package.manifest.id)?.manifest);
  }

  Future<void> _magic() async {
    final made = await showMagicExtension(context, ai: widget.ai!, extensions: widget.service, automations: widget.automations);
    if (made != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(made.message), duration: const Duration(seconds: 8)));
  }

  Future<void> _write() async {
    final written = await showDialog<(String, String)>(context: context, builder: (_) => const _WriteDialog());
    if (written == null) return;
    await _guard(() async {
      final package = widget.service.inspectSource(written.$1, written.$2);
      if (!await _confirm(package)) return;
      _installed(await widget.service.installSource(package.manifestText, package.script));
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final service = widget.service;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Extensions', style: Theme.of(context,).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            'Extensions are small scripts (JavaScript) that add tools to the menu of selected text and actions to the automations. '
            'Each runs in a sandbox: it cannot reach your files, the network or your notes unless you give it that permission, it is stopped if it runs '
            'too long or uses too much memory, and it is off until you switch it on. Only install extensions from people you trust.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          if (!service.canRun) ...[
            const SizedBox(height: 8),
            Text(kIsWeb ? tr('Extensions do not run in the browser: a script there could reach your notes, as the browser cannot keep it apart from them. Use the app on a computer or phone for them.') : tr('The script engine is not available on this device: extensions cannot run.'), style: TextStyle(color: scheme.error, fontSize: 13)),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 8, children: [
            FilledButton.tonalIcon(key: const ValueKey('extension-install-file'), onPressed: _installFile, icon: const Icon(Icons.upload_file, size: 18), label: const Text('Install from a file (.zip)')),
            if (widget.ai != null && widget.ai!.provider != null)
              FilledButton.icon(key: const ValueKey('extension-magic'), onPressed: _magic, icon: const Icon(Icons.auto_fix_high, size: 18), label: const Text('Create with AI')),
            OutlinedButton.icon(key: const ValueKey('extension-write'), onPressed: _write, icon: const Icon(Icons.code, size: 18), label: const Text('Write one')),
          ]),
          const SizedBox(height: 8),
          if (service.installed.isEmpty) Text(tr('No extensions yet.'), style: TextStyle(color: scheme.onSurfaceVariant)),
          for (final e in service.installed) _card(context, service, e),
        ]);
      },
    );
  }

  Widget _card(BuildContext context, ExtensionService service, InstalledExtension e) {
    final m = e.manifest;
    return Card(
      key: ValueKey('extension-${m.id}'),
      margin: const EdgeInsets.only(top: 8),
      child: ExpansionTile(
        title: Text.verbatim('${m.name}  ·  ${m.version}'),
        subtitle: Text.verbatim([if (m.author.isNotEmpty) m.author, if (m.description.isNotEmpty) m.description].join(' · ')),
        trailing: Switch.adaptive(key: ValueKey('extension-on-${m.id}'), value: e.enabled, onChanged: (v) => service.setEnabled(m.id, v)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.tools.isNotEmpty) Text.verbatim('${tr('Tools')}: ${m.tools.map((t) => t.title).join(', ')}'),
          if (m.actions.isNotEmpty) Text.verbatim('${tr('Actions')}: ${m.actions.map((a) => a.title).join(', ')}'),
          const SizedBox(height: 8),
          Text(tr('It asks to be allowed to:'), style: Theme.of(context).textTheme.labelLarge),
          if (m.permissions.isEmpty) Text(tr('Nothing: it only works on the text it is given.')),
          for (final p in m.permissions)
            SwitchListTile.adaptive(
              key: ValueKey('extension-${m.id}-${p.id}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text.verbatim(tr(p.description)),
              subtitle: switch (p) {
                ExtensionPermission.network => Text.verbatim(m.hosts.join(', ')),
                ExtensionPermission.eventsEmit => Text.verbatim(m.events.map((e) => e.title).join(', ')),
                _ => null,
              },
              value: e.granted.contains(p),
              onChanged: (v) => service.setGranted(m.id, p, v),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(key: ValueKey('extension-remove-${m.id}'), onPressed: () => service.remove(m.id), icon: const Icon(Icons.delete_outline, size: 18), label: const Text('Remove')),
          ),
        ],
      ),
    );
  }
}

/// A manifest and a script to write, with an example in them.
class _WriteDialog extends StatefulWidget {
  const _WriteDialog();

  @override
  State<_WriteDialog> createState() => _WriteDialogState();
}

class _WriteDialogState extends State<_WriteDialog> {
  final _manifest = TextEditingController(text: _sampleManifest);
  final _script = TextEditingController(text: _sampleScript);

  @override
  void dispose() {
    _manifest.dispose();
    _script.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlatformAlertDialog(
        title: const Text('Write an extension'),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(key: const ValueKey('extension-docs'), onPressed: () => showExtensionDocs(context), icon: const Icon(Icons.menu_book_outlined, size: 18), label: const Text('Read the documentation')),
              ),
              const Text('The manifest says what it is called, what it adds and what it asks to be allowed to do (JSON):'),
              const SizedBox(height: 6),
              TextField(
                key: const ValueKey('extension-manifest'),
                controller: _manifest,
                maxLines: 10,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
              ),
              const SizedBox(height: 12),
              const Text('The script (JavaScript):'),
              const SizedBox(height: 6),
              TextField(
                key: const ValueKey('extension-script'),
                controller: _script,
                maxLines: 10,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('extension-save'), onPressed: () => Navigator.pop(context, (_manifest.text, _script.text)), child: const Text('Install')),
        ],
      );
}
