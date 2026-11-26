// YouTube transcripts: a transcript source for "New note from a transcript".
//
// 1. the link (or the bare video id) gives the video id;
// 2. the player endpoint, asked as YouTube's own Android app asks, answers with the title and the list of caption tracks;
// 3. one track is chosen and downloaded; the app reads the caption file itself (it is YouTube's XML).
//
// Nothing here is an official API: when YouTube changes it, this is the one file to fix.

const CLIENT_VERSION = '20.10.38';
const USER_AGENT = 'com.google.android.youtube/' + CLIENT_VERSION + ' (Linux; U; Android 14) gzip';

function videoId(input) {
  const text = String(input || '').trim();
  if (/^[\w-]{11}$/.test(text)) return text;
  const m = text.match(/^(?:https?:\/\/)?(?:(?:www|m|music)\.)?(?:youtube\.com|youtube-nocookie\.com|youtu\.be)\/(.*)$/i);
  if (!m) return null;
  const rest = m[1];
  const fromQuery = rest.match(/[?&]v=([\w-]{11})(?:[&#]|$)/);
  if (fromQuery) return fromQuery[1];
  const fromPath = rest.match(/^(?:shorts\/|embed\/|live\/|v\/)?([\w-]{11})(?:[/?&#]|$)/);
  return fromPath ? fromPath[1] : null;
}

// The track to take: the language the video is spoken in (the automatic track says it), a person's captions before the automatic ones.
function chooseTrack(tracks) {
  const automatic = tracks.filter((t) => t.kind === 'asr');
  const written = tracks.filter((t) => t.kind !== 'asr');
  const spoken = automatic.length ? String(automatic[0].languageCode || '').split('-')[0] : '';
  const sameLanguage = (t) => spoken && String(t.languageCode || '').split('-')[0] === spoken;
  return written.find(sameLanguage) || written[0] || automatic[0] || null;
}

async function ask(url, options) {
  try {
    return await notation.network.fetch(url, options);
  } catch (e) {
    throw new Error('Could not reach YouTube: ' + ((e && e.message) || e));
  }
}

notation.transcriptSource('youtube', async (ctx) => {
  const id = videoId(ctx.input);
  if (!id) throw new Error('This is not a YouTube link.');

  const answer = await ask('https://www.youtube.com/youtubei/v1/player?prettyPrint=false', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'User-Agent': USER_AGENT },
    body: JSON.stringify({
      context: { client: { clientName: 'ANDROID', clientVersion: CLIENT_VERSION, androidSdkVersion: 34, hl: 'en' } },
      videoId: id,
    }),
  });
  if (answer.status !== 200) throw new Error('YouTube answered with the error ' + answer.status + '. It may have changed what it asks for.');
  let player;
  try {
    player = JSON.parse(answer.body);
  } catch (e) {
    throw new Error('YouTube gave an answer that cannot be read. It may have changed.');
  }

  const status = player.playabilityStatus || {};
  if (status.status && status.status !== 'OK') {
    throw new Error('YouTube will not show this video here' + (status.reason ? ': ' + status.reason : '.'));
  }
  const listed = player.captions && player.captions.playerCaptionsTracklistRenderer;
  const tracks = ((listed && listed.captionTracks) || []).filter((t) => t && typeof t.baseUrl === 'string');
  if (!tracks.length) throw new Error('This video has no captions.');

  const track = chooseTrack(tracks);
  if (!track.baseUrl.startsWith('https://www.youtube.com/')) throw new Error('YouTube pointed to a place this extension may not use.');
  const file = await ask(track.baseUrl, { headers: { 'User-Agent': USER_AGENT } });
  if (file.status !== 200 || !file.body || !file.body.trim()) {
    throw new Error('YouTube did not hand over the captions (status ' + file.status + '). It may have changed what it asks for.');
  }

  const details = player.videoDetails || {};
  return {
    captions: { text: file.body },
    title: typeof details.title === 'string' ? details.title : '',
    language: String(track.languageCode || ''),
    source: 'https://www.youtube.com/watch?v=' + id,
  };
});
