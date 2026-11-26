import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/extensions/extension_manifest.dart';
import 'package:notes/extensions/extension_service.dart';
import 'package:notes/extensions/script_engine.dart';
import 'package:notes/transcript/transcript_source.dart';

/// The extension in extensions/youtube-transcripts, run against answers shaped like YouTube's (made up here, not copied).
void main() {
  final manifest = File('extensions/youtube-transcripts/manifest.json').readAsStringSync();
  final script = File('extensions/youtube-transcripts/main.js').readAsStringSync();
  final skip = QuickJsEngine.available ? null : 'the JavaScript engine is not here';

  test('the manifest is valid and asks for the network and nothing but youtube.com', () {
    final m = ExtensionManifest.fromJson(jsonDecode(manifest));
    expect(m.permissions, {ExtensionPermission.network});
    expect(m.hosts, ['www.youtube.com']);
    expect(m.transcriptSources.single.id, 'youtube');
  });

  late Directory dir;
  late Map<String, String> settings;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ext');
    settings = {};
  });
  tearDown(() => dir.delete(recursive: true));

  const timedtext = 'https://www.youtube.com/api/timedtext?v=abcdefghijk&lang=';
  const xml = '<?xml version="1.0"?><timedtext format="3"><body><p t="1000" d="2000">Hello &#39;there&#39;</p><p t="65000" d="1000">A minute on</p></body></timedtext>';

  String player({String status = 'OK', List<Map<String, Object?>>? tracks, String title = 'My talk'}) => jsonEncode({
        'playabilityStatus': {'status': status, 'reason': ?(status == 'OK' ? null : 'Sign in to confirm your age')},
        'videoDetails': {'title': title},
        'captions': ?(tracks == null ? null : {'playerCaptionsTracklistRenderer': {'captionTracks': tracks}}),
      });

  Map<String, Object?> track(String lang, {String? kind, String? url}) => {'baseUrl': url ?? '$timedtext$lang${kind == null ? '' : '&kind=$kind'}', 'languageCode': lang, 'kind': ?kind};

  Future<({TranscriptSource source, List<Uri> asked, List<String> bodies})> setUpWith(Map<String, Object?> Function(Uri url) answer) async {
    final asked = <Uri>[];
    final bodies = <String>[];
    Future<Map<String, Object?>> fetch(Uri url, {String method = 'GET', Map<String, String> headers = const {}, String? body}) async {
      asked.add(url);
      if (body != null) bodies.add(body);
      return answer(url);
    }

    final s = ExtensionService((k) async => settings[k], (k, v) async => settings[k] = v, directory: () async => Directory('${dir.path}/extensions'), fetch: fetch);
    await s.installSource(manifest, script);
    await s.setEnabled('youtube-transcripts', true);
    await s.setGranted('youtube-transcripts', ExtensionPermission.network, true);
    return (source: s.transcriptChoices.single, asked: asked, bodies: bodies);
  }

  Map<String, Object?> ok(String body) => {'status': 200, 'headers': <String, String>{}, 'body': body};

  test('a link gives the captions, the title and the link of the video', () async {
    final t = await setUpWith((url) => url.path.contains('youtubei') ? ok(player(tracks: [track('en')])) : ok(xml));
    final r = await t.source.fetch('https://youtu.be/abcdefghijk?si=xyz');
    expect(r.title, 'My talk');
    expect(r.language, 'en');
    expect(r.source, 'https://www.youtube.com/watch?v=abcdefghijk');
    expect(r.segments.map((s) => s.text), ["Hello 'there'", 'A minute on']);
    expect(t.asked.map((u) => u.host).toSet(), {'www.youtube.com'});
    expect(jsonDecode(t.bodies.single)['videoId'], 'abcdefghijk');
  }, skip: skip);

  test('the forms of an address that name a video, and those that do not', () async {
    final t = await setUpWith((url) => url.path.contains('youtubei') ? ok(player(tracks: [track('en')])) : ok(xml));
    for (final good in [
      'https://www.youtube.com/watch?v=abcdefghijk',
      'https://www.youtube.com/watch?list=PL1&v=abcdefghijk&t=5s',
      'http://m.youtube.com/watch?v=abcdefghijk',
      'https://music.youtube.com/watch?v=abcdefghijk',
      'youtube.com/shorts/abcdefghijk',
      'https://www.youtube.com/embed/abcdefghijk?start=3',
      'https://www.youtube.com/live/abcdefghijk',
      'abcdefghijk',
    ]) {
      expect((await t.source.fetch(good)).source, endsWith('abcdefghijk'), reason: good);
    }
    for (final bad in ['https://vimeo.com/123456789', 'https://evil.example/watch?v=abcdefghijk', 'https://www.youtube.com/', 'not a link at all', '']) {
      await expectLater(t.source.fetch(bad), throwsA(isA<TranscriptSourceError>().having((e) => e.message, 'message', contains('not a YouTube link'))), reason: bad);
    }
  }, skip: skip);

  test('a track written by a person in the spoken language is taken before the automatic one and before other languages', () async {
    final t = await setUpWith((url) {
      if (url.path.contains('youtubei')) {
        return ok(player(tracks: [track('de', kind: 'asr'), track('fr'), track('de-CH'), track('en')]));
      }
      return ok(xml);
    });
    final r = await t.source.fetch('abcdefghijk');
    expect(r.language, 'de-CH');
    expect(t.asked.last.toString(), contains('lang=de-CH'));
  }, skip: skip);

  test('only automatic captions: they are taken', () async {
    final t = await setUpWith((url) => url.path.contains('youtubei') ? ok(player(tracks: [track('en', kind: 'asr')])) : ok(xml));
    expect((await t.source.fetch('abcdefghijk')).language, 'en');
  }, skip: skip);

  test('what goes wrong is told in a sentence', () async {
    Future<String> messageFor(Map<String, Object?> Function(Uri) answer) async {
      final t = await setUpWith(answer);
      try {
        await t.source.fetch('abcdefghijk');
      } on TranscriptSourceError catch (e) {
        return e.message;
      }
      return 'no error';
    }

    expect(await messageFor((u) => ok(player(tracks: const []))), contains('no captions'));
    expect(await messageFor((u) => ok(player())), contains('no captions'));
    expect(await messageFor((u) => ok(player(status: 'LOGIN_REQUIRED'))), contains('Sign in to confirm your age'));
    expect(await messageFor((u) => {'status': 429, 'headers': <String, String>{}, 'body': ''}), contains('429'));
    expect(await messageFor((u) => ok('<html>not json</html>')), contains('cannot be read'));
    expect(await messageFor((u) => u.path.contains('youtubei') ? ok(player(tracks: [track('en')])) : {'status': 200, 'headers': <String, String>{}, 'body': '  '}), contains('did not hand over'));
    expect(await messageFor((u) => ok(player(tracks: [track('en', url: 'https://evil.example/steal')]))), contains('may not use'));
    expect(await messageFor((u) => u.path.contains('youtubei') ? ok(player(tracks: [track('en')])) : ok('not captions')), contains('captions'));
  }, skip: skip);
}
