import 'dart:convert';
import 'dart:typed_data';

import 'bits.dart';
import 'byte_source.dart';

/// The audio track of an MP4 / M4A / MOV file: what it holds and where each of its samples (access units) is in the file.
class Mp4Audio {
  /// 'aac', 'mp3', 'opus', 'alac', 'ac3' ... (as far as the file says), or the four letters of the sample entry.
  final String codec;
  final Uint8List? config; // AAC: the AudioSpecificConfig; Opus: the dOps box
  final int sampleRate, channels;
  final Int64List offsets;
  final Int32List sizes;

  /// The time scale and the duration of the track, in that scale.
  final int timeScale, duration;

  Mp4Audio({required this.codec, required this.config, required this.sampleRate, required this.channels, required this.offsets, required this.sizes, required this.timeScale, required this.duration});

  int get count => sizes.length;
  double get seconds => timeScale == 0 ? 0 : duration / timeScale;
}

class _Box {
  final String type;
  final int start, end, bodyStart; // in the buffer it was found in
  _Box(this.type, this.start, this.end, this.bodyStart);
}

Iterable<_Box> _boxes(Uint8List b, int from, int to) sync* {
  var pos = from;
  final d = ByteData.sublistView(b);
  while (pos + 8 <= to) {
    var size = d.getUint32(pos);
    final type = String.fromCharCodes(b, pos + 4, pos + 8);
    var header = 8;
    if (size == 1) {
      if (pos + 16 > to) return;
      size = d.getUint64(pos + 8);
      header = 16;
    } else if (size == 0) {
      size = to - pos;
    }
    if (size < header || pos + size > to) return;
    yield _Box(type, pos, pos + size, pos + header);
    pos += size;
  }
}

/// Finds the audio track of the MP4 file in [source] and its sample table. Throws an [AudioFormatException] with a plain sentence
/// when there is no audio or the file is built in a way that is not supported.
Future<Mp4Audio> readMp4Audio(ByteSource source) async {
  // top level boxes: look for moov without reading the media data
  var pos = 0;
  Uint8List? moov;
  var sawFragment = false;
  while (pos + 8 <= source.length) {
    final head = await source.read(pos, 16);
    if (head.length < 8) break;
    final d = ByteData.sublistView(head);
    var size = d.getUint32(0);
    final type = latin1.decode(head.sublist(4, 8), allowInvalid: true);
    var header = 8;
    if (size == 1) {
      if (head.length < 16) break;
      size = d.getUint64(8);
      header = 16;
    } else if (size == 0) {
      size = source.length - pos;
    }
    if (size < header) break;
    if (type == 'moov') {
      moov = await source.read(pos + header, size - header);
      break;
    }
    if (type == 'moof') sawFragment = true;
    pos += size;
  }
  if (moov == null) {
    throw AudioFormatException(sawFragment ? 'This MP4 file is built in fragments, which are not supported yet.' : 'This does not look like an MP4 file (no "moov" box).');
  }
  for (final trak in _boxes(moov, 0, moov.length).where((b) => b.type == 'trak')) {
    final audio = _readTrack(moov, trak);
    if (audio != null) return audio;
  }
  throw const AudioFormatException('This file has no audio track.');
}

_Box? _find(Uint8List b, _Box parent, String type) {
  for (final c in _boxes(b, parent.bodyStart, parent.end)) {
    if (c.type == type) return c;
  }
  return null;
}

