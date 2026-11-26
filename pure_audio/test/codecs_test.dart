import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('AAC in MP4', () {
    for (final f in ['aac_mono_22k.m4a', 'aac_stereo_44k.m4a', 'aac_video_48k.mp4', 'raw_stereo_44k.aac']) {
      expectMatchesReference(f);
    }
  });
  group('MP3', () {
    for (final f in ['m_mono_22k.mp3', 'm_stereo_44k.mp3', 'm_mono_16k.mp3', 'm_stereo_plain.mp3']) {
      expectMatchesReference(f);
    }
  });
  group('Matroska', () {
    for (final f in ['k_aac.mkv', 'k_mp3.mkv', 'k_aac_stereo.mka']) {
      expectMatchesReference(f);
    }
  });
  group('FLAC and WAV', () {
    for (final f in ['t_mono.flac', 't_stereo.flac', 't_24.wav', 't_f32.wav']) {
      expectMatchesReference(f, minSnr: 85);
    }
    expectMatchesReference('t_mulaw.wav', minSnr: 75);
  });
}
