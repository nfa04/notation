import 'dart:convert';

import '../extensions/extension_host.dart';
import 'ai_prompt.dart';
import 'ai_service.dart';
import 'note_agent.dart';
import 'text_provider.dart';

/// The tools of the assistant that only look: the person's notes, the PDFs in them and their tasks. Nothing can be changed or sent
/// with them, so an assistant that works on its own (no one is there to be asked) can be given them.
const readingToolNames = {'notes.search', 'notes.read', 'notes.list', 'pdf.read', 'pdf.search', 'tasks.list'};

List<AgentTool> get readingTools => [for (final t in agentTools) if (readingToolNames.contains(t.name)) t];

/// Lets the model work on [request] with [tools] (only ones that look: see [readingTools]) on [api] until it answers without calls,
/// and answers that answer. Nobody is asked: a tool that is not one of [readingToolNames] is refused. [onStep] is told what it does
/// (to show). Fails like [AiService.generate] does, and when the model goes round in circles for [rounds] rounds.
Future<String> runReadingAgent(
  AiService ai, {
  required ExtensionApi api,
  required String system,
  required String request,
  List<AgentTool>? tools,
  int rounds = 8,
  int callsPerRound = 6,
  int maxTokens = 1500,
  AiCancel? cancel,
  void Function(String step)? onStep,
}) async {
  final usable = [for (final t in tools ?? readingTools) if (readingToolNames.contains(t.name)) t];
  final textSystem = '$system\n\nTo use a tool, write only this, nothing around it:\n<tool>{"name":"notes.read","args":{"id":"..."}}</tool>\n'
      'You are then told what came of it and can use another tool. When you have what you need, write the answer, with no tool in it.\n\n'
      'Tools:\n${usable.map((t) => '- ${t.usage}').join('\n')}';
  final done = <String>{};
  // (what the tools give back is cut to what the model can take in, with room for the rest of the conversation)
  final room = (ai.contextChars ~/ 3).clamp(1500, 20000);

  Future<String> call(AgentCall c) async {
    if (c.error != null) return 'Error: ${c.error}';
    final tool = usable.where((t) => t.name == c.name).firstOrNull;
    if (tool == null) return 'Error: there is no tool "${c.name}". There are: ${usable.map((t) => t.name).join(', ')}.';
    final key = jsonEncode([c.name, c.args]);
    if (!done.add(key)) return '${c.name}: this was done already, do not do it again.';
    try {
      onStep?.call(tool.describe(c.args).summary);
      final result = await tool.run(api, c.args);
      return '${c.name}: ${result.length > room ? '${result.substring(0, room)}...' : result}';
    } on ExtensionError catch (e) {
      return 'Error in ${c.name}: ${e.message}';
    } catch (e) {
      return 'Error in ${c.name}: $e';
    }
  }

  var native = ai.canCallTools;
  var user = request;
  final turns = <AiTurn>[];
  for (var round = 0; round < rounds; round++) {
    final last = round == rounds - 1;
    final String reply;
    final List<AiToolCall> sent;
    final List<AgentCall> calls;
    if (native) {
      try {
        final r = await ai.generateWithTools(
          AiPrompt(system: system, user: user, history: turns, exact: true),
          [for (final t in usable) t.spec],
          maxTokens: maxTokens,
          cancel: cancel,
        );
        reply = r.text;
        sent = r.calls;
        calls = [for (final c in r.calls) AgentCall(usable.where((t) => t.wire == c.name).firstOrNull?.name ?? c.name, c.args, id: c.id, error: c.error)];
      } on ToolsNotSupported {
        if (round > 0) rethrow;
        native = false;
        round--;
        continue;
      }
    } else {
      reply = await ai.generate(AiPrompt(system: textSystem, user: user, history: turns, exact: true), maxTokens: maxTokens, cancel: cancel);
      sent = const [];
      calls = parseToolCalls(reply);
    }
    if (cancel?.cancelled ?? false) throw StateError('stopped');
    // (in the last round calls are not done any more: what was written beside them is the answer, if there is one)
    if (calls.isEmpty || last) {
      final answer = native ? reply.trim() : visibleAnswer(reply);
      if (answer.isNotEmpty || calls.isEmpty) return answer;
      break;
    }
    final results = [for (final (i, c) in calls.indexed) i < callsPerRound ? await call(c) : '${c.name}: not done, there were too many calls at once.'];
    if (native) {
      if (user.isNotEmpty) turns.add(AiTurn(true, user));
      turns.add(AiTurn(false, reply, calls: sent));
      for (final (i, c) in sent.indexed) {
        turns.add(AiTurn(false, results[i], resultOf: c.id));
      }
      user = round == rounds - 2 ? 'This is the last round: write the answer now, without tools.' : '';
    } else {
      turns
        ..add(AiTurn(true, user))
        ..add(AiTurn(false, reply));
      user = 'Results:\n${results.join('\n')}\n\n${round == rounds - 2 ? 'This is the last round: write the answer now, without tools.' : 'Use another tool if more is needed, otherwise write the answer.'}';
    }
  }
  throw StateError('The assistant did not finish.');
}
