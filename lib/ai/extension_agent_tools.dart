import '../extensions/extension_host.dart';
import '../extensions/extension_manifest.dart';
import '../extensions/extension_service.dart';
import '../l10n/language.dart';
import 'note_agent.dart';

/// The tools extensions offer the assistant (`agentTools` in their manifests), as tools of the agent: each is asked for every time (the
/// person says yes or no on a card that names the extension and the arguments), and the script runs with the permissions it was
/// given in the settings, in the place of the assistant. An extension with the permission `network` cannot offer any (the manifest
/// is refused): text in a note could make the assistant send the note away through it.
List<AgentTool> extensionAgentTools(ExtensionService service) {
  final taken = <String>{};
  return [
    for (final x in service.agentTools)
      () {
        var name = 'ext_${x.extension.id.replaceAll(RegExp(r'[^a-z0-9]'), '_')}_${x.tool.id.replaceAll(RegExp(r'[^a-z0-9]'), '_')}';
        for (var n = 2; !taken.add(name); n++) {
          name = '${name}_$n';
        }
        final args = x.tool.args;
        final who = x.extension.manifest.name;
        return AgentTool(
          name: name,
          usage: '$name {${args.keys.map((k) => '"$k"').join(', ')}} : ${x.tool.description} (a tool of the extension "$who"${args.isEmpty ? '' : '; ${args.entries.map((e) => '${e.key}: ${e.value}').join('; ')}'})',
          parameters: {
            'type': 'object',
            'properties': {for (final a in args.entries) a.key: {'type': 'string', 'description': a.value}},
          },
          permission: ExtensionPermission.assistantTool,
          describe: (given) {
            for (final k in given.keys) {
              if (!args.containsKey(k)) throw ExtensionError('This tool has no argument "$k". It takes: ${args.keys.join(', ')}.');
            }
            return AgentAction(tr('Run "{tool}" of the extension {name}', {'tool': x.tool.title, 'name': who}), given.isEmpty ? null : given.entries.map((e) => '${e.key}: ${e.value}').join('\n'));
          },
          run: (api, given) async => 'Done: ${await service.runAgentTool(x.extension, x.tool, given, api)}',
        );
      }(),
  ];
}
