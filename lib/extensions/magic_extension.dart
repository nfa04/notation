import 'dart:convert';

import '../ai/ai_prompt.dart';
import '../ai/ai_service.dart';
import '../ai/text_provider.dart';
import '../automations/automation.dart';
import '../automations/automation_service.dart';
import '../markdown/code_highlight.dart';
import 'extension_manifest.dart';
import 'extension_service.dart';
import 'magic_prompt.dart';

/// What the AI's answer is not good for; [message] says why (it is told back to the model, which tries again).
class MagicProblem implements Exception {
  final String message;
  MagicProblem(this.message);

  @override
  String toString() => message;
}

/// A rule of the automations that uses an action of the new extension.
class MagicAutomation {
  final AutomationEvent event;

  /// The id of the action in the extension's manifest.
  final String action;
  final String? contains;
  final int? weeks;

  const MagicAutomation(this.event, this.action, {this.contains, this.weeks});
}

/// An extension (and the rules that use it) as the AI made it, checked, for the person to read before anything is installed.
class MagicDraft {
  final ExtensionManifest manifest;
  final String script;
  final List<MagicAutomation> automations;
  final String explanation;

  /// The permissions that were not in the answer's manifest but that the script uses (they were added, and the person is told).
  final List<ExtensionPermission> added;

  /// The answer as it came, to be built on when a change is asked for.
  final String raw;

  const MagicDraft({required this.manifest, required this.script, required this.automations, required this.explanation, required this.added, required this.raw});

  String get manifestText => const JsonEncoder.withIndent('  ').convert(manifest.toJson());
}

/// "Create with AI": makes an extension, and the automations that use its actions, from what the person asks for in their own words. The
/// model is given the API (see [magicSystem]) and the request, and nothing else; what it answers is checked like anything that is installed,
/// problems are told back to it, and the person reads the result before it is installed (off, with no permission, unless they say otherwise).
class MagicExtension {
  final AiService ai;
  final ExtensionService extensions;

  /// How many times in all the model is asked (the first time and the tries after a problem).
  final int attempts;

  MagicExtension(this.ai, this.extensions, {this.attempts = 3});

  /// Makes a draft for [request]. With [previous] and [change] the draft is made again with that change asked for. [onPartial] gets
  /// the answer as it is being written; [onProblem] is told what was wrong with an answer before it is asked again.
  Future<MagicDraft> draft(
    String request, {
    MagicDraft? previous,
    String? change,
    void Function(String partial)? onPartial,
    void Function(String problem)? onProblem,
    AiCancel? cancel,
  }) async {
    final history = <AiTurn>[
      if (previous != null) ...[AiTurn(true, 'Make this: ${request.trim()}'), AiTurn(false, previous.raw)],
    ];
    var ask = previous == null ? 'Make this: ${request.trim()}' : 'Change it like this and answer again in full, in the same format: ${change?.trim() ?? ''}';
    MagicProblem? last;
    for (var i = 0; i < attempts; i++) {
      final raw = await ai.generate(AiPrompt(system: magicSystem, user: ask, history: List.of(history), exact: true), onPartial: onPartial, cancel: cancel);
      try {
        return check(raw);
      } on MagicProblem catch (e) {
        last = e;
        onProblem?.call(e.message);
        history
          ..add(AiTurn(true, ask))
          ..add(AiTurn(false, raw));
        ask = 'That did not work: ${e.message}\nAnswer again in full, fixed, in the same format.';
      }
    }
    throw MagicProblem('The AI did not make a working extension (${last?.message}). Try again, or ask for something simpler.');
  }

  // ---- reading the answer

  static final _heading = RegExp(r'^\s*(?:#{2,4}|={2,4})\s*(manifest\.json|main\.js|automations|explanation)\s*(?:={2,4})?\s*:?\s*$', caseSensitive: false);

  /// The four parts of an answer by their headings.
  static Map<String, String> sections(String raw) {
    final out = <String, StringBuffer>{};
    StringBuffer? at;
    for (final line in raw.split('\n')) {
      final m = _heading.firstMatch(line);
      if (m != null) {
        at = out[m.group(1)!.toLowerCase()] = StringBuffer();
      } else {
        at?.writeln(line);
      }
    }
    return {for (final e in out.entries) e.key: e.value.toString().trim()};
  }

