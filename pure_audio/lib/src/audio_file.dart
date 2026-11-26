import 'bits.dart';
import 'byte_source.dart';
import 'flac.dart';
import 'mkv_demux.dart';
import 'mp3_decoder.dart';
import 'mp4_demux.dart';
import 'pcm.dart';
import 'wav_source.dart';
import 'aac_decoder.dart';

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
