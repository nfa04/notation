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
for f in *.aac *.m4a *.mp4 *.mp3 *.flac t_*.wav *.mkv *.mka *.ogg *.opus *.webm; do
  [ -f "$f" ] || continue
  ffmpeg -loglevel error -y -i "$f" -f s16le - | gzip -9 > "${f%.*}.ref.gz"
done
rm -f speech.wav mono22.wav st44.wav
