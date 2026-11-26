import 'bits.dart';
import 'byte_source.dart';
import 'flac.dart';
import 'mkv_demux.dart';
import 'mp3_decoder.dart';
import 'mp4_demux.dart';
import 'pcm.dart';
import 'wav_source.dart';
import 'aac_decoder.dart';
import 'ogg_demux.dart';
import 'vorbis/vorbis_decoder.dart';
import 'opus/opus_decoder.dart';

import 'dart:math' as math;

import 'dart:typed_data';

/// The decoded sound of an audio or video file in [source], found out from the first bytes. Throws an [AudioFormatException] with a
/// plain sentence when the kind of file or the way it was made (codec) cannot be read.
Future<PcmSource> openAudio(ByteSource source) async {
  switch (await sniffAudio(source)) {
    case 'wav':
      return WavSource.open(source);
    case 'flac':
      return FlacSource.open(source);
    case 'mp3':
      return Mp3Source.open(source);
    case 'mp4':
      return _openMp4(source);
    case 'matroska':
      return _openMkv(source);
    case 'adts':
      return _openAdts(source);
    case 'ogg':
      return _openOgg(source);
    case final other:
      throw AudioFormatException('Files of the kind "$other" cannot be read yet.');
  }
}

Future<PcmSource> _openMp4(ByteSource source) async {
  final audio = await readMp4Audio(source);
  switch (audio.codec) {
    case 'aac':
      return _AacMp4(source, audio);
    case 'mp3':
      return _Mp3Mp4(source, audio);
    case 'opus':
      final d = audio.config;
      if (d == null || d.length < 11) throw const AudioFormatException('The Opus audio of this file has no settings.');
      // (the `dOps` box holds what an OpusHead does, with big endian numbers)
      final head = Uint8List(19)
        ..setAll(0, 'OpusHead'.codeUnits)
        ..[8] = 1
        ..[9] = d[1]
        ..[10] = d[3]
        ..[11] = d[2]
        ..[16] = d[9]
        ..[17] = d[8]
        ..[18] = d[10];
      return _opusPcm(head, mp4Samples(source, audio), audio.seconds == 0 ? null : audio.seconds);
    case final other:
      throw AudioFormatException('The audio of this file is "$other", which cannot be read yet.');
  }
}

class _AacMp4 implements PcmSource {
  final ByteSource _source;
  final Mp4Audio _audio;
  final AacDecoder _decoder;
  _AacMp4(this._source, this._audio) : _decoder = AacDecoder.fromConfig(_audio.config!);

  @override
  String get codec => 'aac';
  @override
  int get sampleRate => _decoder.sampleRate;
  @override
  int get channels => _decoder.channels;
  @override
  double? get seconds => _audio.seconds == 0 ? null : _audio.seconds;

  @override
  Stream<List<Float64List>> blocks() async* {
    // (about a second at a time)
    final per = (sampleRate / 1024).ceil();
    var pending = <List<Float64List>>[];
    await for (final frame in mp4Samples(_source, _audio)) {
      pending.add(_decoder.decode(frame));
      if (pending.length >= per) {
        yield _join(pending);
        pending = [];
      }
    }
    if (pending.isNotEmpty) yield _join(pending);
  }

  List<Float64List> _join(List<List<Float64List>> frames) {
    final out = <Float64List>[];
    for (var c = 0; c < channels; c++) {
      final one = Float64List(frames.length * 1024);
      for (var i = 0; i < frames.length; i++) {
        one.setAll(i * 1024, frames[i][c]);
      }
      out.add(one);
    }
    return out;
  }
}

/// MP3 in an MP4 file: every sample is one frame.
class _Mp3Mp4 implements PcmSource {
  final ByteSource _source;
  final Mp4Audio _audio;
  _Mp3Mp4(this._source, this._audio);

  @override
  String get codec => 'mp3';
  @override
  int get sampleRate => _audio.sampleRate;
  @override
  int get channels => _audio.channels;
  @override
  double? get seconds => _audio.seconds == 0 ? null : _audio.seconds;

