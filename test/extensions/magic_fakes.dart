import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/extensions/script_engine.dart';

/// A model that answers from a list, one after the other, and keeps what it was asked.
class Scripted extends ChangeNotifier implements TextModelProvider {
  Scripted(this.answers);
  final List<String> answers;
  final prompts = <AiPrompt>[];

  @override
  String get id => 'scripted';
  @override
  String get label => 'Scripted';
  @override
  String get description => '';
  @override
  ProviderState get state => ProviderState.ready;
  @override
  String? get reason => null;
  @override
  Future<void> prepare() async {}
  @override
  Future<String> complete(AiPrompt prompt, {int maxTokens = 256, void Function(String partial)? onPartial, AiCancel? cancel}) async {
    prompts.add(prompt);
    final a = answers.removeAt(0);
    onPartial?.call(a);
    return a;
  }
}

/// A script engine that only says whether the script "reads": a script with SYNTAX in it does not.
class ReadingEngine implements ScriptEngine {
  @override
  void register(String name, FutureOr<Object?> Function(List<Object?> args) fn) {}
  @override
  void eval(String code, {String filename = 'script'}) {
    if (code.contains('SYNTAX')) throw 'SyntaxError: unexpected token';
  }

  @override
  Future<Object?> evalAsync(String code, {String filename = 'script', Duration? timeout}) async => null;
  @override
  void dispose() {}
}

String answer({String manifest = '', String script = '', String automations = 'none', String explanation = 'It does a thing.'}) => '''
### manifest.json
$manifest
### main.js
$script
### automations
$automations
### explanation
$explanation
''';

String json(Map<String, Object?> m) => jsonEncode(m);

