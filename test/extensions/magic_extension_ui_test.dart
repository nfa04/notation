import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_service.dart';
import 'package:notes/extensions/extension_service.dart';
import 'package:notes/extensions/magic_extension.dart';
import 'package:notes/extensions/extension_manifest.dart';
import 'package:notes/screens/extension_settings.dart';
import 'package:notes/screens/magic_extension_dialog.dart';

import 'magic_fakes.dart';

void main() {
  late Directory dir;
  late Map<String, String> settings;
  late ExtensionService extensions;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('magic_ui');
    settings = {};
    extensions = ExtensionService((k) async => settings[k], (k, v) async => settings[k] = v, directory: () async => Directory('${dir.path}/extensions'), engine: ({onConsole}) => ReadingEngine());
  });
  tearDown(() => dir.deleteSync(recursive: true));

  final good = answer(
    manifest: json({
      'id': 'checklist',
      'name': 'Checklist',
      'version': '1.0.0',
      'tools': [{'id': 'make-list', 'title': 'Make a checklist'}],
    }),
    script: "notation.tool('make-list', (ctx) => ctx.text.split('\\n').map((l) => '- [ ] ' + l).join('\\n'));",
    explanation: 'Select some lines and get a checklist.',
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('describe it, read what the AI made, install it off or install and allow', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = Scripted([good, good]);
    final magic = MagicExtension(AiService(providers: [provider]), extensions);
    MagicInstalled? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => result = await showDialog<MagicInstalled>(context: context, builder: (_) => MagicExtensionDialog(magic: magic, extensions: extensions)),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('magic-request')), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('magic-request')), 'make lines a checklist');
    await tester.tap(find.byKey(const ValueKey('magic-create')));
    await settle(tester);

    // what it made is shown before anything is installed
    expect(find.byKey(const ValueKey('magic-explanation')), findsOneWidget);
    expect(find.text('Select some lines and get a checklist.'), findsOneWidget);
    expect(find.text('• Checklist: Make a checklist'), findsOneWidget);
    expect(find.text('Nothing: it only works on the text it is given.'), findsOneWidget);
    expect(extensions.installed, isEmpty, reason: 'nothing is installed before the person decides');
    await tester.tap(find.byKey(const ValueKey('magic-script')));
    await tester.pumpAndSettle();
    expect(find.textContaining("notation.tool('make-list'"), findsOneWidget);

    // a change is asked for: the model is asked again with it
    await tester.enterText(find.byKey(const ValueKey('magic-change')), 'also strip dashes');
    await tester.tap(find.byKey(const ValueKey('magic-change-go')));
    await settle(tester);
    expect(provider.prompts.last.user, contains('also strip dashes'));

    await tester.tap(find.byKey(const ValueKey('magic-install-allow')));
    await settle(tester);
    for (var i = 0; i < 30 && result == null; i++) {
      await settle(tester);
    }
    expect(result, isNotNull);
    expect(result!.allowed, isTrue);
    expect(result!.message, contains('installed and switched on'));
    final e = extensions.byId('checklist')!;
    expect(e.enabled, isTrue);
    expect(extensions.tools.map((t) => t.tool.id), ['make-list']);
  });

  testWidgets('install without allowing: it is in the list, off', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final magic = MagicExtension(AiService(providers: [Scripted([good])]), extensions);
    MagicInstalled? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => result = await showDialog<MagicInstalled>(context: context, builder: (_) => MagicExtensionDialog(magic: magic, extensions: extensions)),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('magic-request')), 'checklist');
    await tester.tap(find.byKey(const ValueKey('magic-create')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('magic-install')));
    await settle(tester);
    for (var i = 0; i < 30 && result == null; i++) {
      await settle(tester);
    }
    expect(result!.allowed, isFalse);
    expect(result!.message, contains('off until you switch it on'));
    expect(extensions.byId('checklist')!.enabled, isFalse);
    expect(extensions.tools, isEmpty);
  });

  testWidgets('an answer that cannot be made to work is said, and the request stays to try again', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final magic = MagicExtension(AiService(providers: [Scripted(['nonsense', 'nonsense', 'nonsense'])]), extensions);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MagicExtensionDialog(magic: magic, extensions: extensions))));
    await tester.enterText(find.byKey(const ValueKey('magic-request')), 'something');
    await tester.tap(find.byKey(const ValueKey('magic-create')));
    await settle(tester);
    expect(find.byKey(const ValueKey('magic-failure')), findsOneWidget);
    expect(find.byKey(const ValueKey('magic-request')), findsOneWidget);
    expect(find.textContaining('did not make a working extension'), findsOneWidget);
    expect(extensions.installed, isEmpty);
  });

  testWidgets('the button is in the extension settings only with an AI that can answer', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ExtensionSettings(service: extensions)))));
    expect(find.byKey(const ValueKey('extension-magic')), findsNothing);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ExtensionSettings(service: extensions, ai: AiService(providers: [Scripted([])]))))));
    await tester.pump();
    expect(find.byKey(const ValueKey('extension-magic')), findsOneWidget);
    expect(ExtensionPermission.values, isNotEmpty);
  });
}
