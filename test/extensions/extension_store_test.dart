import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/extensions/extension_service.dart';
import 'package:notes/data/safe_zip.dart';
import 'package:notes/extensions/extension_store.dart';
import 'package:notes/extensions/store_defaults.dart';
import 'package:notes/screens/extension_store.dart';

String sha(List<int> b) => crypto.sha256.convert(b).toString();

Uint8List zipOf(Map<String, String> files) {
  final a = Archive();
  files.forEach((n, c) => a.addFile(ArchiveFile(n, utf8.encode(c).length, utf8.encode(c))));
  return Uint8List.fromList(ZipEncoder().encode(a));
}

Uint8List manifestZip(String id, {String version = '1.0.0', List<String> permissions = const [], String name = 'Demo'}) => zipOf({
      'manifest.json': jsonEncode({'id': id, 'name': name, 'version': version, 'permissions': permissions, 'tools': [{'id': 't', 'title': 'T'}]}),
      'main.js': "notation.tool('t', (c) => c.text);",
    });

final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4]);

String _hashOfFile(Uint8List zip, String name) => sha(ZipDecoder().decodeBytes(zip).files.firstWhere((f) => f.name == name).content as List<int>);

Map<String, Object?> entryFor(String id, Uint8List zip, {String version = '1.0.0', List<String> permissions = const [], Uint8List? logo, String? mainSha}) => {
      'id': id, 'name': 'Demo $id', 'version': version, 'author': 'A', 'summary': 'Does a thing.', 'description': 'Long text.', 'category': 'writing',
      'tags': ['x'], 'permissions': permissions, 'hosts': <String>[], 'updated': '2026-11-26', 'size': zip.length, 'sha256': sha(zip), 'logoSha256': sha(logo ?? png),
      'manifestSha256': _hashOfFile(zip, 'manifest.json'), 'mainSha256': mainSha ?? _hashOfFile(zip, 'main.js'),
    };

/// A fake store: signs its catalogue like the PHP server does, serves files from a map, and records what was asked for.
class FakeStore {
  final SimpleKeyPair pair;
  final SimplePublicKey pub;
  final Map<String, Uint8List> files = {};
  final List<String> asked = [];
  FakeStore(this.pair, this.pub);

  static Future<FakeStore> make() async {
    final pair = await Ed25519().newKeyPair();
    return FakeStore(pair, await pair.extractPublicKey());
  }

  String get key => base64.encode(pub.bytes);

  Future<void> publish({required int sequence, required List<Map<String, Object?>> entries, SimpleKeyPair? signWith, bool tamper = false}) async {
    final json = Uint8List.fromList(utf8.encode(jsonEncode({'format': 1, 'sequence': sequence, 'generated': 'x', 'extensions': entries})));
    final sig = await Ed25519().sign([...utf8.encode(ExtensionStoreClient.domain), ...json], keyPair: signWith ?? pair);
    files['/v1/index.json'] = tamper ? Uint8List.fromList([...json.sublist(0, json.length - 2), 0x20, json.last]) : json;
    files['/v1/index.json.sig'] = Uint8List.fromList(utf8.encode('${base64.encode(sig.bytes)}\n'));
  }

  Future<Uint8List> fetch(Uri url, int max) async {
    asked.add('${url.scheme}://${url.host}${url.path}');
    final f = files[url.path];
    if (f == null) throw const StoreException('The store answered with error 404.');
    if (f.length > max) throw const StoreException('The store sent more than it should.');
    return f;
  }

  ExtensionStoreClient client({StoreMemory? memory, List<String>? keys}) =>
      ExtensionStoreClient(base: Uri.parse('https://store.example.org'), fetch: fetch, publicKeys: keys ?? [key], memory: memory ?? MemoryStoreMemory());
}

