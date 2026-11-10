import 'package:flutter/material.dart' hide Text;

import '../extensions/extension_manifest.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';

/// What an extension asks to be allowed to do, one line each, with what a permission is about (the websites of `network`, the events of
/// `events.emit`). A permission that [before] (the version that is installed) did not ask for is marked as new.
List<Widget> permissionLines(BuildContext context, ExtensionManifest m, {ExtensionManifest? before}) {
  final scheme = Theme.of(context).colorScheme;
  return [
    if (m.permissions.isEmpty) Text(tr('Nothing: it only works on the text it is given.')),
    for (final p in m.permissions)
      Padding(
        key: ValueKey('asks-${p.id}'),
        padding: const EdgeInsets.only(bottom: 2),
        child: Text.verbatim(
          '• ${tr(p.description)}'
          '${p == ExtensionPermission.network ? ' (${m.hosts.join(', ')})' : ''}'
          '${p == ExtensionPermission.eventsEmit ? ' (${m.events.map((e) => e.title).join(', ')})' : ''}'
          '${before != null && !before.permissions.contains(p) ? '  ${tr('(new)')}' : ''}',
          style: TextStyle(color: scheme.error),
        ),
      ),
  ];
}

/// Shows what [m] is and what it asks to be allowed to do, before it is installed. True when the person says to install it. [before] is
/// the installed version, if this is an update.
Future<bool> confirmInstall(BuildContext context, ExtensionManifest m, {ExtensionManifest? before}) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      Widget heading(String text) => Padding(padding: const EdgeInsets.only(top: 12, bottom: 4), child: Text(text, style: Theme.of(context).textTheme.labelLarge));
      return PlatformAlertDialog(
        key: const ValueKey('extension-review'),
        title: Text.verbatim('${m.name}  ·  ${m.version}'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (m.author.isNotEmpty) Text.verbatim(m.author, style: TextStyle(color: scheme.onSurfaceVariant)),
              if (m.description.isNotEmpty) Text.verbatim(m.description),
              if (before != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(tr('This replaces version {version}.', {'version': before.version}), style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
              if (m.tools.isNotEmpty) ...[
                heading(tr('Tools (in the menu of selected text)')),
                for (final t in m.tools) Text.verbatim('• ${m.name}: ${t.title}'),
              ],
              if (m.actions.isNotEmpty) ...[
                heading(tr('Actions (for automations)')),
                for (final a in m.actions) Text.verbatim('• ${a.title}'),
              ],
              heading(tr('It asks to be allowed to:')),
              ...permissionLines(context, m, before: before),
              const SizedBox(height: 12),
              Text(
                tr('It is installed switched off and without any permission. You switch it on and give it these in Settings.'),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(key: const ValueKey('extension-review-cancel'), onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('extension-review-install'), onPressed: () => Navigator.pop(context, true), child: const Text('Install')),
        ],
      );
    },
  );
  return yes ?? false;
}