  /// The code of [part] without the fence a model may have put round it.
  static String unfenced(String part) {
    final lines = part.trim().split('\n');
    if (lines.isEmpty) return '';
    if (matchFenceOpen(lines.first) != null) {
      var end = lines.length;
      if (lines.length > 1 && RegExp(r'^\s*(`{3,}|~{3,})\s*$').hasMatch(lines.last)) end = lines.length - 1;
      return lines.sublist(1, end).join('\n').trim();
    }
    return part.trim();
  }

  static final _uses = <ExtensionPermission, RegExp>{
    ExtensionPermission.noteRead: RegExp(r'notation\s*\.\s*note\s*\.\s*get\b'),
    ExtensionPermission.noteWrite: RegExp(r'notation\s*\.\s*(?:note\s*\.\s*(?:insertText|setTitle)|selection\s*\.\s*replace)\b'),
    ExtensionPermission.tasks: RegExp(r'notation\s*\.\s*tasks\s*\.\s*add\b'),
    ExtensionPermission.clipboard: RegExp(r'notation\s*\.\s*clipboard\s*\.\s*write\b'),
    ExtensionPermission.network: RegExp(r'notation\s*\.\s*network\s*\.\s*fetch\b'),
    ExtensionPermission.eventsEmit: RegExp(r'notation\s*\.\s*events\s*\.\s*emit\b'),
  };

  static bool _registers(String script, String kind, String id) => RegExp('notation\\s*\\.\\s*$kind\\s*\\(\\s*[\'"`]${RegExp.escape(id)}[\'"`]').hasMatch(script);

  /// Checks an answer and makes a draft of it, or says what is wrong ([MagicProblem]).
  MagicDraft check(String raw) {
    final parts = sections(raw);
    for (final need in ['manifest.json', 'main.js']) {
      if (!parts.containsKey(need) || parts[need]!.isEmpty) throw MagicProblem('The answer has no "### $need" part.');
    }
    final Object? json;
    try {
      json = jsonDecode(unfenced(parts['manifest.json']!));
    } catch (_) {
      throw MagicProblem('The manifest is not valid JSON (double quotes, no comments, no trailing commas).');
    }
    if (json is! Map) throw MagicProblem('The manifest is not a JSON object.');
    final script = unfenced(parts['main.js']!);
    if (script.isEmpty) throw MagicProblem('The script is empty.');
    if (script.length > 256 * 1024) throw MagicProblem('The script is too big.');

    // small things a model forgets are put right
    final fixed = <String, Object?>{...json.cast<String, Object?>()};
    final name = fixed['name'] is String && (fixed['name'] as String).trim().isNotEmpty ? (fixed['name'] as String).trim() : 'My extension';
    fixed['name'] = name;
    final id = (fixed['id'] is String ? fixed['id'] as String : name).toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    fixed['id'] = id.length < 3 ? '$id-ext' : (id.length > 64 ? id.substring(0, 64) : id);
    fixed['version'] ??= '1.0.0';
    fixed['main'] = 'main.js';
    if (fixed['description'] is! String || (fixed['description'] as String).trim().isEmpty) fixed['description'] = parts['explanation']?.split('\n').first.trim() ?? '';
    fixed['permissions'] ??= <Object?>[];

    // what the script uses must be asked for
    final asked = <String>{for (final p in (fixed['permissions'] is List ? fixed['permissions'] as List : const [])) '$p'};
    final added = <ExtensionPermission>[];
    for (final e in _uses.entries) {
      if (e.value.hasMatch(script) && !asked.contains(e.key.id)) {
        asked.add(e.key.id);
        added.add(e.key);
      }
    }
    fixed['permissions'] = asked.toList();
    if (asked.contains(ExtensionPermission.network.id)) {
      final hosts = <String>{for (final h in (fixed['hosts'] is List ? fixed['hosts'] as List : const [])) '$h'.toLowerCase()};
      if (hosts.isEmpty) {
        for (final m in RegExp(r'https://([a-z0-9.-]+)', caseSensitive: false).allMatches(script)) {
          hosts.add(m.group(1)!.toLowerCase());
        }
      }
      if (hosts.isEmpty) throw MagicProblem('The script uses the network but the manifest has no "hosts" (the website names, e.g. "api.example.com").');
      fixed['hosts'] = hosts.toList();
    } else {
      fixed.remove('hosts');
    }

    final ExtensionManifest manifest;
    try {
      manifest = ExtensionManifest.fromJson(fixed);
    } on ManifestException catch (e) {
      throw MagicProblem('The manifest is wrong: ${e.message}');
    }
    if (manifest.tools.isEmpty && manifest.actions.isEmpty) throw MagicProblem('The manifest has no "tools" and no "actions": the extension would do nothing.');
    for (final t in manifest.tools) {
      if (!_registers(script, 'tool', t.id)) throw MagicProblem('The script has no handler for the tool "${t.id}": add notation.tool(\'${t.id}\', (ctx) => ...).');
    }
    for (final a in manifest.actions) {
      if (!_registers(script, 'action', a.id)) throw MagicProblem('The script has no handler for the action "${a.id}": add notation.action(\'${a.id}\', async (ctx) => ...).');
    }
    final syntax = extensions.checkScript(script);
    if (syntax != null) throw MagicProblem('The script has an error: $syntax');

    return MagicDraft(
      manifest: manifest,
      script: script,
      automations: _automations(parts['automations'] ?? '', manifest),
      explanation: (parts['explanation'] ?? '').trim(),
      added: added,
      raw: raw,
    );
  }

