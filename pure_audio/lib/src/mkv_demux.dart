import 'dart:typed_data';

import 'bits.dart';
import 'byte_source.dart';

/// The audio track of a Matroska / WebM file.
class MkvAudio {
  final String codecId; // 'A_AAC', 'A_OPUS', 'A_VORBIS', 'A_MPEG/L3', ...
  final Uint8List? config; // CodecPrivate
  final int sampleRate, channels;
  final int trackNumber;
  final double? seconds;
  final int _firstCluster, _segmentEnd;
  final ByteSource _source;

  MkvAudio._(this._source, this.codecId, this.config, this.sampleRate, this.channels, this.trackNumber, this.seconds, this._firstCluster, this._segmentEnd);

  /// The frames of the track (access units), in order.
  Stream<Uint8List> frames() async* {
    var pos = _firstCluster;
    while (pos + 2 < _segmentEnd) {
      final h = await _header(_source, pos);
      if (h == null) return;
      if (h.id == _cluster) {
        final end = h.size < 0 ? _segmentEnd : h.bodyStart + h.size;
        yield* _clusterFrames(h.bodyStart, end, h.size < 0);
        if (h.size < 0) return; // (an unknown-size cluster is read to the end, with the clusters after it)
      }
      if (h.size < 0) return;
      pos = h.bodyStart + h.size;
    }
  }

  Stream<Uint8List> _clusterFrames(int from, int end, bool unknownSize) async* {
    var pos = from;
    while (pos + 2 < end) {
      final h = await _header(_source, pos);
      if (h == null) return;
      if (unknownSize && (h.id == _cluster || h.id == 0x1C53BB6B || h.id == 0x1254C367 || h.id == 0x1043A770)) {
        if (h.id == _cluster) {
          // the next cluster of an unknown size one: carry on reading in it
          pos = h.bodyStart;
          continue;
        }
        return;
      }
      if (h.size < 0) return;
      final next = h.bodyStart + h.size;
      if (h.id == 0xA3 || h.id == 0xA1) {
        yield* _block(await _source.read(h.bodyStart, h.size));
      } else if (h.id == 0xA0) {
        // block group: look for the block inside
        var p = h.bodyStart;
        while (p + 2 < next) {
          final c = await _header(_source, p);
          if (c == null || c.size < 0) break;
          if (c.id == 0xA1) yield* _block(await _source.read(c.bodyStart, c.size));
          p = c.bodyStart + c.size;
        }
      }
      pos = next;
    }
  }

  Stream<Uint8List> _block(Uint8List b) async* {
    if (b.length < 4) return;
    final (track, used) = _vint(b, 0, keepMarker: false);
    if (track != trackNumber || used + 3 > b.length) return;
    final flags = b[used + 2];
    var p = used + 3;
    final lacing = (flags >> 1) & 3;
    if (lacing == 0) {
      yield Uint8List.sublistView(b, p);
      return;
    }
    final count = b[p++] + 1;
    final sizes = <int>[];
    if (lacing == 1) {
      for (var i = 0; i < count - 1; i++) {
        var n = 0;
        while (p < b.length && b[p] == 255) {
          n += 255;
          p++;
        }
        n += b[p++];
        sizes.add(n);
      }
    } else if (lacing == 3) {
      final (first, u) = _vint(b, p, keepMarker: false);
      p += u;
      sizes.add(first);
      for (var i = 1; i < count - 1; i++) {
        final (raw, u2) = _vint(b, p, keepMarker: false);
        p += u2;
        final bias = (1 << (7 * u2 - 1)) - 1;
        sizes.add(sizes.last + raw - bias);
      }
    } else {
      final each = (b.length - p) ~/ count;
      for (var i = 0; i < count - 1; i++) {
        sizes.add(each);
      }
    }
    var used2 = 0;
    for (final s in sizes) {
      used2 += s;
    }
    sizes.add(b.length - p - used2);
    for (final s in sizes) {
      if (s < 0 || p + s > b.length) return;
      yield Uint8List.sublistView(b, p, p + s);
      p += s;
    }
  }
}

const _segment = 0x18538067, _cluster = 0x1F43B675, _tracks = 0x1654AE6B, _info = 0x1549A966;

class _Header {
  final int id, size, bodyStart; // size -1: unknown
  _Header(this.id, this.size, this.bodyStart);
}

