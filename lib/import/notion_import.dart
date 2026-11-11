import '../markdown/mention.dart';
import 'markdown_convert.dart';
import 'obsidian_import.dart' show ConvertedPage;

/// A name of Notion's export without its ending and without the 32 digits it adds to tell two pages of one name apart:
/// "Week 3 3f2a9c0e5b7d4e1f8a6b2c4d6e8f0a1b.md" is "Week 3".
String notionName(String fileName) {
  var n = fileName.substring(fileName.lastIndexOf('/') + 1);
  n = n.replaceFirst(RegExp(r'\.(md|csv|markdown|html)$', caseSensitive: false), '');
  n = n.replaceFirst(RegExp(r'_all$'), '');
  n = n.replaceFirst(RegExp(r'\s*[0-9a-fA-F]{32}$'), '');
  return n.trim();
}

/// A page of Notion's Markdown export read into the written document. Notion writes some things as HTML (a callout is `<aside>`, a
/// toggle is `<details>`); the properties of a row of a database come as `Name: value` lines under the title.
ConvertedPage convertNotionPage(String text, ConvertEnv env, {required String title, required bool databaseRow}) {
  var t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll('﻿', '');
  t = t.replaceAllMapped(RegExp(r'<aside>\s*([\s\S]*?)\s*</aside>'), (m) => m.group(1)!.trim().split('\n').map((l) => '> $l').join('\n'));
  t = t.replaceAllMapped(RegExp(r'<details[^>]*>\s*<summary>([\s\S]*?)</summary>'), (m) => '**${m.group(1)!.trim()}**\n');
  t = t.replaceAll('</details>', '');
  t = t.replaceAll(RegExp(r'</?(?:u|mark|span|div|center)(?:\s[^>]*)?>'), '');
  t = t.split('\n').map((l) => l.replaceAll(RegExp(r'<br\s*/?>'), l.trimLeft().startsWith('|') ? ' ' : '\n')).join('\n');
  if (databaseRow) t = _propertyList(t);
  var body = convertMarkdown(t, env, wiki: false).trim();
  if (!RegExp(r'^#\s').hasMatch(body)) body = '# $title\n\n$body';
  return ConvertedPage('${body.trimRight()}\n', const {});
}

/// The lines `Key: value` that follow the title of a row of a database, as a list.
String _propertyList(String text) {
  final lines = text.split('\n');
  final first = lines.indexWhere((l) => l.trim().isNotEmpty);
  if (first < 0 || !lines[first].startsWith('# ')) return text;
  var i = first + 1;
  while (i < lines.length && lines[i].trim().isEmpty) {
    i++;
  }
  final out = <String>[...lines.sublist(0, i)];
  final line = RegExp(r'^([^:\n]{1,60}):\s+(\S.*)$');
  var found = 0;
  while (i < lines.length && lines[i].trim().isNotEmpty) {
    final m = line.firstMatch(lines[i]);
    if (m == null) break;
    out.add('- **${m.group(1)!.trim()}:** ${m.group(2)!.trim()}');
    found++;
    i++;
  }
  if (found == 0) return text;
  return [...out, ...lines.sublist(i)].join('\n');
}

/// The rows of CSV text (quotes, doubled quotes and line breaks inside quotes are read as the format says).
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false, any = false;
  final s = text.replaceAll('﻿', '');
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < s.length && s[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(c);
      }
      continue;
    }
    switch (c) {
      case '"':
        quoted = true;
        any = true;
      case ',':
        row.add(cell.toString());
        cell.clear();
        any = true;
      case '\r':
        break;
      case '\n':
        if (any || cell.isNotEmpty) {
          row.add(cell.toString());
          rows.add(row);
        }
        row = <String>[];
        cell.clear();
        any = false;
      default:
        cell.write(c);
        any = true;
    }
  }
  if (any || cell.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }
  return rows;
}

/// A database of Notion (its CSV) as a table of the written document. The first column links to the page of the row when the
/// export has one ([rows]: pages by lower-case title).
String notionTable(String csv, {required String title, required Map<String, PageRef> rows}) {
  final data = parseCsv(csv);
  if (data.isEmpty) return '# $title\n';
  final width = data.map((r) => r.length).fold(0, (a, b) => a > b ? a : b);
  String cell(String v) => v.replaceAll(RegExp(r'\s*\n\s*'), ' ').replaceAll('|', r'\|').trim();
  String line(List<String> r, {bool first = false}) {
    final cells = [for (var i = 0; i < width; i++) i < r.length ? cell(r[i]) : ''];
    if (first && cells.isNotEmpty) {
      final page = rows[r[0].trim().toLowerCase()];
      if (page != null) cells[0] = noteLink(page.id, cells[0]);
    }
    return '| ${cells.join(' | ')} |';
  }

  final out = StringBuffer('# $title\n\n');
  out.writeln(line(data.first));
  out.writeln('| ${List.filled(width, '---').join(' | ')} |');
  for (final r in data.skip(1)) {
    out.writeln(line(r, first: true));
  }
  return out.toString();
}
