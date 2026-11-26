import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/extensions/extension_host.dart' show ExtensionFetch;
import 'package:notes/extensions/extension_manifest.dart';
import 'package:notes/extensions/extension_service.dart';
import 'package:notes/extensions/script_engine.dart';
import 'package:notes/transcript/script_result.dart';
import 'package:notes/transcript/transcript.dart';
import 'package:notes/transcript/transcript_source.dart';

Map<String, Object?> valid([Map<String, Object?> more = const {}]) => {'id': 'videos', 'name': 'Videos', 'version': '1.0.0', ...more};
const _source = {'id': 'site', 'title': 'The site', 'hint': 'A link'};

void main() {
  group('the manifest', () {
    test('a source is read, needs no permission, and comes back as it went in', () {
      final m = ExtensionManifest.fromJson(valid({'transcriptSources': [_source]}));
      expect(m.transcriptSources.single.title, 'The site');
      expect(m.transcriptSources.single.hint, 'A link');
      expect(m.permissions, isEmpty);
      final again = ExtensionManifest.fromJson(jsonDecode(jsonEncode(m.toJson())));
      expect(again.transcriptSources.single.id, 'site');
      expect(again.transcriptSources.single.hint, 'A link');
    });

    test('a bad id, no title, a long hint and a repeated id are refused', () {
      for (final bad in [
        {'id': 'Bad Id', 'title': 'X'},
        {'id': 'x'},
        {'id': 'x', 'title': 'X', 'hint': 'y' * 121},
        {'id': 'x', 'title': 'X', 'hint': 5},
      ]) {
        expect(() => ExtensionManifest.fromJson(valid({'transcriptSources': [bad]})), throwsA(isA<ManifestException>()), reason: '$bad');
      }
      expect(() => ExtensionManifest.fromJson(valid({'transcriptSources': [_source, _source]})), throwsA(isA<ManifestException>()));
    });
  });

  group('what a script answers', () {
    Transcript parse(Object? v) => transcriptFromScript(v, input: 'https://typed.example/v');
    String? refused(Object? v) {
      try {
        parse(v);
        return null;
      } on TranscriptSourceError catch (e) {
        return e.message;
      }
    }

    test('segments: sorted, empty text dropped, optional end', () {
      final t = parse({
        'title': '  A\ntalk ',
        'language': 'en',
        'segments': [
          {'start': 5, 'end': 7.5, 'text': 'second'},
          {'start': 1, 'text': ' first\n line '},
          {'start': 3, 'text': '   '},
        ],
      });
      expect(t.title, 'A talk');
      expect(t.language, 'en');
      expect(t.segments.map((s) => s.text), ['first line', 'second']);
      expect(t.segments[0].end, 1);
      expect(t.segments[1].end, 7.5);
      expect(t.source, 'https://typed.example/v', reason: 'what was typed, when the script names none');
    });

    test('captions as text are read by the app; the script may name the address', () {
      final t = parse({'captions': {'text': 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi'}, 'source': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'});
      expect(t.segments.single.text, 'Hi');
      expect(t.source, 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    });

    test('an address from the script that is not http(s) or has odd characters is not kept', () {
      for (final bad in ['javascript:alert(1)', 'file:///etc/passwd', 'https://x.example/a b', 'https://x.example/>[evil](x)']) {
        expect(parse({'segments': [{'start': 0, 'text': 'x'}], 'source': bad}).source, 'https://typed.example/v', reason: bad);
      }
    });

    test('answers that are not right are refused with a sentence', () {
      expect(refused(null), isNotNull);
      expect(refused('text'), isNotNull);
      expect(refused({}), contains('neither'));
      expect(refused({'segments': 'x'}), isNotNull);
      expect(refused({'segments': [5]}), isNotNull);
      expect(refused({'segments': [{'start': -1, 'text': 'x'}]}), contains('start'));
      expect(refused({'segments': [{'start': double.nan, 'text': 'x'}]}), contains('start'));
      expect(refused({'segments': [{'start': 5, 'end': 2, 'text': 'x'}]}), contains('end'));
      expect(refused({'segments': [{'start': 1}]}), contains('text'));
      expect(refused({'captions': {'text': 'not captions'}}), isNotNull);
      expect(refused({'segments': [{'start': 0, 'text': 'x'}], 'title': 5}), contains('title'));
    });
  });

  group('running a source', () {
    final skip = QuickJsEngine.available ? null : 'the JavaScript engine is not here';
    late Directory dir;
    late Map<String, String> settings;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ext');
      settings = {};
    });
    tearDown(() => dir.delete(recursive: true));

    ExtensionService make({ExtensionFetch? fetch}) =>
        ExtensionService((k) async => settings[k], (k, v) async => settings[k] = v, directory: () async => Directory('${dir.path}/extensions'), fetch: fetch);

    test('it is offered while the extension is on, takes the typed address and fetches through network', () async {
      final asked = <Uri>[];
      final s = make(fetch: (url, {method = 'GET', headers = const {}, body}) async {
        asked.add(url);
        return {'status': 200, 'headers': <String, String>{}, 'body': 'WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nFrom the net\n\n00:01:00.000 --> 00:01:02.000\nA minute on'};
      });
      await s.installSource(
        jsonEncode(valid({'permissions': ['network'], 'hosts': ['captions.example'], 'transcriptSources': [_source]})),
        '''notation.transcriptSource('site', async (ctx) => {
          const res = await notation.network.fetch('https://captions.example/get?u=' + encodeURIComponent(ctx.input));
          if (res.status !== 200) throw new Error('No captions for this video.');
          return { captions: { text: res.body }, title: 'Fetched' };
        });''',
      );
      expect(s.transcriptChoices, isEmpty, reason: 'off');
      await s.setEnabled('videos', true);
      final choice = s.transcriptChoices.single;
      expect(choice.id, 'ext:videos/site');
      expect(choice.title, 'The site');

      // (without the permission the script's request is refused)
      await expectLater(choice.fetch('https://v.example/1'), throwsA(isA<TranscriptSourceError>().having((e) => e.message, 'message', contains('network'))));
      await s.setGranted('videos', ExtensionPermission.network, true);
      final t = await s.transcriptChoices.single.fetch('https://v.example/1');
      expect(t.title, 'Fetched');
      expect(t.segments.map((e) => e.text), ['From the net', 'A minute on']);
      expect(asked.single.host, 'captions.example');
      expect(asked.single.queryParameters['u'], 'https://v.example/1');
    }, skip: skip);

    test('an error the script throws reaches the person as its sentence; a wrong answer is refused', () async {
      final s = make();
      await s.installSource(
        jsonEncode(valid({'transcriptSources': [_source, {'id': 'bad', 'title': 'Bad'}]})),
        '''notation.transcriptSource('site', async () => { throw new Error('No captions for this video.'); });
           notation.transcriptSource('bad', async () => ({ segments: [{ start: 'soon', text: 'x' }] }));''',
      );
      await s.setEnabled('videos', true);
      final byId = {for (final c in s.transcriptChoices) c.id: c};
      await expectLater(byId['ext:videos/site']!.fetch('x'), throwsA(isA<TranscriptSourceError>().having((e) => e.message, 'message', 'No captions for this video.')));
      await expectLater(byId['ext:videos/bad']!.fetch('x'), throwsA(isA<TranscriptSourceError>().having((e) => e.message, 'message', contains('start'))));
    }, skip: skip);
  });
}
