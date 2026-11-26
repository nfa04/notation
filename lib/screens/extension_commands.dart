import 'package:flutter/material.dart' hide Text;
import 'package:material_symbols_icons/symbols.dart';

import '../extensions/extension_doors.dart';
import '../extensions/extension_host.dart';
import '../extensions/extension_service.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';

typedef CommandEntry = ({InstalledExtension extension, ExtensionCommand command});

/// Runs [entry] with [api] (which says where it runs and what it can reach) and tells the person what came of it.
Future<void> runExtensionCommand(BuildContext context, ExtensionService service, CommandEntry entry, ExtensionApi api, {Map<String, Object?> extra = const {}}) async {
  final messenger = ScaffoldMessenger.of(context);
  final name = entry.extension.manifest.name;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(content: Text.verbatim('$name: ${entry.command.title}...'), duration: const Duration(seconds: 20)));
  final result = await service.runCommand(entry.extension, entry.command, api: api, context: extra);
  messenger.hideCurrentSnackBar();
  if (!context.mounted) return;
  messenger.showSnackBar(SnackBar(content: Text.verbatim('$name: $result'), duration: const Duration(seconds: 6)));
}

/// The list of commands of the extensions that are on (the ones for [place] and the ones for the list of commands); a tap runs one.
Future<void> showExtensionCommands(
  BuildContext context, {
  required ExtensionService service,
  required ExtensionApi Function(CommandEntry entry) apiFor,
  CommandPlace place = CommandPlace.palette,
}) async {
  final entries = [
    ...service.commands(place),
    if (place != CommandPlace.palette)
      for (final e in service.commands(CommandPlace.palette))
        if (!service.commands(place).any((x) => x.extension.id == e.extension.id && x.command.id == e.command.id)) e,
  ];
  final chosen = await showDialog<CommandEntry>(
    context: context,
    builder: (context) => PlatformAlertDialog(
      title: const Text('Commands of your extensions'),
      content: SizedBox(
        width: 420,
        child: entries.isEmpty
            ? const Text('No extension that is switched on has a command. Install one in Settings, Extensions.')
            : SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final e in entries)
                    ListTile(
                      key: ValueKey('command-${e.extension.id}-${e.command.id}'),
                      leading: const Icon(Symbols.extension),
                      title: Text.verbatim(e.command.title),
                      subtitle: Text.verbatim(e.extension.manifest.name),
                      onTap: () => Navigator.pop(context, e),
                    ),
                ]),
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    ),
  );
  if (chosen == null || !context.mounted) return;
  await runExtensionCommand(context, service, chosen, apiFor(chosen));
}
