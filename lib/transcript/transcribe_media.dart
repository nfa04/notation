import 'dart:typed_data';

import 'package:pure_audio/pure_audio.dart';

import '../speech/speech_to_text.dart';
import 'transcript.dart';

/// What Whisper heard in an audio or video file: decoded in plain Dart (AAC, MP3, FLAC, WAV; in MP4, M4A, MOV or alone), piece by
/// piece, so a long recording needs little memory. The times come from the model. [progress] gets (seconds done, seconds in all or
/// null if the file does not say). Throws an [AudioFormatException] with a plain sentence when the file cannot be read.
Future<Transcript> transcribeMedia(
  SpeechToText speech,
  ByteSource source, {
  required String name,
  String? language,
  void Function(double done, double? total)? progress,
  void Function(List<TranscriptSegment> soFar)? onSegments,
  bool Function()? shouldStop,
}) async {
  final audio = await openAudio(source);
  final total = audio.seconds;
  final segments = await speech.transcribeTimedStream(
    mono16k(audio),
    language: language,
    onSegments: onSegments,
    progress: (s) => progress?.call(s, total),
    shouldStop: shouldStop,
  );
  return Transcript(title: name.replaceFirst(RegExp(r'\.[A-Za-z0-9]{1,5}$'), ''), source: name, language: speech.language ?? '', segments: segments);
}

/// A [ByteSource] over bytes in memory.
ByteSource memorySource(Uint8List bytes) => MemoryByteSource(bytes);
