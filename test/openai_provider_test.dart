import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_prompt.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/ai/openai_provider.dart';
import 'package:notes/ai/text_provider.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/screens/settings_screen.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/sync/caldav_service.dart' show SecretStore;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Secret implements SecretStore {
  String? value;

  /// A keystore that cannot be written to (locked, or the platform has none).
  bool broken = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async {
    if (broken) throw StateError('the keystore is locked');
    value = v;
  }
  @override
  Future<void> delete() async => value = null;
}

String sse(List<String> pieces) =>
    '${[for (final p in pieces) 'data: ${jsonEncode({'choices': [{'delta': {'content': p}}]})}\n\n'].join()}data: [DONE]\n\n';

const prompt = AiPrompt(system: 'Be brief.', user: 'Summarize this.');

void main() {
  setUpAll(AppDatabase.initFfi);

  late _Secret secret;
  late List<({Uri url, Map<String, String> headers, Map<String, dynamic> body})> sent;

  OpenAiProvider make(Stream<String> Function(int call, String body) answer) {
    sent = [];
    return OpenAiProvider(
      secret: secret,
      transport: (url, headers, body, cancel) {
        sent.add((url: url, headers: headers, body: jsonDecode(body) as Map<String, dynamic>));
        return answer(sent.length, body);
      },
    );
  }

  setUp(() => secret = _Secret());

  group('tools', () {
    String delta(Map<String, Object?> d) => 'data: ${jsonEncode({'choices': [{'delta': d}]})}\n\n';
    const tools = [
      AiToolSpec('note_insertText', 'Adds text.', {'type': 'object', 'properties': {'text': {'type': 'string'}}, 'required': ['text']}),
      AiToolSpec('note_get', 'Reads the note.'),
    ];

    test('they go with the request, the calls come back in pieces, and the answers keep their form', () async {
      final p = make((_, _) => Stream.fromIterable([
            delta({'content': 'Adding it.'}),
            delta({'tool_calls': [{'index': 0, 'id': 'c1', 'function': {'name': 'note_insertText', 'arguments': '{"text":"# Gre'}}]}),
            delta({'tool_calls': [{'index': 0, 'function': {'arguments': 'ek\\n\\nhistory"}'}}]}),
            delta({'tool_calls': [{'index': 1, 'id': '', 'function': {'name': 'note_get', 'arguments': ''}, 'extra_content': {'google': {'thought_signature': 'sig'}}}]}),
            'data: [DONE]\n\n',
          ]));
      await p.save(const OpenAiConfig(baseUrl: 'https://api.openai.com/v1', model: 'm'), 'k');
      final reply = await p.completeWithTools(
        const AiPrompt(system: 'S', user: '', history: [
          AiTurn(true, 'write it'),
          AiTurn(false, '', calls: [AiToolCall('c0', 'note_get', {}, extra: {'google': {'thought_signature': 'old'}})]),
          AiTurn(false, 'Title: x', resultOf: 'c0'),
        ]),
        tools,
      );
      expect(reply.text, 'Adding it.');
      expect(reply.calls.map((c) => '${c.id} ${c.name} ${jsonEncode(c.args)}'), ['c1 note_insertText {"text":"# Greek\\n\\nhistory"}', 'call_1 note_get {}']);
      expect(reply.calls.last.extra, {'google': {'thought_signature': 'sig'}});
      final body = sent.single.body;
      expect(body['tools'], [
        {'type': 'function', 'function': {'name': 'note_insertText', 'description': 'Adds text.', 'parameters': tools.first.parameters}},
        {'type': 'function', 'function': {'name': 'note_get', 'description': 'Reads the note.'}},
      ]);
      expect(body['messages'], [
        {'role': 'system', 'content': 'S'},
        {'role': 'user', 'content': 'write it'},
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {'id': 'c0', 'type': 'function', 'function': {'name': 'note_get', 'arguments': '{}'}, 'extra_content': {'google': {'thought_signature': 'old'}}},
          ],
        },
        {'role': 'tool', 'tool_call_id': 'c0', 'content': 'Title: x'},
      ]);
    });

    test('arguments that are not JSON are kept as an error; a plain request has no tools', () async {
      final p = make((_, _) => Stream.fromIterable([
            delta({'tool_calls': [{'index': 0, 'id': 'a', 'function': {'name': 'note_insertText', 'arguments': '{"text": "cut off'}}]}),
          ]));
      await p.save(const OpenAiConfig(baseUrl: 'https://api.openai.com/v1', model: 'm'), 'k');
      final reply = await p.completeWithTools(prompt, tools);
      expect(reply.calls.single.error, isNotNull);
      await p.complete(prompt);
      expect(sent.last.body.containsKey('tools'), isFalse);
    });

    test('a server that takes no tools says so', () async {
      final p = make((_, _) => Stream.error(refusal('The service answered 400: registry.ollama.ai/library/gemma does not support tools')));
      await p.save(const OpenAiConfig(baseUrl: 'http://localhost:11434/v1', model: 'gemma'), '');
      await expectLater(p.completeWithTools(prompt, tools), throwsA(isA<ToolsNotSupported>()));
      await expectLater(p.complete(prompt), throwsStateError);
    });
  });

  test('it needs an address and a model before it is ready', () async {
    final p = make((_, _) => const Stream.empty());
    expect(p.state, ProviderState.unavailable);
    expect(p.reason, contains('model'));
    await expectLater(p.complete(prompt), throwsStateError);
    await p.save(const OpenAiConfig(baseUrl: 'http://localhost:11434/v1/', model: 'llama3.2'), '');
    expect(p.state, ProviderState.ready);
    expect(p.config.chatUrl.toString(), 'http://localhost:11434/v1/chat/completions');
    expect(const OpenAiConfig(baseUrl: 'https://x.org/v1/chat/completions').chatUrl.path, '/v1/chat/completions');
  });

  test('it asks like OpenAI does and streams the answer', () async {
    final p = make((_, _) => Stream.fromIterable(sse(['The ', 'second law', ' holds.']).split('\n\n').map((e) => '$e\n\n')));
    await p.save(const OpenAiConfig(baseUrl: 'https://api.openai.com/v1', model: 'gpt-4o-mini'), 'sk-secret');
    final partials = <String>[];
    final answer = await p.complete(prompt, maxTokens: 100, onPartial: partials.add);
    expect(answer, 'The second law holds.');
    expect(partials.last, 'The second law holds.');
    final r = sent.single;
    expect(r.url.toString(), 'https://api.openai.com/v1/chat/completions');
    expect(r.headers['Authorization'], 'Bearer sk-secret');
    expect(r.body['model'], 'gpt-4o-mini');
    expect(r.body['stream'], true);
    expect(r.body['max_tokens'], 100);
    expect(r.body.containsKey('reasoning_effort'), isFalse);
    expect(r.body['messages'], [
      {'role': 'system', 'content': 'Be brief.'},
      {'role': 'user', 'content': 'Summarize this.'},
    ]);
  });

  test('Gemini is asked to think little, with room for its thinking on top of the answer', () async {
    final p = make((_, _) => Stream.value(sse(['Ok.'])));
    await p.save(const OpenAiConfig(baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai/', model: 'gemini-2.5-flash'), 'k');
    expect(await p.complete(prompt, maxTokens: 100), 'Ok.');
    expect(sent.single.body['reasoning_effort'], 'low');
    expect(sent.single.body['max_tokens'], greaterThan(1000));
  });

  test('chunks may cut the stream anywhere, and thinking is left out', () async {
    final whole = sse(['<think>hmm</think>', 'Answer', ' here']);
    final p = make((_, _) => Stream.fromIterable([for (var i = 0; i < whole.length; i += 7) whole.substring(i, i + 7 > whole.length ? whole.length : i + 7)]));
    await p.save(const OpenAiConfig(model: 'm'), '');
    expect(await p.complete(prompt), 'Answer here');
    expect(sent.single.headers.containsKey('Authorization'), isFalse); // no key, none sent
  });

  test('a server that does not stream still works', () async {
    final p = make((_, _) => Stream.value(jsonEncode({'choices': [{'message': {'content': 'All at once.'}}]})));
    await p.save(const OpenAiConfig(model: 'm'), 'k');
    expect(await p.complete(prompt), 'All at once.');
  });

  test('a newer model that wants max_completion_tokens is asked again with it', () async {
    final p = make((call, _) => call == 1
        ? Stream.error(refusal("The service answered 400: Unsupported parameter: 'max_tokens'. Use 'max_completion_tokens' instead."))
        : Stream.value(sse(['Ok.'])));
    await p.save(const OpenAiConfig(model: 'gpt-5'), 'k');
    expect(await p.complete(prompt, maxTokens: 50), 'Ok.');
    expect(sent.length, 2);
    expect(sent.last.body.containsKey('max_tokens'), isFalse);
    expect(sent.last.body['max_completion_tokens'], 50);
  });

  test('a refusal is reported with what the server said', () async {
    final p = make((_, _) => Stream.error(refusal('The service answered 401 (is the key right?): bad key')));
    await p.save(const OpenAiConfig(model: 'm'), 'k');
    await expectLater(p.complete(prompt), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('bad key'))));
  });

  test('Stop returns what there is', () async {
    final cancel = AiCancel();
    final p = make((_, _) async* {
      yield '${sse(['One ']).split('\n\n').first}\n\n';
      cancel.cancel();
      yield 'data: ${jsonEncode({'choices': [{'delta': {'content': 'two'}}]})}\n\n';
    });
    await p.save(const OpenAiConfig(model: 'm'), '');
    expect(await p.complete(prompt, cancel: cancel), 'One');
  });

  test('address and model are kept in the settings, the key in the keystore', () async {
    final db = await AppDatabase.open(path: inMemoryDatabasePath);
    await db.delete('settings', where: "key LIKE 'ai_%'");
    final settings = SettingsRepository(db);
    final a = OpenAiProvider(settings: settings, secret: secret, transport: (_, _, _, _) => const Stream.empty());
    await a.save(const OpenAiConfig(baseUrl: 'http://h/v1', model: 'm1'), 'sk-1');
    expect(await settings.get('ai_openai_config'), isNot(contains('sk-1')));
    expect(secret.value, 'sk-1');
    final b = OpenAiProvider(settings: settings, secret: secret, transport: (_, _, _, _) => const Stream.empty());
    await b.load();
    expect((b.config.baseUrl, b.config.model, b.hasKey), ('http://h/v1', 'm1', true));
    await b.save(b.config, '');
    expect(secret.value, isNull);
  });

  testWidgets('settings: fill in the service, try it, and choose it', (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = await tester.runAsync(() => AppDatabase.open(path: inMemoryDatabasePath));
    await tester.runAsync(() => db!.delete('settings', where: "key LIKE 'ai_%'"));
    final provider = make((_, _) => Stream.value(sse(['It works.'])));
    final ai = AiService(settings: SettingsRepository(db!), providers: [provider]);
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory(), ai: ai)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('openai-url')), 400, scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const ValueKey('ai-unavailable')), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('openai-test'))).onPressed, isNull);

    await tester.enterText(find.byKey(const ValueKey('openai-url')), 'http://localhost:1234/v1');
    await tester.enterText(find.byKey(const ValueKey('openai-model')), 'qwen');
    await tester.enterText(find.byKey(const ValueKey('openai-key')), 'sk-abc');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('openai-test')));
    for (var i = 0; i < 20 && find.byKey(const ValueKey('openai-result')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('openai-result')), findsOneWidget);
    expect(find.textContaining('Connected: It works.'), findsOneWidget);
    expect(provider.config.model, 'qwen');
    expect(secret.value, 'sk-abc');
    expect(provider.state, ProviderState.ready);
    expect(find.byKey(const ValueKey('ai-unavailable')), findsNothing);
  });

  testWidgets('settings: a keystore that cannot save the key shows why instead of doing nothing', (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = await tester.runAsync(() => AppDatabase.open(path: inMemoryDatabasePath));
    await tester.runAsync(() => db!.delete('settings', where: "key LIKE 'ai_%'"));
    secret.broken = true;
    final provider = make((_, _) => Stream.value(sse(['never asked'])));
    final ai = AiService(settings: SettingsRepository(db!), providers: [provider]);
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory(), ai: ai)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('openai-url')), 400, scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.byKey(const ValueKey('openai-url')), 'http://localhost:1234/v1');
    await tester.enterText(find.byKey(const ValueKey('openai-model')), 'qwen');
    await tester.enterText(find.byKey(const ValueKey('openai-key')), 'sk-abc');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('openai-test')));
    for (var i = 0; i < 20 && find.byKey(const ValueKey('openai-result')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.textContaining('the keystore is locked'), findsOneWidget);
    expect(sent, isEmpty, reason: 'nothing was asked of the service');
    // and the button is usable again
    expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('openai-test'))).onPressed, isNotNull);
  });

  testWidgets('settings: leaving the screen while the test is running does not fail', (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = await tester.runAsync(() => AppDatabase.open(path: inMemoryDatabasePath));
    await tester.runAsync(() => db!.delete('settings', where: "key LIKE 'ai_%'"));
    final provider = make((_, _) => Stream.value(sse(['late answer'])));
    final ai = AiService(settings: SettingsRepository(db!), providers: [provider]);
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(theme: AppTheme.inMemory(), ai: ai)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('openai-url')), 400, scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.byKey(const ValueKey('openai-url')), 'http://localhost:1234/v1');
    await tester.enterText(find.byKey(const ValueKey('openai-model')), 'qwen');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('openai-test')));
    await tester.pumpWidget(const MaterialApp(home: Text('elsewhere')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  group('rate limits', () {
    const cfg = OpenAiConfig(baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai', model: 'm', pauseSeconds: 4);
    final ok = sse(['hi']);

    OpenAiProvider limited(List<Duration> slept, Stream<String> Function(int call) answer) {
      sent = [];
      return OpenAiProvider(
        secret: secret,
        sleep: (d) async => slept.add(d),
        transport: (url, headers, body, cancel) {
          sent.add((url: url, headers: headers, body: jsonDecode(body) as Map<String, dynamic>));
          return answer(sent.length);
        },
      );
    }

    test('the pause is saved, read back, and clamped', () {
      expect(OpenAiConfig.decode(cfg.encode()).pauseSeconds, 4);
      expect(OpenAiConfig.decode(const OpenAiConfig().encode()).pauseSeconds, 0);
      expect(OpenAiConfig.decode('{"baseUrl":"x","model":"m","pause":99999}').pauseSeconds, OpenAiConfig.maxPauseSeconds);
      expect(OpenAiConfig.decode('{"baseUrl":"x","model":"m","pause":-3}').pauseSeconds, 0);
    });

    test('requests start at least the pause apart', () async {
      final slept = <Duration>[];
      final p = limited(slept, (_) => Stream.value(ok));
      await p.save(cfg, 'k');
      await p.complete(const AiPrompt(system: 's', user: 'a'));
      expect(slept, isEmpty, reason: 'the first one starts at once');
      await p.complete(const AiPrompt(system: 's', user: 'b'));
      final total = slept.fold<Duration>(Duration.zero, (a, b) => a + b);
      expect(total, greaterThan(const Duration(seconds: 3)));
      expect(total, lessThanOrEqualTo(const Duration(seconds: 4)));
    });

    test('with no pause nothing waits', () async {
      final slept = <Duration>[];
      final p = limited(slept, (_) => Stream.value(ok));
      await p.save(const OpenAiConfig(baseUrl: 'http://x/v1', model: 'm'), '');
      await p.complete(const AiPrompt(system: 's', user: 'a'));
      await p.complete(const AiPrompt(system: 's', user: 'b'));
      expect(slept, isEmpty);
    });

    test('a 429 is tried again after the wait the service asks for, then it works', () async {
      final slept = <Duration>[];
      final p = limited(slept, (call) => call < 3 ? Stream.error(refusal('slow down', status: 429, retryAfter: const Duration(seconds: 7))) : Stream.value(ok));
      await p.save(const OpenAiConfig(baseUrl: 'http://x/v1', model: 'm'), '');
      expect(await p.complete(const AiPrompt(system: 's', user: 'a')), 'hi');
      expect(sent.length, 3);
      expect(slept.fold<Duration>(Duration.zero, (a, b) => a + b), const Duration(seconds: 15)); // 2 x (7 s + half a second)
    });

    test('without a time from the service the wait grows, and after three tries the error is shown', () async {
      final slept = <Duration>[];
      final p = limited(slept, (_) => Stream.error(refusal('The service answered 429: too many', status: 429)));
      await p.save(const OpenAiConfig(baseUrl: 'http://x/v1', model: 'm'), '');
      await expectLater(p.complete(const AiPrompt(system: 's', user: 'a')), throwsA(predicate((e) => '$e'.contains('429'))));
      expect(sent.length, 4);
      expect(slept.fold<Duration>(Duration.zero, (a, b) => a + b), const Duration(milliseconds: 35000 + 3 * 500)); // 5, 10, 20 s and half a second each
    });

    test('a wait of minutes (a daily quota) is not waited for', () async {
      final slept = <Duration>[];
      final p = limited(slept, (_) => Stream.error(refusal('quota', status: 429, retryAfter: const Duration(minutes: 20))));
      await p.save(const OpenAiConfig(baseUrl: 'http://x/v1', model: 'm'), '');
      await expectLater(p.complete(const AiPrompt(system: 's', user: 'a')), throwsA(anything));
      expect(sent.length, 1);
      expect(slept, isEmpty);
    });

    test('other errors are not tried again', () async {
      final p = limited([], (_) => Stream.error(refusal('nope', status: 401)));
      await p.save(const OpenAiConfig(baseUrl: 'http://x/v1', model: 'm'), '');
      await expectLater(p.complete(const AiPrompt(system: 's', user: 'a')), throwsA(anything));
      expect(sent.length, 1);
    });

    test('a stop ends the waiting', () async {
      final cancel = AiCancel();
      sent = [];
      final p2 = OpenAiProvider(secret: secret, sleep: (_) async => cancel.cancel(), transport: (u, h, b, c) {
        sent.add((url: u, headers: h, body: jsonDecode(b) as Map<String, dynamic>));
        return Stream.error(refusal('slow', status: 429, retryAfter: const Duration(seconds: 30)));
      });
      await p2.save(const OpenAiConfig(baseUrl: 'http://x/v1', model: 'm'), '');
      expect(await p2.complete(const AiPrompt(system: 's', user: 'a'), cancel: cancel), '');
      expect(sent.length, 1);
    });

    test('where the service says how long: the header and the words of Gemini', () {
      expect(OpenAiProvider.retryAfterOf('12', ''), const Duration(seconds: 12));
      expect(OpenAiProvider.retryAfterOf(null, '{"error":{"details":[{"retryDelay":"33s"}]}}'), const Duration(seconds: 33));
      expect(OpenAiProvider.retryAfterOf(null, 'Quota exceeded. Please retry in 12.5s.'), const Duration(milliseconds: 12500));
      expect(OpenAiProvider.retryAfterOf(null, 'nothing'), isNull);
    });
  });
}