  @override
  Stream<List<Float64List>> blocks() async* {
    final decoder = Mp3Decoder();
    await for (final frame in mp4Samples(_source, _audio)) {
      final h = Mp3Header.parse(frame, 0);
      if (h == null) continue;
      try {
        yield decoder.decodeFrame(frame, h);
      } on AudioFormatException {
        continue;
      }
    }
  }
}

Future<PcmSource> _openMkv(ByteSource source) async {
  final audio = await openMkv(source);
  switch (audio.codecId) {
    case 'A_AAC':
      final config = audio.config;
      if (config == null) throw const AudioFormatException('The AAC audio of this file has no settings.');
      final decoder = AacDecoder.fromConfig(config);
      return _FramePcm('aac', decoder.sampleRate, decoder.channels, audio.seconds, audio.frames(), (frame) => decoder.decode(frame), 1024);
    case 'A_VORBIS':
      final parts = audio.config == null ? null : VorbisDecoder.splitXiph(audio.config!);
      if (parts == null) throw const AudioFormatException('The Vorbis audio of this file has no settings.');
      final decoder = VorbisDecoder(parts.$1, parts.$2);
      return _FramePcm('vorbis', decoder.sampleRate, decoder.channels, audio.seconds, audio.frames(), decoder.decode, 1024);
    case 'A_OPUS':
      final head = audio.config;
      if (head == null || head.length < 19) throw const AudioFormatException('The Opus audio of this file has no settings.');
      return _opusPcm(head, audio.frames(), audio.seconds);
    case 'A_MPEG/L3':
      final decoder = Mp3Decoder();
      return _FramePcm('mp3', audio.sampleRate, audio.channels, audio.seconds, audio.frames(), (frame) {
        final h = Mp3Header.parse(frame, 0);
        if (h == null) return null;
        return decoder.decodeFrame(frame, h);
      }, 1152);
    case final other:
      throw AudioFormatException('The audio of this file is "$other", which cannot be read yet.');
  }
}

/// A stream of coded frames and a function that decodes one (null: skip it) as a [PcmSource], in blocks of about a second.
class _FramePcm implements PcmSource {
  @override
  final String codec;
  @override
  final int sampleRate, channels;
  @override
  final double? seconds;
  final Stream<Uint8List> _frames;
  final List<Float64List>? Function(Uint8List) _decode;
  final int _frameSamples;
  _FramePcm(this.codec, this.sampleRate, this.channels, this.seconds, this._frames, this._decode, this._frameSamples);

  @override
  Stream<List<Float64List>> blocks() async* {
    var pending = <List<Float64List>>[];
    final per = (sampleRate / _frameSamples).ceil();
    await for (final frame in _frames) {
      List<Float64List>? pcm;
      try {
        pcm = _decode(frame);
      } on AudioFormatException {
        continue;
      }
      if (pcm == null) continue;
      pending.add(pcm);
      if (pending.length >= per) {
        yield _concat(pending);
        pending = [];
      }
    }
    if (pending.isNotEmpty) yield _concat(pending);
  }

  List<Float64List> _concat(List<List<Float64List>> frames) {
    return [
      for (var c = 0; c < channels; c++)
        () {
          var total = 0;
          for (final f in frames) {
            total += f[c < f.length ? c : f.length - 1].length;
          }
          final one = Float64List(total);
          var at = 0;
          for (final f in frames) {
            final part = f[c < f.length ? c : f.length - 1];
            one.setAll(at, part);
            at += part.length;
          }
          return one;
        }()
    ];
  }
}

