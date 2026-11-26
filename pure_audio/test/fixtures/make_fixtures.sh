#!/bin/sh
# Makes the test files from a spoken sentence (espeak-ng) with ffmpeg; each has a reference: what ffmpeg decodes it to, as 16 bit
# samples, gzipped. Run in this folder: ./make_fixtures.sh
set -e
espeak-ng -v en -s 150 -w speech.wav "Hello and welcome to this short talk. Today we will look at how plants make energy from light. Thank you for listening."
ffmpeg -loglevel error -y -i speech.wav -t 2.5 -ac 1 -ar 22050 mono22.wav
ffmpeg -loglevel error -y -i mono22.wav -ar 44100 -filter_complex "[0:a]asplit[l][r];[r]volume=0.5,adelay=3|3[r2];[l][r2]amerge=inputs=2" st44.wav
ffmpeg -loglevel error -y -i mono22.wav -c:a aac -b:a 48k aac_mono_22k.m4a
ffmpeg -loglevel error -y -i st44.wav -t 2 -c:a aac -b:a 96k aac_stereo_44k.m4a
ffmpeg -loglevel error -y -f lavfi -i color=c=black:s=64x64:r=5:d=3 -i mono22.wav -ar 48000 -c:v libx264 -preset ultrafast -c:a aac -b:a 64k -shortest aac_video_48k.mp4
ffmpeg -loglevel error -y -i mono22.wav -c:a libmp3lame -b:a 48k m_mono_22k.mp3
ffmpeg -loglevel error -y -i st44.wav -t 2 -c:a libmp3lame -b:a 96k m_stereo_44k.mp3
ffmpeg -loglevel error -y -i mono22.wav -ar 16000 -c:a libmp3lame -b:a 32k m_mono_16k.mp3
ffmpeg -loglevel error -y -i st44.wav -t 2 -c:a libmp3lame -b:a 128k -joint_stereo 0 m_stereo_plain.mp3
ffmpeg -loglevel error -y -i mono22.wav -c:a flac t_mono.flac
ffmpeg -loglevel error -y -i st44.wav -t 2 -c:a flac t_stereo.flac
ffmpeg -loglevel error -y -i mono22.wav -c:a pcm_s24le t_24.wav
ffmpeg -loglevel error -y -i mono22.wav -c:a pcm_mulaw -ar 8000 t_mulaw.wav
ffmpeg -loglevel error -y -i mono22.wav -c:a pcm_f32le t_f32.wav
ffmpeg -loglevel error -y -i mono22.wav -c:a aac -b:a 48k k_aac.mkv
ffmpeg -loglevel error -y -i mono22.wav -c:a libmp3lame -b:a 48k k_mp3.mkv
ffmpeg -loglevel error -y -i st44.wav -t 2 -c:a aac -b:a 96k k_aac_stereo.mka
ffmpeg -loglevel error -y -i aac_stereo_44k.m4a -c:a copy -f adts raw_stereo_44k.aac
# Opus (the reference is libopus itself)
ffmpeg -loglevel error -y -i st44.wav -t 2 -c:a libopus -application audio -b:a 96k o_celt_stereo.opus
ffmpeg -loglevel error -y -i mono22.wav -c:a libopus -application audio -b:a 32k -frame_duration 20 o_hybrid_mono.opus
ffmpeg -loglevel error -y -i st44.wav -t 2 -c:a libopus -application voip -b:a 48k -cutoff 12000 o_hybrid_stereo.opus
ffmpeg -loglevel error -y -i mono22.wav -c:a libopus -application voip -b:a 8k -cutoff 4000 o_silk_nb.opus
ffmpeg -loglevel error -y -i mono22.wav -c:a libopus -application voip -b:a 12k -cutoff 6000 -frame_duration 60 o_silk_mb_60ms.opus
ffmpeg -loglevel error -y -i mono22.wav -c:a libopus -application voip -b:a 16k -cutoff 8000 -frame_duration 40 o_silk_wb_40ms.opus
ffmpeg -loglevel error -y -i st44.wav -t 2 -c:a libopus -application voip -b:a 40k -cutoff 8000 o_silk_wb_stereo.opus
ffmpeg -loglevel error -y -i o_silk_wb_stereo.opus -c:a copy o_in_webm.webm
ffmpeg -loglevel error -y -i o_hybrid_mono.opus -c:a copy o_in_mp4.mp4
ffmpeg -loglevel error -y -i o_celt_stereo.opus -c:a copy o_in_mkv.mka
ffmpeg -loglevel error -y -i mono22.wav -c:a libvorbis -q:a 3 v_mono.ogg
ffmpeg -loglevel error -y -i st44.wav -t 2 -c:a libvorbis -q:a 5 v_stereo.ogg
ffmpeg -loglevel error -y -i st44.wav -t 2 -c:a libvorbis -b:a 64k v_stereo_in.mkv
ffmpeg -loglevel error -y -i aac_stereo_44k.m4a -c:a copy -movflags frag_keyframe+empty_moov+default_base_moof f_aac.mp4
ffmpeg -loglevel error -y -i o_hybrid_mono.opus -c:a copy -movflags frag_keyframe+empty_moov f_opus.mp4
ffmpeg -loglevel error -y -i f_aac.mp4 -f s16le - | gzip -9 > f_aac.ref.gz
ffmpeg -loglevel error -y -c:a libopus -i f_opus.mp4 -f s16le - | gzip -9 > f_opus.ref.gz
ffmpeg -loglevel error -y -i v_stereo.ogg -c:a copy -strict -2 v_in_mp4.mp4
for f in v_*; do
  case "$f" in *.ref.gz) continue;; esac
  ffmpeg -loglevel error -y -i "$f" -f s16le - | gzip -9 > "${f%.*}.ref.gz"
done
for f in o_*; do
  case "$f" in *.ref.gz) continue;; esac
  ffmpeg -loglevel error -y -c:a libopus -i "$f" -f s16le - | gzip -9 > "${f%.*}.ref.gz"
done
for f in *.aac *.m4a *.mp4 *.mp3 *.flac t_*.wav *.mkv *.mka *.ogg; do
  [ -f "$f" ] || continue
  ffmpeg -loglevel error -y -i "$f" -f s16le - | gzip -9 > "${f%.*}.ref.gz"
done
rm -f speech.wav mono22.wav st44.wav