void main() {
  storeSourceTests();
  late FakeStore store;
  setUp(() async => store = await FakeStore.make());

  group('the catalogue', () {
    test('a signed catalogue is read, and the number is remembered', () async {
      final zip = manifestZip('demo');
      await store.publish(sequence: 3, entries: [entryFor('demo', zip)]);
      final memory = MemoryStoreMemory();
      final c = await store.client(memory: memory).catalogue();
      expect(c.sequence, 3);
      expect(c.entries.single.id, 'demo');
      expect(await memory.lastSequence('store.example.org'), 3);
    });

    test('one changed byte is refused', () async {
      await store.publish(sequence: 1, entries: [entryFor('demo', manifestZip('demo'))], tamper: true);
      await expectLater(store.client().catalogue(), throwsA(isA<StoreException>().having((e) => e.message, 'message', contains('not signed'))));
    });

    test('a signature of another key is refused, and a key list with the right one among them is fine (key replacement)', () async {
      final other = await Ed25519().newKeyPair();
      await store.publish(sequence: 1, entries: [], signWith: other);
      await expectLater(store.client().catalogue(), throwsA(isA<StoreException>()));
      final otherPub = base64.encode((await other.extractPublicKey()).bytes);
      expect((await store.client(keys: [store.key, otherPub]).catalogue()).sequence, 1);
    });

    test('a signature over the bare bytes (no domain) is not accepted', () async {
      final json = Uint8List.fromList(utf8.encode('{"format":1,"sequence":1,"extensions":[]}'));
      final sig = await Ed25519().sign(json, keyPair: store.pair);
      store.files['/v1/index.json'] = json;
      store.files['/v1/index.json.sig'] = Uint8List.fromList(utf8.encode(base64.encode(sig.bytes)));
      await expectLater(store.client().catalogue(), throwsA(isA<StoreException>()));
    });

    test('garbage signatures are refused without crashing', () async {
      await store.publish(sequence: 1, entries: []);
      for (final junk in ['', 'not base64!!', base64.encode([1, 2, 3]), '\u0000\u0001']) {
        store.files['/v1/index.json.sig'] = Uint8List.fromList(utf8.encode(junk));
        await expectLater(store.client().catalogue(), throwsA(isA<StoreException>()), reason: junk);
      }
    });

    test('an older (once genuine) catalogue is refused: no rollback', () async {
      final memory = MemoryStoreMemory();
      await store.publish(sequence: 5, entries: []);
      await store.client(memory: memory).catalogue();
      await store.publish(sequence: 4, entries: []);
      await expectLater(store.client(memory: memory).catalogue(), throwsA(isA<StoreException>().having((e) => e.message, 'm', contains('older'))));
      await store.publish(sequence: 5, entries: []);
      await store.client(memory: memory).catalogue(); // the same one again is fine
    });

    test('bad entries are refused', () async {
      final zip = manifestZip('demo');
      for (final bad in [
        {...entryFor('demo', zip), 'id': '../etc'},
        {...entryFor('demo', zip), 'id': 'a..b'},
        {...entryFor('demo', zip), 'id': 'UPPER'},
        {...entryFor('demo', zip), 'sha256': 'zz'},
        {...entryFor('demo', zip), 'size': 99999999},
        {...entryFor('demo', zip), 'size': '5'},
        {...entryFor('demo', zip), 'name': ''},
        {...entryFor('demo', zip), 'name': 'x' * 61},
        {...entryFor('demo', zip), 'tags': ['a', 5]},
      ]) {
        await store.publish(sequence: 1, entries: [bad]);
        await expectLater(store.client().catalogue(), throwsA(isA<StoreException>()), reason: '$bad');
      }
      await store.publish(sequence: 1, entries: [entryFor('demo', zip), entryFor('demo', zip)]);
      await expectLater(store.client().catalogue(), throwsA(isA<StoreException>().having((e) => e.message, 'm', contains('twice'))));
    });

    test('only https, and no store address means no store', () async {
      expect(ExtensionStoreClient(base: Uri.parse('http://store.example.org'), fetch: store.fetch, publicKeys: [store.key]).configured, isFalse);
      expect(ExtensionStoreClient(base: Uri.parse(''), fetch: store.fetch, publicKeys: [store.key]).configured, isFalse);
      await expectLater(ExtensionStoreClient(base: Uri.parse('http://store.example.org'), fetch: store.fetch).catalogue(), throwsA(isA<StoreException>()));
      await expectLater(fetchLimited(Uri.parse('http://store.example.org/v1/index.json'), 100), throwsA(isA<StoreException>()));
      expect(store.asked, isEmpty);
    });

    test('a different format is "too old", not a crash', () async {
      final json = Uint8List.fromList(utf8.encode('{"format":2}'));
      final sig = await Ed25519().sign([...utf8.encode(ExtensionStoreClient.domain), ...json], keyPair: store.pair);
      store.files['/v1/index.json'] = json;
      store.files['/v1/index.json.sig'] = Uint8List.fromList(utf8.encode(base64.encode(sig.bytes)));
      await expectLater(store.client().catalogue(), throwsA(isA<StoreException>().having((e) => e.message, 'm', contains('too old'))));
    });
  });

  group('downloads', () {
    test('the zip must be exactly what was listed; the address is built from the id, never taken from the catalogue', () async {
      final zip = manifestZip('demo');
      store.files['/v1/extensions/demo/extension.zip'] = zip;
      final e = StoreEntry.fromJson({...entryFor('demo', zip), 'zip': 'https://evil.example/x.zip'});
      expect(await store.client().zip(e), zip);
      expect(store.asked.single, 'https://store.example.org/v1/extensions/demo/extension.zip');
      store.files['/v1/extensions/demo/extension.zip'] = manifestZip('demo', name: 'Changed');
      await expectLater(store.client().zip(e), throwsA(isA<StoreException>()));
      store.files['/v1/extensions/demo/extension.zip'] = Uint8List(zip.length + 5);
      await expectLater(store.client().zip(e), throwsA(isA<StoreException>()));
    });

    test('a logo is only used when it is the listed one and a png', () async {
      final e = StoreEntry.fromJson(entryFor('demo', manifestZip('demo')));
      store.files['/v1/extensions/demo/logo.png'] = png;
      expect(await store.client().logo(e), png);
      store.files['/v1/extensions/demo/logo.png'] = Uint8List.fromList(utf8.encode('<svg onload=alert(1)>'));
      expect(await store.client().logo(e), isNull);
      store.files.remove('/v1/extensions/demo/logo.png');
      expect(await store.client().logo(e), isNull);
      final svg = Uint8List.fromList(utf8.encode('<svg onload=alert(1)>'));
      store.files['/v1/extensions/demo/logo.png'] = svg;
      expect(await store.client().logo(StoreEntry.fromJson(entryFor('demo', manifestZip('demo'), logo: svg))), isNull, reason: 'not a png even with the right hash');
    });
  });

  group('the store page', () {
    late Directory dir;
    late Map<String, String> saved;
    ExtensionService service() => ExtensionService((k) async => saved[k], (k, v) async => saved[k] = v, directory: () async => Directory('${dir.path}/ext'));

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('store');
      saved = {};
    });
    tearDown(() => dir.delete(recursive: true));

    Future<void> open(WidgetTester tester, ExtensionService s, ExtensionStoreClient c) async {
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: ExtensionStorePage(service: s, client: c)));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    testWidgets('lists, searches, and installs only after the person says yes', (tester) async {
      final a = manifestZip('alpha', permissions: ['note.read']), b = manifestZip('beta');
      store.files['/v1/extensions/alpha/extension.zip'] = a;
      store.files['/v1/extensions/beta/extension.zip'] = b;
      await store.publish(sequence: 1, entries: [entryFor('alpha', a, permissions: ['note.read']), entryFor('beta', b)]);
      final s = service();
      await open(tester, s, store.client());
      expect(find.byKey(const ValueKey('store-entry-alpha')), findsOneWidget);
      expect(find.byKey(const ValueKey('store-entry-beta')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('store-search')), 'alpha');
      await tester.pump();
      expect(find.byKey(const ValueKey('store-entry-beta')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('store-search')), '');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('store-install-alpha')));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byKey(const ValueKey('extension-review')), findsOneWidget, reason: 'the permission dialog comes first');
      expect(s.byId('alpha'), isNull, reason: 'nothing is installed before the yes');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(s.byId('alpha'), isNull);
    });

    testWidgets('a download whose manifest is not what the catalogue listed is not installed', (tester) async {
      final z = manifestZip('alpha', permissions: ['note.read', 'note.write']); // asks for more than listed
      store.files['/v1/extensions/alpha/extension.zip'] = z;
      await store.publish(sequence: 1, entries: [entryFor('alpha', z, permissions: ['note.read'])]);
      final s = service();
      await open(tester, s, store.client());
      await tester.tap(find.byKey(const ValueKey('store-install-alpha')));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byKey(const ValueKey('extension-review')), findsNothing);
      expect(find.textContaining('not the one the store listed'), findsOneWidget);
      expect(s.byId('alpha'), isNull);
    });

    testWidgets('a script that is not the one the store reviewed is not installed', (tester) async {
      final z = manifestZip('alpha');
      store.files['/v1/extensions/alpha/extension.zip'] = z;
      await store.publish(sequence: 1, entries: [entryFor('alpha', z, mainSha: sha(utf8.encode('something else')))]);
      final s = service();
      await open(tester, s, store.client());
      await tester.tap(find.byKey(const ValueKey('store-install-alpha')));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byKey(const ValueKey('extension-review')), findsNothing);
      expect(find.textContaining('not the ones the store reviewed'), findsOneWidget);
      expect(s.byId('alpha'), isNull);
    });

    testWidgets('an unsigned catalogue shows an error and a retry, and lists nothing', (tester) async {
      await store.publish(sequence: 1, entries: [entryFor('alpha', manifestZip('alpha'))], tamper: true);
      await open(tester, service(), store.client());
      expect(find.byKey(const ValueKey('store-retry')), findsOneWidget);
      expect(find.byKey(const ValueKey('store-entry-alpha')), findsNothing);
      expect(find.textContaining('not signed'), findsOneWidget);
    });

    testWidgets('with no store address it says so', (tester) async {
      await open(tester, service(), ExtensionStoreClient(base: Uri.parse(''), fetch: store.fetch));
      expect(find.textContaining('No extension store is set up'), findsOneWidget);
    });
  });

  // The store's own repository, when it is next to this one (or NOTATION_STORE_DIR names it): what it publishes must be what this app accepts.
  group('the real store repository', () {
    final dirName = Platform.environment['NOTATION_STORE_DIR'] ?? '${Directory.current.parent.path}/notation-extension-store';
    final here = Directory(dirName).existsSync();
    final skip = here ? null : 'the store repository is not at $dirName';

    test('its catalogue is signed by the key built into the app, and the app takes every zip', () async {
      final json = Uint8List.fromList(File('$dirName/data/index.json').readAsBytesSync());
      final sig = Uint8List.fromList(File('$dirName/data/index.json.sig').readAsBytesSync());
      expect(await ExtensionStoreClient(base: Uri.parse('https://x.example'), fetch: (_, _) async => json).verifies(json, sig), isTrue);
      expect(File('$dirName/store.pub').readAsStringSync().trim(), extensionStorePublicKeys.first);
      final s = ExtensionService((k) async => null, (k, v) async {}, directory: () async => Directory.systemTemp);
      final entries = (jsonDecode(utf8.decode(json))['extensions'] as List).map(StoreEntry.fromJson).toList();
      expect(entries, isNotEmpty);
      for (final e in entries) {
        final bytes = File('$dirName/packages/${e.id}/extension.zip').readAsBytesSync();
        expect(bytes.length, e.size);
        expect(sha(bytes), e.sha256);
        final m = s.inspectZip(bytes).manifest;
        expect(m.id, e.id);
        expect(m.version, e.version);
        expect({for (final p in m.permissions) p.id}, e.permissions.toSet());
      }
    }, skip: skip);
  });
}