  List<MagicAutomation> _automations(String text, ExtensionManifest manifest) {
    final out = <MagicAutomation>[];
    for (final line in text.split('\n')) {
      final l = line.trim().replaceAll(RegExp(r'^[-*]\s*'), '');
      if (l.isEmpty || l.toLowerCase() == 'none' || l.toLowerCase().startsWith('none ')) continue;
      final fields = {for (final m in RegExp(r'(\w+)\s*=\s*([^\s]+)').allMatches(l)) m.group(1)!.toLowerCase(): m.group(2)!};
      final event = AutomationEvent.values.where((e) => e.name.toLowerCase() == (fields['event'] ?? '').toLowerCase()).firstOrNull;
      if (event == null) throw MagicProblem('The rule "$l" has no event I know (${AutomationEvent.values.map((e) => e.name).join(', ')}).');
      final action = fields['action'] ?? '';
      if (!manifest.actions.any((a) => a.id == action)) throw MagicProblem('The rule "$l" uses the action "$action", which the manifest does not have in "actions".');
      int? weeks;
      if (event == AutomationEvent.noteStale) {
        weeks = int.tryParse(fields['weeks'] ?? '') ?? 4;
        if (weeks < 1) throw MagicProblem('"weeks" of a noteStale rule has to be 1 or more.');
      }
      final contains = fields['contains']?.replaceAll('"', '');
      out.add(MagicAutomation(event, action, contains: contains == null || contains.isEmpty ? null : contains, weeks: weeks));
    }
    return out;
  }

  // ---- installing

  /// Puts the draft in the list: off and with no permission, or with [allow] on and with the permissions the person read. The rules it
  /// asked for are added to [automations] (switched on only with [allow]). Returns how many rules were added.
  Future<int> install(MagicDraft draft, {bool allow = false, AutomationService? automations}) async {
    await extensions.installSource(draft.manifestText, draft.script);
    final id = draft.manifest.id;
    if (allow) {
      for (final p in draft.manifest.permissions) {
        await extensions.setGranted(id, p, true);
      }
      await extensions.setEnabled(id, true);
    }
    var made = 0;
    if (automations != null) {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      for (final (i, a) in draft.automations.indexed) {
        await automations.add(Automation(
          id: '${stamp + i}',
          event: a.event,
          action: AutomationAction.extensionAction,
          contains: a.contains,
          params: {'extension': '$id/${a.action}', if (a.weeks != null) 'weeks': '${a.weeks}'},
          enabled: allow,
        ));
        made++;
      }
    }
    return made;
  }
}
