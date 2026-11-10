import 'package:flutter/foundation.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/text_provider.dart';

/// A model that writes one fact per line of the document it is given, in the form the fact extractor asks for.
class FactWriter extends ChangeNotifier implements TextModelProvider {
  int calls = 0;
  String Function(String document)? answer;

  @override
  String get id => 'fact-writer';
  @override
  String get label => 'Fact writer';
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
    calls++;
    final document = prompt.user.replaceFirst('DOCUMENT:\n', '');
    if (answer != null) return answer!(document);
    return [
      for (final line in document.split('\n'))
        if (line.trim().length > 30) '${line.split(' ').take(4).join(' ')}: Mechanism | Fact | ${line.trim()} | ${line.split(RegExp(r'\W+')).where((w) => w.length > 3).take(8).join(', ')}',
    ].join('\n');
  }
}

AiService factWriterService([FactWriter? writer]) => AiService(providers: [writer ?? FactWriter()]);