void storeSourceTests() {
  group('StoreSource.problem', () {
    final key = base64.encode(List.filled(32, 7));
    test('accepts an https host and a 32 byte key', () {
      expect(StoreSource.problem('https://store.example.org', key), isNull);
      expect(StoreSource.problem('https://store.example.org/', key), isNull);
    });
    test('refuses http, paths, credentials, queries and bad keys', () {
      for (final a in ['http://store.example.org', 'https://store.example.org/x', 'https://u:p@store.example.org', 'https://store.example.org?a=1', 'store.example.org', '']) {
        expect(StoreSource.problem(a, key), isNotNull, reason: a);
      }
      expect(StoreSource.problem('https://store.example.org', ''), isNotNull);
      expect(StoreSource.problem('https://store.example.org', base64.encode(List.filled(31, 1))), isNotNull);
      expect(StoreSource.problem('https://store.example.org', 'not base64!'), isNotNull);
    });
    test('the built-in source uses the built-in address and keys; a chosen one only its own key', () {
      expect(StoreSource.builtIn.keys, extensionStorePublicKeys);
      final s = StoreSource('https://store.example.org', key);
      expect(s.keys, [key]);
      expect(s.uri.host, 'store.example.org');
    });
  });

  group('zips that are run', () {
    test('a local file name that differs from the directory is refused', () {
      final z = zipOf({'notes.txt': 'evil', 'main.js': 'good'});
      final at = String.fromCharCodes(z).indexOf('notes.txt');
      final bad = Uint8List.fromList(z)..setRange(at, at + 9, 'main.js  '.codeUnits.take(9)); // first local header says "main.js  "
      expect(() => decodeZipLimited(bad, strict: true), throwsA(anything));
      expect(decodeZipLimited(z, strict: true).files.length, 2);
    });
  });

  test('versions are compared as numbers, a release is after its pre-release', () {
    expect(isNewerVersion('1.10.0', '1.9.0'), isTrue);
    expect(isNewerVersion('1.9.0', '1.10.0'), isFalse);
    expect(isNewerVersion('1.0.0', '1.0.0'), isFalse);
    expect(isNewerVersion('1.0', '1.0.0'), isFalse);
    expect(isNewerVersion('1.0.0', '1.0.0-beta'), isTrue);
    expect(isNewerVersion('1.0.0-beta', '1.0.0'), isFalse);
    expect(isNewerVersion('2', '1.9'), isTrue);
    expect(isNewerVersion('banana', '1.0.0'), isTrue);
  });
}
