/// Audio decoding in plain Dart. Start with [openAudio], then read `blocks()` or [mono16k].
library;

export 'src/aac_decoder.dart' show AacDecoder;
export 'src/audio_file.dart' show openAudio;
export 'src/bits.dart' show AudioFormatException;
export 'src/byte_source.dart';
export 'src/flac.dart' show FlacSource;
export 'src/mkv_demux.dart' show MkvAudio, openMkv;
export 'src/mp3_decoder.dart' show Mp3Decoder, Mp3Header, Mp3Source;
export 'src/mp4_demux.dart' show Mp4Audio, readMp4Audio, mp4Samples;
export 'src/pcm.dart';
export 'src/wav_source.dart' show WavSource;