(int, int) _vint(Uint8List b, int at, {required bool keepMarker}) {
  if (at >= b.length) throw const AudioFormatException('This Matroska file is cut short.');
  final first = b[at];
  var len = 1;
  var mask = 0x80;
  while (len <= 8 && (first & mask) == 0) {
    len++;
    mask >>= 1;
  }
  if (len > 8 || at + len > b.length) throw const AudioFormatException('This Matroska file has a bad number in it.');
  var v = keepMarker ? first : first & (mask - 1);
  var allOnes = (first & (mask - 1)) == mask - 1;
  for (var i = 1; i < len; i++) {
    v = (v << 8) | b[at + i];
    if (b[at + i] != 0xFF) allOnes = false;
  }
  if (!keepMarker && allOnes) return (-1, len);
  return (v, len);
}

Future<_Header?> _header(ByteSource source, int pos) async {
  final b = await source.read(pos, 12);
  if (b.length < 2) return null;
  try {
    final (id, idLen) = _vint(b, 0, keepMarker: true);
    final (size, sizeLen) = _vint(b, idLen, keepMarker: false);
    return _Header(id, size, pos + idLen + sizeLen);
  } on AudioFormatException {
    return null;
  }
}

/// Finds the first audio track of a Matroska / WebM file. Throws an [AudioFormatException] when there is none.
Future<MkvAudio> openMkv(ByteSource source) async {
  var pos = 0;
  var h = await _header(source, pos);
  if (h == null || h.id != 0x1A45DFA3) throw const AudioFormatException('This is not a Matroska or WebM file.');
  pos = h.bodyStart + h.size; // past the EBML header
  h = await _header(source, pos);
  if (h == null || h.id != _segment) throw const AudioFormatException('This Matroska file has no segment.');
  final segmentEnd = h.size < 0 ? source.length : h.bodyStart + h.size;
  pos = h.bodyStart;
  double? seconds;
  var scale = 1000000;
  MkvAudio? audio;
  int? firstCluster;
  while (pos + 2 < segmentEnd) {
    final c = await _header(source, pos);
    if (c == null) break;
    if (c.id == _cluster) {
      firstCluster = pos;
      break;
    }
    if (c.size < 0) break;
    if (c.id == _info) {
      final body = await source.read(c.bodyStart, c.size);
      double? duration;
      _children(body, 0, body.length, (id, from, to) {
        if (id == 0x2AD7B1) scale = _uint(body, from, to);
        if (id == 0x4489) duration = _float(body, from, to);
      });
      if (duration != null) seconds = duration! * scale / 1e9;
    } else if (c.id == _tracks) {
      final body = await source.read(c.bodyStart, c.size);
      _children(body, 0, body.length, (id, from, to) {
        if (id != 0xAE || audio != null) return;
        int number = 0, type = 0, channels = 1;
        var codec = '';
        var rate = 8000.0;
        Uint8List? priv;
        _children(body, from, to, (id, f, t) {
          switch (id) {
            case 0xD7:
              number = _uint(body, f, t);
            case 0x83:
              type = _uint(body, f, t);
            case 0x86:
              codec = String.fromCharCodes(body.sublist(f, t));
            case 0x63A2:
              priv = Uint8List.fromList(body.sublist(f, t));
            case 0xE1:
              _children(body, f, t, (id, f2, t2) {
                if (id == 0xB5) rate = _float(body, f2, t2);
                if (id == 0x9F) channels = _uint(body, f2, t2);
              });
          }
        });
        if (type == 2) audio = MkvAudio._(source, codec, priv, rate.round(), channels, number, seconds, 0, segmentEnd);
      });
    }
    pos = c.bodyStart + c.size;
  }
  final found = audio;
  if (found == null) throw const AudioFormatException('This file has no audio track.');
  if (firstCluster == null) throw const AudioFormatException('This Matroska file has no sound in it.');
  return MkvAudio._(source, found.codecId, found.config, found.sampleRate, found.channels, found.trackNumber, seconds, firstCluster, segmentEnd);
}

void _children(Uint8List b, int from, int to, void Function(int id, int bodyFrom, int bodyTo) visit) {
  var p = from;
  while (p + 2 <= to) {
    try {
      final (id, il) = _vint(b, p, keepMarker: true);
      final (size, sl) = _vint(b, p + il, keepMarker: false);
      final start = p + il + sl;
      final end = size < 0 ? to : start + size;
      if (end > to) return;
      visit(id, start, end);
      p = end;
    } on AudioFormatException {
      return;
    }
  }
}

int _uint(Uint8List b, int from, int to) {
  var v = 0;
  for (var i = from; i < to; i++) {
    v = (v << 8) | b[i];
  }
  return v;
}

double _float(Uint8List b, int from, int to) {
  final d = ByteData.sublistView(b, from, to);
  return to - from == 4 ? d.getFloat32(0) : d.getFloat64(0);
}
