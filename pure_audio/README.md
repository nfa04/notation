# pure_audio

Decode audio, and the audio track of video files, in plain Dart. No native code, no ffmpeg, no platform channels: it runs the same on
Android, iOS, desktop and the web.

```dart
import 'package:pure_audio/pure_audio.dart';

final source = await openAudio(MemoryByteSource(bytes)); // or any ByteSource that reads at an offset (a file, a stream)
print('${source.codec}, ${source.sampleRate} Hz, ${source.channels} channels');
await for (final block in source.blocks()) {
  // block[channel] is a Float64List of samples in -1..1
}
// or, for speech recognition: 16 kHz mono blocks
await for (final Float32List chunk in mono16k(source)) {}
```

Files are read in pieces, so a video of many gigabytes needs memory for about a second of sound.

| Kind | Status |
| --- | --- |
| MP4 / M4A / MOV (also built in fragments, as from streaming sites) with AAC-LC (mono, stereo; HE-AAC is decoded at its core rate, without the high band) | works, checked against ffmpeg (> 115 dB SNR) |
| MP3 in MP3 files, MP4 or Matroska (MPEG-1/2/2.5 Layer III) | works, checked against ffmpeg (> 115 dB SNR); intensity stereo is not applied |
| Matroska / WebM / MKA with AAC or MP3 | works |
| FLAC, WAV (8/16/24/32 bit PCM, float, A-law, mu-law) | works, exact |
| Opus (Ogg `.opus`/`.ogg`, WebM, Matroska, MP4): CELT, SILK and hybrid, mono and stereo, all frame sizes | works, checked against libopus (speech modes are bit-exact, music within 16 bit rounding, > 75 dB); no repair of lost packets, no cross fade at a change of mode, more than two channels not supported |
| Vorbis I (Ogg, Matroska/WebM, MP4), floor type 1 | works, checked against ffmpeg (> 75 dB); floor type 0 (very old files) is not supported |
| Layers I and II, AAC Main/LTP/SSR, 5.1 channels | not supported (an `AudioFormatException` says so in a plain sentence) |

There are no encoders.

## Tests

`dart test`. The test files are made by `test/fixtures/make_fixtures.sh` (needs `ffmpeg` and `espeak-ng`); every file has the output
of ffmpeg next to it (`*.ref.gz`, 16 bit samples) and the tests demand a signal to noise ratio of at least 60 dB after the codec's
delay.

## Licence

The Opus decoder (`lib/src/opus/`) is a port of [libopus](https://opus-codec.org) 1.5.2 (BSD-3-Clause: Copyright Xiph.Org Foundation,
Skype Limited, Octasic, Jean-Marc Valin, Timothy B. Terriberry, CSIRO, Gregory Maxwell, Mozilla, Amazon and others) and carries its
tables; the licence text of libopus applies to those files.


The AAC and MP3 decoders are written after the decoders of the [Symphonia](https://github.com/pdeljanov/Symphonia) project
(MPL-2.0, which in turn follows NihAV), and the code tables in `aac_tables.dart` and `mp3_tables.dart` are taken from it. Files
derived from it stay under the MPL-2.0; the rest is yours to license (the app that uses it is AGPL-3.0).
