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
  group('Opus', () {
    // (libopus is the reference: speech modes are exact, CELT within the rounding to 16 bit)
    for (final f in ['o_celt_stereo.opus', 'o_hybrid_mono.opus', 'o_hybrid_stereo.opus']) {
      expectMatchesReference(f, minSnr: 70);
    }
    for (final f in ['o_silk_nb.opus', 'o_silk_mb_60ms.opus', 'o_silk_wb_40ms.opus', 'o_silk_wb_stereo.opus']) {
      expectMatchesReference(f, minSnr: 90);
    }
    for (final f in ['o_in_webm.webm', 'o_in_mp4.mp4', 'o_in_mkv.mka']) {
      expectMatchesReference(f, minSnr: 70);
    }
  });
  group('Vorbis', () {
    for (final f in ['v_mono.ogg', 'v_stereo.ogg', 'v_stereo_in.mkv', 'v_in_mp4.mp4']) {
      expectMatchesReference(f, minSnr: 70);
    }
  });
  group('Fragmented MP4', () {
    for (final f in ['f_aac.mp4', 'f_opus.mp4']) {
      expectMatchesReference(f, minSnr: 70);
    }
  });
  group('Length', () {
    // the end of an Ogg file says where the sound really stops
    for (final f in ['o_celt_stereo.opus', 'o_silk_nb.opus', 'v_mono.ogg', 'v_stereo.ogg']) {
      test('$f ends where the reference ends', () async {
        final (source, got) = await decodeFixture(f);
        final ref = reference(f).length ~/ got.length;
        expect((got[0].length - ref).abs(), lessThan(5), reason: '$f has ${got[0].length}, expected $ref');
      });
    }
  });
}