Mp4Audio? _readTrack(Uint8List b, _Box trak) {
  final mdia = _find(b, trak, 'mdia');
  if (mdia == null) return null;
  final hdlr = _find(b, mdia, 'hdlr');
  if (hdlr == null || hdlr.end - hdlr.bodyStart < 12) return null;
  final handler = latin1.decode(b.sublist(hdlr.bodyStart + 8, hdlr.bodyStart + 12), allowInvalid: true);
  if (handler != 'soun') return null;
  final d = ByteData.sublistView(b);
  var timeScale = 0, duration = 0;
  final mdhd = _find(b, mdia, 'mdhd');
  if (mdhd != null) {
    final v = b[mdhd.bodyStart];
    if (v == 1) {
      timeScale = d.getUint32(mdhd.bodyStart + 20);
      duration = d.getUint64(mdhd.bodyStart + 24);
    } else {
      timeScale = d.getUint32(mdhd.bodyStart + 12);
      duration = d.getUint32(mdhd.bodyStart + 16);
    }
  }
  final minf = _find(b, mdia, 'minf');
  final stbl = minf == null ? null : _find(b, minf, 'stbl');
  if (stbl == null) return null;
  final stsd = _find(b, stbl, 'stsd');
  final stsz = _find(b, stbl, 'stsz');
  final stsc = _find(b, stbl, 'stsc');
  final stco = _find(b, stbl, 'stco');
  final co64 = _find(b, stbl, 'co64');
  if (stsd == null || stsz == null || stsc == null || (stco == null && co64 == null)) return null;

  // the sample entry
  var codec = '', sampleRate = 0, channels = 0;
  Uint8List? config;
  final entries = _boxes(b, stsd.bodyStart + 8, stsd.end).toList();
  if (entries.isEmpty) return null;
  final entry = entries.first;
  codec = entry.type;
  final e = entry.bodyStart;
  if (entry.end - e >= 28) {
    final version = d.getUint16(e + 8);
    channels = d.getUint16(e + 16);
    sampleRate = d.getUint16(e + 24);
    var inner = e + 28;
    if (version == 1) {
      inner += 16;
    } else if (version == 2) {
      channels = d.getUint32(e + 48);
      sampleRate = d.getFloat64(e + 32).round();
      inner = e + 28 + 36;
    }
    for (final c in _boxes(b, inner, entry.end)) {
      if (c.type == 'esds') {
        final es = _esds(b, c.bodyStart + 4, c.end);
        if (es != null) {
          config = es.$1;
          codec = switch (es.$2) {
            0x40 || 0x66 || 0x67 || 0x68 => 'aac',
            0x69 || 0x6B => 'mp3',
            0xDD => 'vorbis',
            _ => 'mp4a',
          };
        }
      } else if (c.type == 'dOps') {
        config = Uint8List.sublistView(b, c.bodyStart, c.end);
      } else if (c.type == 'wave') {
        for (final w in _boxes(b, c.bodyStart, c.end)) {
          if (w.type == 'esds') {
            final es = _esds(b, w.bodyStart + 4, w.end);
            if (es != null) {
              config = es.$1;
              codec = es.$2 == 0x6B || es.$2 == 0x69 ? 'mp3' : 'aac';
            }
          }
        }
      }
    }
    if (codec == 'mp4a') codec = config == null ? 'mp4a' : 'aac';
    if (codec == '.mp3' || codec == 'mp3 ') codec = 'mp3';
    if (codec == 'Opus') codec = 'opus';
    if (codec == 'fLaC') codec = 'flac';
  }

  // the sample table
  final count = d.getUint32(stsz.bodyStart + 8);
  final fixed = d.getUint32(stsz.bodyStart + 4);
  final sizes = Int32List(count);
  for (var i = 0; i < count; i++) {
    sizes[i] = fixed != 0 ? fixed : d.getUint32(stsz.bodyStart + 12 + 4 * i);
  }
  final chunkCount = d.getUint32((stco ?? co64!).bodyStart + 4);
  final chunkOffsets = Int64List(chunkCount);
  for (var i = 0; i < chunkCount; i++) {
    chunkOffsets[i] = stco != null ? d.getUint32(stco.bodyStart + 8 + 4 * i) : d.getUint64(co64!.bodyStart + 8 + 8 * i);
  }
  final runs = d.getUint32(stsc.bodyStart + 4);
  final firstChunk = <int>[], perChunk = <int>[];
  for (var i = 0; i < runs; i++) {
    firstChunk.add(d.getUint32(stsc.bodyStart + 8 + 12 * i));
    perChunk.add(d.getUint32(stsc.bodyStart + 12 + 12 * i));
  }
  final offsets = Int64List(count);
  var sample = 0;
  for (var run = 0; run < runs && sample < count; run++) {
    final from = firstChunk[run] - 1;
    final to = run + 1 < runs ? firstChunk[run + 1] - 1 : chunkCount;
    for (var c = from; c < to && c < chunkCount && sample < count; c++) {
      var at = chunkOffsets[c];
      for (var k = 0; k < perChunk[run] && sample < count; k++) {
        offsets[sample] = at;
        at += sizes[sample];
        sample++;
      }
    }
  }
  if (sample < count) throw const AudioFormatException('The sample table of this MP4 file is broken.');
  return Mp4Audio(codec: codec, config: config, sampleRate: sampleRate, channels: channels, offsets: offsets, sizes: sizes, timeScale: timeScale, duration: duration);
}

/// The decoder-specific bytes and the object type of an 'esds' box body (after its version and flags).
(Uint8List, int)? _esds(Uint8List b, int from, int to) {
  var p = from;
  int length() {
    var n = 0;
    for (var i = 0; i < 4 && p < to; i++) {
      final v = b[p++];
      n = (n << 7) | (v & 0x7F);
      if (v & 0x80 == 0) break;
    }
    return n;
  }

  int? objectType;
  while (p < to) {
    final tag = b[p++];
    final len = length();
    if (tag == 0x03) {
      p += 2; // ES id
      final flags = b[p++];
      if (flags & 0x80 != 0) p += 2;
      if (flags & 0x40 != 0) p += 1 + b[p];
      if (flags & 0x20 != 0) p += 2;
    } else if (tag == 0x04) {
      objectType = b[p];
      p += 13;
    } else if (tag == 0x05) {
      return (Uint8List.fromList(b.sublist(p, (p + len).clamp(p, to))), objectType ?? 0);
    } else {
      p += len;
    }
  }
  return null;
}

/// The access units of [audio], read from [source] one after the other (consecutive ones in one read).
Stream<Uint8List> mp4Samples(ByteSource source, Mp4Audio audio) async* {
  var i = 0;
  const maxRead = 512 * 1024;
  while (i < audio.count) {
    var j = i;
    var end = audio.offsets[i] + audio.sizes[i];
    while (j + 1 < audio.count && audio.offsets[j + 1] == end && end - audio.offsets[i] + audio.sizes[j + 1] <= maxRead) {
      j++;
      end += audio.sizes[j];
    }
    final block = await source.read(audio.offsets[i], end - audio.offsets[i]);
    if (block.length < end - audio.offsets[i]) throw const AudioFormatException('The file ends before its audio does.');
    var at = 0;
    for (var k = i; k <= j; k++) {
      yield Uint8List.sublistView(block, at, at + audio.sizes[k]);
      at += audio.sizes[k];
    }
    i = j + 1;
  }
}
