import 'package:flutter_test/flutter_test.dart';
import 'package:notes/extensions/extension_manifest.dart';

Map<String, Object?> valid([Map<String, Object?> more = const {}]) => {
      'id': 'word-count',
      'name': 'Word count',
      'version': '1.0.0',
      ...more,
    };

void main() {
  test('a small manifest', () {
    final m = ExtensionManifest.fromJson(valid());
    expect((m.id, m.name, m.version, m.main), ('word-count', 'Word count', '1.0.0', 'main.js'));
    expect(m.permissions, isEmpty);
  });

  test('a full manifest, and it comes back as it went in', () {
    final m = ExtensionManifest.fromJson(valid({
      'description': 'Counts words.',
      'author': 'Someone',
      'main': 'count.js',
      'permissions': ['note.read', 'network'],
      'hosts': ['API.example.com'],
      'tools': [
        {'id': 'count', 'title': 'Count the words'}
      ],
      'actions': [
        {'id': 'daily', 'title': 'Count every day'}
      ],
    }));
    expect(m.permissions, {ExtensionPermission.noteRead, ExtensionPermission.network});
    expect(m.hosts, ['api.example.com']);
    expect(m.tools.single.title, 'Count the words');
    final again = ExtensionManifest.fromJson(m.toJson());
    expect((again.id, again.main), (m.id, m.main));
    expect(again.hosts, m.hosts);
    expect(again.permissions, m.permissions);
    expect((again.tools.length, again.actions.length), (1, 1));
  });

  group('what is refused', () {
    void refused(String why, Object? json, String reason) =>
        test(why, () => expect(() => ExtensionManifest.fromJson(json), throwsA(isA<ManifestException>().having((e) => e.message, 'message', contains(reason)))));

    refused('not an object', [1], 'not a JSON object');
    refused('no id', {'name': 'x', 'version': '1'}, '"id"');
    refused('a bad id', valid({'id': '../evil'}), '"id"');
    refused('a short id', valid({'id': 'a'}), '"id"');
    refused('no name', {'id': 'abc', 'version': '1'}, '"name"');
    refused('no version', {'id': 'abc', 'name': 'x'}, '"version"');
    refused('a name that is not text', valid({'name': 3}), 'text');
    refused('a script in a folder', valid({'main': '../x.js'}), '"main"');
    refused('a script that is not js', valid({'main': 'x.exe'}), '"main"');
    refused('an unknown permission', valid({'permissions': ['files.everything']}), 'Unknown permission');
    refused('network without hosts', valid({'permissions': ['network']}), 'needs "hosts"');
    refused('hosts without network', valid({'hosts': ['example.com']}), 'only for the permission');
    refused('a host with a path', valid({'permissions': ['network'], 'hosts': ['example.com/x']}), 'not a website name');
    refused('a host with a wildcard', valid({'permissions': ['network'], 'hosts': ['*.example.com']}), 'not a website name');
    refused('a url as host', valid({'permissions': ['network'], 'hosts': ['https://example.com']}), 'not a website name');
    refused('a tool without title', valid({'tools': [{'id': 'a'}]}), 'title');
    refused('a tool with a bad id', valid({'tools': [{'id': 'A B', 'title': 't'}]}), '"id"');
    refused('two tools with the same id', valid({'tools': [{'id': 'a', 'title': 't'}, {'id': 'a', 'title': 'u'}]}), 'same');
    refused('too many tools', valid({'tools': [for (var i = 0; i < 21; i++) {'id': 't$i', 'title': 't'}]}), 'at most 20');
    refused('an over-long description', valid({'description': 'x' * 500}), 'too long');
  });
}
