import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show compute;

import 'inflate_io.dart' if (dart.library.js_interop) 'inflate_web.dart';

/// Messages between devices are compressed before they are sealed (sealed data cannot be compressed any more). A packed message
/// starts with one byte that says how the rest is: [_plain] or [_zlib]. A message that starts with `{` or `[` is one of an older
/// app, which sent plain JSON; it is read as it is.
///
/// Only devices that know each other's key can send a message that opens, so what is unpacked comes from a member, not from the
/// network or the server.
const int _plain = 0x00, _zlib = 0x01;

/// The most a message may unpack to. A member can send a few kilobytes that inflate to gigabytes, so the unpacking stops here.
const int maxUnpackedMessage = 256 * 1024 * 1024;

/// Below this many bytes compressing saves nothing worth the time.
const int _worthIt = 128;

/// From this many bytes on the work is done apart from the screen.
const int _apart = 256 * 1024;

/// [plain] packed: compressed when that makes it smaller, as it is otherwise.
Future<Uint8List> packMessage(Uint8List plain) => plain.length >= _apart ? compute(packMessageSync, plain) : Future.value(packMessageSync(plain));

Uint8List packMessageSync(Uint8List plain) {
  if (plain.length >= _worthIt) {
    final packed = ZLibEncoder().encodeBytes(plain, level: 6);
    if (packed.length + 1 < plain.length) return _tagged(_zlib, packed);
  }
  return _tagged(_plain, plain);
}

/// What [packMessage] packed, or an older app's plain message. Throws a [FormatException] for anything else.
Future<Uint8List> unpackMessage(Uint8List data) => data.length >= _apart ? compute(unpackMessageSync, data) : Future.value(unpackMessageSync(data));

Uint8List unpackMessageSync(Uint8List data, {int limit = maxUnpackedMessage}) {
  if (data.isEmpty) return data;
  final first = data[0];
  if (first == 0x7B || first == 0x5B) return data; // '{' or '[': plain JSON of an older app
  final rest = Uint8List.sublistView(data, 1);
  if (first == _plain) return rest;
  if (first == _zlib) return _inflate(rest, limit);
  throw const FormatException('not a packed message');
}

Uint8List _tagged(int tag, List<int> body) {
  final out = Uint8List(body.length + 1);
  out[0] = tag;
  out.setRange(1, out.length, body);
  return out;
}

/// [packed] inflated, giving up with a [FormatException] as soon as more than [limit] bytes have come out (they are counted as
/// they are produced, so the memory is never taken).
Uint8List _inflate(Uint8List packed, int limit) => inflateCapped(packed, limit);
