// A probe of the pieces a cloud-folder publish and pull use, in the browser; POSTs what happened to /result.
// Build: flutter build web -t tool/web_probe/cloud_probe.dart --output build/probe --no-pub --no-wasm-dry-run --no-web-resources-cdn
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:notes/collab/compression.dart';
import 'package:notes/collab/secure_box.dart';
import 'package:notes/data/note_file.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final log = <String>[];
  Future<void> step(String name, Future<Object?> Function() f) async {
    try {
      log.add('ok   $name: ${await f()}');
    } catch (e, s) {
      log.add('FAIL $name: $e\n${s.toString().split('\n').take(6).join('\n')}');
    }
  }

  final rnd = Random(1);
  Uint8List bytes(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) rnd.nextInt(256)]);
  final key = bytes(32);
  final aad = utf8.encode('notation-cloud-file-v1|x/n/abc.123');
  Uint8List? zip;
  await step('zip small', () async {
    zip = zipNoteFile([('manifest.json', Uint8List.fromList(utf8.encode('{"note":{"createdAt":1}}')), true), ('doc.pdf', bytes(5000), false), ('a.txt', Uint8List.fromList(utf8.encode('hello hello hello ' * 50)), true)]);
    return zip!.length;
  });
  await step('digest', () async => noteContentDigest(zip!));
  await step('seal small with aad', () async {
    final s = await sealApart(key, zip!, aad: aad);
    final o = await openApart(key, s, aad: aad);
    return '${s.length} ${o.length}';
  });
  await step('seal big (apart)', () async {
    final s = await sealApart(key, bytes(300 * 1024), aad: aad);
    final o = await openApart(key, s, aad: aad);
    return '${s.length} ${o.length}';
  });
  await step('pack small', () async => (await unpackMessage(await packMessage(Uint8List.fromList(utf8.encode('x' * 3000))))).length);
  await step('pack big', () async => (await unpackMessage(await packMessage(Uint8List.fromList(utf8.encode('{"a":"${'xyz' * 200000}"}'))))).length);
  await step('zip with big pdf', () async {
    final z = zipNoteFile([('manifest.json', Uint8List.fromList(utf8.encode('{"note":{"createdAt":1}}')), true), ('doc.pdf', bytes(600 * 1024), false)]);
    return '${z.length} digest ${noteContentDigest(z)}';
  });
  for (final mb in [3, 12]) {
    await step('pdf note of $mb MB: zip, digest, seal, open', () async {
      final z = zipNoteFile([('manifest.json', Uint8List.fromList(utf8.encode('{"note":{"createdAt":1}}')), true), ('source.pdf', bytes(mb * 1024 * 1024), false)]);
      final d = noteContentDigest(z);
      final sealed = await sealApart(key, z, aad: aad);
      final back = await openApart(key, sealed, aad: aad);
      return '${z.length} $d ${back.length == z.length}';
    });
  }
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(minutes: 2), sendTimeout: const Duration(minutes: 5), validateStatus: (s) => s != null && s < 500));
  await step('dio put stream', () async {
    final data = bytes(2000);
    final r = await dio.put<void>('/files/a.bin', data: Stream.fromIterable([data]), options: Options(headers: {'Authorization': 'Basic eDp5', 'Content-Type': 'application/octet-stream', 'Content-Length': '${data.length}'}));
    return r.statusCode;
  });
  await step('dio get bytes', () async {
    final r = await dio.get<List<int>>('/files/a.bin', options: Options(responseType: ResponseType.bytes));
    return '${r.statusCode} ${Uint8List.fromList(r.data!).length}';
  });
  await step('dio get 404', () async => (await dio.get<List<int>>('/files/none', options: Options(responseType: ResponseType.bytes))).statusCode);
  await step('dio propfind', () async {
    final r = await dio.request<String>('/files/', options: Options(method: 'PROPFIND', headers: {'Depth': '1'}, responseType: ResponseType.plain), data: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"/>');
    return '${r.statusCode} ${r.data?.length}';
  });
  await step('dio mkcol', () async => (await dio.request<void>('/files/dir', options: Options(method: 'MKCOL'))).statusCode);
  await step('dio delete', () async => (await dio.delete<void>('/files/a.bin')).statusCode);
  log.add('OK');
  await globalContext.callMethod<JSPromise<JSObject>>('fetch'.toJS, 'result'.toJS, {'method': 'POST', 'body': log.join('\n')}.jsify()).toDart;
}