/// Raw AAC in ADTS frames (a `.aac` file): every frame starts with a header that says how long it is.
Future<PcmSource> _openAdts(ByteSource source) async {
  final first = await source.read(0, 16);
  final decoder = AacDecoder.fromAdts(first);
  Stream<Uint8List> frames() async* {
    var at = 0;
    while (at + 7 <= source.length) {
      final head = await source.read(at, 7);
      if (head.length < 7 || head[0] != 0xFF || (head[1] & 0xF0) != 0xF0) {
        at++; // lost sync: look for the next header
        continue;
      }
      final size = ((head[3] & 3) << 11) | (head[4] << 3) | (head[5] >> 5);
      final header = (head[1] & 1) == 1 ? 7 : 9; // protection bit 1 = no CRC
      if (size < header) {
        at++;
        continue;
      }
      final frame = await source.read(at + header, size - header);
      at += size;
      if (frame.length < size - header) break;
      yield frame;
    }
  }

  return _FramePcm('aac', decoder.sampleRate, decoder.channels, null, frames(), (frame) => decoder.decode(frame), 1024);
}


Future<PcmSource> _openOgg(ByteSource source) async {
  final ogg = await OggStream.open(source);
  final first = ogg.firstPacket;
  if (first.length >= 19 && String.fromCharCodes(first.sublist(0, 8)) == 'OpusHead') {
    final preSkip = first[10] | (first[11] << 8);
    final seconds = ogg.lastGranule < 0 ? null : math.max(0, ogg.lastGranule - preSkip) / 48000;
    // (the first two packets are the head and the tags)
    Stream<Uint8List> packets() async* {
      var n = 0;
      await for (final p in ogg.packets()) {
        if (n++ < 2) continue;
        yield p;
      }
    }

    return _opusPcm(first, packets(), seconds);
  }
  if (first.length > 7 && first[0] == 1 && String.fromCharCodes(first.sublist(1, 7)) == 'vorbis') {
    final headers = <Uint8List>[];
    final rest = <Uint8List>[];
    await for (final p in ogg.packets()) {
      if (headers.length < 3) {
        headers.add(p);
      } else {
        rest.add(p);
      }
    }
    if (headers.length < 3) throw const AudioFormatException('The Vorbis headers of this file are incomplete.');
    final decoder = VorbisDecoder(headers[0], headers[2]);
    final seconds = ogg.lastGranule < 0 ? null : ogg.lastGranule / decoder.sampleRate;
    return _FramePcm('vorbis', decoder.sampleRate, decoder.channels, seconds, Stream.fromIterable(rest), decoder.decode, 1024);
  }
  throw const AudioFormatException('The sound in this Ogg file is not Opus or Vorbis; other kinds cannot be read yet.');
}

/// Opus packets with the settings of an `OpusHead` ([head]) as 48 kHz samples; the pre-skip and the gain of the head are applied.
PcmSource _opusPcm(Uint8List head, Stream<Uint8List> packets, double? seconds) {
  if (head.length < 19) throw const AudioFormatException('The Opus settings of this file are too short.');
  final channels = head[9];
  final preSkip = head[10] | (head[11] << 8);
  var gainQ8 = head[16] | (head[17] << 8);
  if (gainQ8 >= 32768) gainQ8 -= 65536;
  final family = head[18];
  if (family != 0 && !(family == 1 && channels <= 2)) throw const AudioFormatException('Opus with more than two channels cannot be read yet.');
  if (channels < 1 || channels > 2) throw const AudioFormatException('This Opus audio has an unusual number of channels.');
  final gain = gainQ8 == 0 ? 1.0 : math.pow(10, gainQ8 / (20 * 256)).toDouble();
  final decoder = OpusDecoder(channels);
  var skip = preSkip;
  return _FramePcm('opus', 48000, channels, seconds, packets, (packet) {
    var pcm = decoder.decodePacket(packet);
    if (gain != 1.0) {
      for (final c in pcm) {
        for (var i = 0; i < c.length; i++) {
          c[i] *= gain;
        }
      }
    }
    if (skip > 0) {
      final drop = math.min(skip, pcm[0].length);
      skip -= drop;
      pcm = [for (final c in pcm) Float64List.sublistView(c, drop)];
      if (pcm[0].isEmpty) return null;
    }
    return pcm;
  }, 960);
}
