import 'markdown_convert.dart';

/// What was read from one page.
class ConvertedPage {
  /// The text of the written document, pictures still as [pictureMark]s.
  final String text;
  final Set<String> tags;
  const ConvertedPage(this.text, this.tags);
}

/// The properties at the top of an Obsidian note (between two lines of `---`), each with its values, and the text under them.
({Map<String, List<String>> properties, String body}) splitFrontmatter(String text) {
  final t = text.replaceAll('\r\n', '\n').replaceAll('﻿', '');
  if (!t.startsWith('---\n')) return (properties: const {}, body: t);
  final lines = t.split('\n');
  var end = -1;
  for (var i = 1; i < lines.length && i < 400; i++) {
    if (lines[i].trimRight() == '---' || lines[i].trimRight() == '...') {
      end = i;
      break;
    }
  }
  if (end < 0) return (properties: const {}, body: t);
  final props = <String, List<String>>{};
  String? key;
  String clean(String v) {
    v = v.trim();
    if (v.length >= 2 && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) v = v.substring(1, v.length - 1);
    return v;
  }

  for (var i = 1; i < end; i++) {
    final line = lines[i];
    final item = RegExp(r'^\s+-\s+(.*)$').firstMatch(line) ?? (key != null ? RegExp(r'^-\s+(.*)$').firstMatch(line) : null);
    if (item != null && key != null) {
      props[key]!.add(clean(item.group(1)!));
      continue;
    }
    final kv = RegExp(r'^([^\s:#][^:]*?):\s*(.*)$').firstMatch(line);
    if (kv == null) continue;
    key = kv.group(1)!.trim();
    final v = kv.group(2)!.trim();
    final values = props.putIfAbsent(key, () => []);
    if (v.startsWith('[') && v.endsWith(']')) {
      values.addAll(v.substring(1, v.length - 1).split(',').map(clean).where((s) => s.isNotEmpty));
    } else if (v.isNotEmpty) {
      values.add(clean(v));
    }
  }
  return (properties: props, body: lines.sublist(end + 1).join('\n').replaceFirst(RegExp(r'^\n+'), ''));
}

const _tagKeys = {'tags', 'tag'};
const _quietKeys = {'aliases', 'alias', 'cssclass', 'cssclasses', 'publish', 'permalink', 'banner', 'banner_icon', 'kanban-plugin'};

/// An Obsidian note read into the written document: a heading with its title, the properties as a list (tags and technical ones
/// left out; tags become tags), then the text with its links, pictures and callouts converted.
ConvertedPage convertObsidianPage(String text, ConvertEnv env, {required String title}) {
  final split = splitFrontmatter(text);
  final tags = <String>{};
  for (final k in _tagKeys) {
    for (final v in split.properties[k] ?? const <String>[]) {
      tags.addAll(v.split(RegExp(r'[,\s]+')).map((t) => t.replaceFirst(RegExp(r'^#+'), '')).where((t) => t.isNotEmpty));
    }
  }
  final props = <String>[
    for (final e in split.properties.entries)
      if (!_tagKeys.contains(e.key.toLowerCase()) && !_quietKeys.contains(e.key.toLowerCase()) && e.value.isNotEmpty)
        '- **${e.key}:** ${convertMarkdown(e.value.join(', '), env, wiki: true)}',
  ];
  final body = convertMarkdown(split.body, env, wiki: true).trim();
  env.tags.addAll(tags);
  final startsWithTitle = RegExp(r'^#\s+(.*)$', multiLine: false).firstMatch(body.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => ''))?.group(1)?.trim().toLowerCase() == title.trim().toLowerCase();
  final out = StringBuffer();
  if (!startsWithTitle) out.write('# $title\n\n');
  if (props.isNotEmpty && !startsWithTitle) out.write('${props.join('\n')}\n\n');
  out.write(body);
  if (props.isNotEmpty && startsWithTitle) {
    // the note has its own heading: the properties go under the whole text, where they cannot push it away
    out.write('\n\n---\n\n${props.join('\n')}');
  }
  return ConvertedPage('${out.toString().trimRight()}\n', env.tags);
}
