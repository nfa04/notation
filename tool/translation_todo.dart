// What is still to be translated into a language of the app, or whether what was written is in order.
//
//   dart run tool/translation_todo.dart fr            the English texts that have no entry in lib/l10n/french.dart, as JSON
//   dart run tool/translation_todo.dart fr --dart     the same as lines for the Dart table:  'English': '',
//   dart run tool/translation_todo.dart fr --german   the JSON with the German text of each as a hint (for the one who translates)
//   dart run tool/translation_todo.dart fr --check    problems in the table: stale keys, empty or changed {placeholders}
//
// The English texts are the keys of the German table (it is kept complete by test/german_coverage_test.dart). Codes: de, fr, es, it.
import 'dart:convert';
import 'dart:io';

import 'package:notes/l10n/french.dart';
import 'package:notes/l10n/german.dart';
import 'package:notes/l10n/italian.dart';
import 'package:notes/l10n/spanish.dart';

const _tables = {'de': germanTexts, 'fr': frenchTexts, 'es': spanishTexts, 'it': italianTexts};

Set<String> _placeholders(String text) => {for (final m in RegExp(r'\{[A-Za-z0-9_]+\}').allMatches(text)) m.group(0)!};

String _quote(String s) => "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('\n', r'\n')}'";

void main(List<String> args) {
  final code = args.isEmpty ? null : args.first;
  final table = _tables[code];
  if (table == null) {
    stderr.writeln('Usage: dart run tool/translation_todo.dart <${_tables.keys.join('|')}> [--dart|--german|--check]');
    exit(64);
  }
  final english = germanTexts.keys.toList();
  if (args.contains('--check')) {
    var problems = 0;
    for (final e in table.entries) {
      String? why;
      if (!germanTexts.containsKey(e.key)) {
        why = 'not an English text of the app (stale or misspelt key)';
      } else if (e.value.trim().isEmpty) {
        why = 'empty';
      } else if (!(_placeholders(e.key).containsAll(_placeholders(e.value)) && _placeholders(e.value).containsAll(_placeholders(e.key)))) {
        why = 'placeholders differ: ${_placeholders(e.key)} -> ${_placeholders(e.value)}';
      }
      if (why != null) {
        problems++;
        stdout.writeln('${_quote(e.key)}: $why');
      }
    }
    final missing = english.where((k) => !table.containsKey(k)).length;
    stdout.writeln('$code: ${table.length} texts, $missing of ${english.length} missing, $problems problems');
    exit(problems == 0 ? 0 : 1);
  }
  final todo = english.where((k) => !table.containsKey(k)).toList();
  if (args.contains('--dart')) {
    for (final k in todo) {
      stdout.writeln("  ${_quote(k)}: '',");
    }
  } else if (args.contains('--german')) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert({for (final k in todo) k: {'de': germanTexts[k]}}));
  } else {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert({for (final k in todo) k: ''}));
  }
  stderr.writeln('${todo.length} of ${english.length} texts to do for $code');
}
