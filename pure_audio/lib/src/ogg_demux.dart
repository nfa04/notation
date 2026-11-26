import 'dart:typed_data';

import 'bits.dart';
import 'byte_source.dart';

/// The packets of the first logical stream of an Ogg file (RFC 3533), in order.
class OggStream {
  final ByteSource _source;

  /// The first packet: it says what the stream is ("OpusHead", "\x01vorbis", ...).
  final Uint8List firstPacket;
  final int serial;

  /// The position (in samples) of the last page, or -1 when it was not found.
  final int lastGranule;
  OggStream._(this._source, this.firstPacket, this.serial, this.lastGranule);

  static Future<OggStream> open(ByteSource source) async {
    final packets = _packets(source, null);
    Uint8List? first;
    int? serial;
    await for (final p in packets.map((e) => e)) {
      first = p.$1;
      serial = p.$2;
      break;
    }
    if (first == null || serial == null) throw const AudioFormatException('This Ogg file has no data in it.');
    var last = -1;
    final tailAt = source.length > 70000 ? source.length - 70000 : 0;
    final tail = await source.read(tailAt, source.length - tailAt);
    for (var i = tail.length - 27; i >= 0; i--) {
      if (tail[i] == 0x4F && tail[i + 1] == 0x67 && tail[i + 2] == 0x67 && tail[i + 3] == 0x53) {
        final s = ByteData.sublistView(tail).getUint32(i + 14, Endian.little);
        if (s != serial) continue;
        final g = ByteData.sublistView(tail).getUint64(i + 6, Endian.little);
        if (g != 0xFFFFFFFFFFFFFFFF) {
          last = g;
          break;
        }
      }
    }
    return OggStream._(source, first, serial, last);
  }

  /// All packets, the first one included.
  Stream<Uint8List> packets() => _packets(_source, serial).map((e) => e.$1);

  static Stream<(Uint8List, int)> _packets(ByteSource source, int? only) async* {
    var at = 0;
    var partial = BytesBuilder(copy: false);
    var hasPartial = false;
    int? wanted = only;
    while (at + 27 <= source.length) {
      final head = await source.read(at, 27);
      if (head.length < 27 || head[0] != 0x4F || head[1] != 0x67 || head[2] != 0x67 || head[3] != 0x53) {
        at++; // not at a page: look for the next one
        continue;
      }
      final bd = ByteData.sublistView(head);
      final serial = bd.getUint32(14, Endian.little);
      final count = head[26];
      final table = await source.read(at + 27, count);
      if (table.length < count) break;
      var total = 0;
      for (final t in table) {
        total += t;
      }
      final body = await source.read(at + 27 + count, total);
      if (body.length < total) break;
      at += 27 + count + total;
      wanted ??= serial;
      if (serial != wanted) continue;
      final continued = (head[5] & 1) != 0;
      if (!continued && hasPartial) {
        partial = BytesBuilder(copy: false);
        hasPartial = false;
      }
      var pos = 0;
      for (final t in table) {
        partial.add(Uint8List.sublistView(body, pos, pos + t));
        hasPartial = true;
        pos += t;
        if (t < 255) {
          yield (partial.takeBytes(), serial);
          partial = BytesBuilder(copy: false);
          hasPartial = false;
        }
      }
    }
  }
}
