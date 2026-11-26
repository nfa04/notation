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

  /// The track number (fragments refer to it).
  final int trackId;

  Mp4Audio({this.trackId = 0, required this.codec, required this.config, required this.sampleRate, required this.channels, required this.offsets, required this.sizes, required this.timeScale, required this.duration});

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
  final fragments = <(int, int)>[]; // (start, size) of each moof
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
    if (type == 'moov') moov = await source.read(pos + header, size - header);
    if (type == 'moof') fragments.add((pos, size));
    pos += size;
  }
  if (moov == null) throw const AudioFormatException('This does not look like an MP4 file (no "moov" box).');
  for (final trak in _boxes(moov, 0, moov.length).where((b) => b.type == 'trak')) {
    final audio = _readTrack(moov, trak);
    if (audio == null) continue;
    if (fragments.isEmpty) return audio;
    return _withFragments(source, moov, audio, fragments);
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
  var trackId = 0;
  final tkhd = _find(b, trak, 'tkhd');
  if (tkhd != null) trackId = ByteData.sublistView(b).getUint32(tkhd.bodyStart + (b[tkhd.bodyStart] == 1 ? 20 : 12));
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
  return Mp4Audio(trackId: trackId, codec: codec, config: config, sampleRate: sampleRate, channels: channels, offsets: offsets, sizes: sizes, timeScale: timeScale, duration: duration);
}

/// A file built in fragments: the samples are in the `trun` boxes of the `moof` boxes ([fragments]), not in the sample table.
Future<Mp4Audio> _withFragments(ByteSource source, Uint8List moov, Mp4Audio base, List<(int, int)> fragments) async {
  var defaultSize = 0, defaultDuration = 0;
  for (final mvex in _boxes(moov, 0, moov.length).where((b) => b.type == 'mvex')) {
    for (final trex in _boxes(moov, mvex.bodyStart, mvex.end).where((b) => b.type == 'trex')) {
      final d = ByteData.sublistView(moov);
      if (d.getUint32(trex.bodyStart + 4) == base.trackId) {
        defaultDuration = d.getUint32(trex.bodyStart + 12);
        defaultSize = d.getUint32(trex.bodyStart + 16);
      }
    }
  }
  final offsets = base.offsets.toList(), sizes = base.sizes.toList();
  var total = base.duration;
  for (final (start, size) in fragments) {
    final b = await source.read(start, size);
    if (b.length < size) break;
    final d = ByteData.sublistView(b);
    for (final traf in _boxes(b, 8, b.length).where((x) => x.type == 'traf')) {
      final tfhd = _find(b, traf, 'tfhd');
      if (tfhd == null || d.getUint32(tfhd.bodyStart + 4) != base.trackId) continue;
      final tf = d.getUint32(tfhd.bodyStart) & 0xFFFFFF;
      var p = tfhd.bodyStart + 8;
      var baseOffset = start; // (default-base-is-moof, and what nearly every writer means)
      if (tf & 1 != 0) {
        baseOffset = d.getUint64(p);
        p += 8;
      }
      if (tf & 2 != 0) p += 4;
      var dur = defaultDuration, sz = defaultSize;
      if (tf & 8 != 0) {
        dur = d.getUint32(p);
        p += 4;
      }
      if (tf & 0x10 != 0) sz = d.getUint32(p);
      var next = -1; // where the data of a run goes on after the previous one
      for (final trun in _boxes(b, traf.bodyStart, traf.end).where((x) => x.type == 'trun')) {
        final fl = d.getUint32(trun.bodyStart) & 0xFFFFFF;
        final n = d.getUint32(trun.bodyStart + 4);
        var q = trun.bodyStart + 8;
        var at = next;
        if (fl & 1 != 0) {
          at = baseOffset + d.getInt32(q);
          q += 4;
        }
        if (at < 0) at = baseOffset;
        if (fl & 4 != 0) q += 4;
        for (var i = 0; i < n; i++) {
          var sDur = dur, sSize = sz;
          if (fl & 0x100 != 0) {
            sDur = d.getUint32(q);
            q += 4;
          }
          if (fl & 0x200 != 0) {
            sSize = d.getUint32(q);
            q += 4;
          }
          if (fl & 0x400 != 0) q += 4;
          if (fl & 0x800 != 0) q += 4;
          offsets.add(at);
          sizes.add(sSize);
          at += sSize;
          total += sDur;
        }
        next = at;
      }
    }
  }
  return Mp4Audio(
      trackId: base.trackId, codec: base.codec, config: base.config, sampleRate: base.sampleRate, channels: base.channels, offsets: Int64List.fromList(offsets), sizes: Int32List.fromList(sizes), timeScale: base.timeScale, duration: total);
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
