import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/openai_provider.dart';
import 'package:notes/screens/openai_providers_settings.dart';
import 'package:notes/sync/caldav_service.dart' show SecretStore;

class _Secret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

void main() {
  testWidgets('adding, switching, editing and deleting services in the settings', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = OpenAiProvider(secret: _Secret(), transport: (_, _, _, _) => const Stream.empty());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: OpenAiProvidersSection(provider: p)))));

    expect(find.text('Set up a service to use it.'), findsOneWidget);

    // add one from a preset
    await tester.tap(find.byKey(const ValueKey('openai-add-service')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('openai-preset-Ollama')));
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('openai-name'))).controller!.text, 'Ollama');
    // Save waits for a model
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('openai-save'))).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('openai-model')), 'llama3.2');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('openai-save')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(p.profiles.length, 1, reason: 'the empty first service is filled in');
    expect((p.config.baseUrl, p.config.model, p.activeProfile.title), ('http://localhost:11434/v1', 'llama3.2', 'Ollama'));

    // a second one
    await tester.tap(find.byKey(const ValueKey('openai-add-service')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('openai-preset-Groq')));
    await tester.enterText(find.byKey(const ValueKey('openai-model')), 'llama-3.3');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('openai-save')));
    await tester.pumpAndSettle();
    expect((p.profiles.length, p.activeProfile.title), (2, 'Groq'));

    // switch back to the first by tapping it
    await tester.tap(find.byKey(ValueKey('openai-service-${OpenAiProvider.firstProfileId}')));
    await tester.pump();
    expect(p.activeProfile.id, OpenAiProvider.firstProfileId);

    // edit the second one without making it the one in use
    final second = p.profiles.last;
    await tester.tap(find.byKey(ValueKey('openai-edit-${second.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('openai-key')), 'sk-x');
    await tester.tap(find.byKey(const ValueKey('openai-save')));
    await tester.pumpAndSettle();
    expect((p.keyOf(second.id), p.activeProfile.id), ('sk-x', OpenAiProvider.firstProfileId));

    // deleting asks twice
    await tester.tap(find.byKey(ValueKey('openai-edit-${second.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('openai-delete')));
    await tester.pump();
    expect(p.profiles.length, 2);
    await tester.tap(find.byKey(const ValueKey('openai-delete')));
    await tester.pumpAndSettle();
    expect(p.profiles.length, 1);
  });
}
