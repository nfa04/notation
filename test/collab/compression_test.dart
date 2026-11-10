import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/compression.dart';
import 'package:notes/collab/inflate_web.dart' as web;

void main() {
  Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));

  test('a message of strokes comes out much smaller, and back the same', () async {
    final rnd = Random(1);
    final ops = jsonEncode({
      't': 'ops',
      'ops': [
        for (var i = 0; i < 200; i++)
          {'kind': 'stroke', 'id': 's$i', 'data': {'points': [for (var p = 0; p < 50; p++) [(rnd.nextDouble() * 800).toStringAsFixed(1), (rnd.nextDouble() * 1100).toStringAsFixed(1), 0.5]], 'color': 4278190080, 'width': 2.0}},
      ],
    });
    final plain = bytesOf(ops);
    final packed = await packMessage(plain);
    expect(packed.length, lessThan(plain.length * 0.6));
    expect(await unpackMessage(packed), plain);
  });

  test('what does not get smaller (already compressed data) is sent as it is, with one byte more', () async {
    final rnd = Random(2);
    final noise = Uint8List.fromList([for (var i = 0; i < 5000; i++) rnd.nextInt(256)]);
    final packed = await packMessage(noise);
    expect(packed.length, noise.length + 1);
    expect(await unpackMessage(packed), noise);
  });

  test('a short message is not compressed', () async {
    final plain = bytesOf('{"t":"at","page":3}');
    final packed = await packMessage(plain);
    expect(packed.length, plain.length + 1);
    expect(await unpackMessage(packed), plain);
  });

  test('the plain JSON of an older app is read as it is; anything else is refused', () async {
    expect(await unpackMessage(bytesOf('{"t":"hi"}')), bytesOf('{"t":"hi"}'));
    expect(await unpackMessage(bytesOf('[1,2]')), bytesOf('[1,2]'));
    expect(() => unpackMessage(Uint8List.fromList([9, 1, 2])), throwsFormatException);
  });

  test('a big message (done apart from the screen) comes back the same', () async {
    final plain = bytesOf(jsonEncode({'bytes': base64.encode(List.filled(400 * 1024, 7))}));
    final packed = await packMessage(plain);
    expect(packed.length, lessThan(plain.length ~/ 10));
    expect(await unpackMessage(packed), plain);
  });

  group('the inflate of the web (pure Dart, as dart:io has no zlib there)', () {
    test('reads what the native side packs', () {
      final plain = bytesOf(jsonEncode({'t': 'pair', 'devices': [for (var i = 0; i < 50; i++) {'id': 'd$i', 'name': 'Device $i'}]}));
      final packed = packMessageSync(plain);
      expect(packed[0], 0x01, reason: 'compressed');
      expect(web.inflateCapped(Uint8List.sublistView(packed, 1), 1 << 20), plain);
    });

    test('stops at the limit, and refuses what is not zlib', () {
      final packed = packMessageSync(Uint8List(1 << 20)); // a megabyte of zeros packs to a few kilobytes
      expect(() => web.inflateCapped(Uint8List.sublistView(packed, 1), 1000), throwsFormatException);
      expect(() => web.inflateCapped(bytesOf('not zlib at all'), 1000), throwsFormatException);
    });
  });
}
