import 'package:flutter/foundation.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/text_provider.dart';

/// A text model that answers with [answer] (or whatever [respond] makes of the prompt) and keeps the prompts it was given.
class FakeModel extends ChangeNotifier implements TextModelProvider, ContextSized {
  FakeModel([this.answer = '']);
  String answer;
  String Function(AiPrompt prompt)? respond;
  ProviderState current = ProviderState.ready;
  final prompts = <AiPrompt>[];

  @override
  int get contextChars => 3000;
  @override
  String get id => 'fake';
  @override
  String get label => 'Fake';
  @override
  String get description => '';
  @override
  ProviderState get state => current;
  @override
  String? get reason => null;
  @override
  Future<void> prepare() async {}
  @override
  Future<String> complete(AiPrompt prompt, {int maxTokens = 256, void Function(String partial)? onPartial, AiCancel? cancel}) async {
    prompts.add(prompt);
    final text = respond?.call(prompt) ?? answer;
    onPartial?.call(text);
    return text;
  }
}

/// Names for the states the tests put a [FakeModel] in.
class ProviderStateForTest {
  static const notReady = ProviderState.needsDownload;
}
