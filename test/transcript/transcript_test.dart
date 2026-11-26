import 'package:flutter_test/flutter_test.dart';
import 'package:notes/transcript/transcript.dart';

void main() {
  test('SRT: times with commas, numbers, tags and entities', () {
    const srt = '1\n00:00:01,500 --> 00:00:03,000\nHello <i>there</i> &amp; welcome\n\n2\n00:01:02,250 --> 00:01:04,000\nSecond\nline\n';
    final s = parseCaptions(srt);
    expect(s.length, 2);
    expect(s[0].start, 1.5);
    expect(s[0].end, 3.0);
    expect(s[0].text, 'Hello there & welcome');
    expect(s[1].start, 62.25);
    expect(s[1].text, 'Second line');
  });

  test('WebVTT: header, cue settings, short times, hours', () {
    const vtt = 'WEBVTT\nKind: captions\n\nNOTE a comment\n\n01:02.000 --> 01:04.000 align:start position:0%\nShort form\n\ncue-id\n1:00:00.000 --> 1:00:02.000\nAn hour in\n';
    final s = parseCaptions(vtt);
    expect(s.map((e) => e.text), ['Short form', 'An hour in']);
    expect(s[0].start, 62);
    expect(s[1].start, 3600);
  });

  test('rolling automatic captions: the line shown before is not said twice', () {
    const vtt = 'WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nthis is the first line\n\n00:00:02.000 --> 00:00:04.000\nthis is the first line\nand now the second\n\n00:00:04.000 --> 00:00:06.000\nand now the second\nand the third\n';
    final s = parseCaptions(vtt);
    expect(s.map((e) => e.text), ['this is the first line', 'and now the second', 'and the third']);
  });

  test('YouTube json3: segments joined, empty events skipped', () {
    const json = '{"events":[{"tStartMs":0,"dDurationMs":1000,"segs":[{"utf8":"Hello "},{"utf8":"world"}]},{"tStartMs":1000,"dDurationMs":500,"segs":[{"utf8":"\\n"}]},{"tStartMs":61500,"dDurationMs":2000,"segs":[{"utf8":"It&#39;s late"}]},{"wsWinStyleId":1}]}';
    final s = parseCaptions(json);
    expect(s.map((e) => e.text), ['Hello world', "It's late"]);
    expect(s[1].start, 61.5);
    expect(s[1].end, 63.5);
  });

  test('YouTube XML: seconds form and milliseconds form', () {
    final a = parseCaptions('<?xml version="1.0"?><transcript><text start="1.5" dur="2">Don&amp;#39;t panic</text><text start="4" dur="1">Next</text></transcript>');
    expect(a.map((e) => e.text), ["Don't panic", 'Next']);
    expect(a[0].end, 3.5);
    final b = parseCaptions('<timedtext format="3"><body><p t="1500" d="2000">One <s>two</s></p><p t="4000" d="1000">Three</p></body></timedtext>');
    expect(b.map((e) => e.text), ['One two', 'Three']);
    expect(b[0].start, 1.5);
    expect(b[0].end, 3.5);
  });

  test('things that are not captions are refused with a reason', () {
    for (final bad in ['', 'just some words', '{"a":1}', '{nope', '<html></html>', 'WEBVTT\n\n']) {
      expect(() => parseCaptions(bad), throwsFormatException, reason: bad);
    }
  });

  test('segments come out in time order', () {
    final s = parseCaptions('1\n00:00:05,000 --> 00:00:06,000\nlater\n\n2\n00:00:01,000 --> 00:00:02,000\nearlier\n');
    expect(s.map((e) => e.text), ['earlier', 'later']);
  });

  test('clockText', () {
    expect(clockText(0), '0:00');
    expect(clockText(187.9), '3:07');
    expect(clockText(3787), '1:03:07');
  });

  test('timeLink: YouTube forms, other addresses, files', () {
    expect(timeLink('https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=x', 75), 'https://youtu.be/dQw4w9WgXcQ?t=75');
    expect(timeLink('https://youtu.be/dQw4w9WgXcQ?si=abc', 5), 'https://youtu.be/dQw4w9WgXcQ?t=5');
    expect(timeLink('https://m.youtube.com/shorts/abcdefghijk', 1), 'https://youtu.be/abcdefghijk?t=1');
    expect(timeLink('https://example.com/v/talk.mp4', 90), 'https://example.com/v/talk.mp4#t=90');
    expect(timeLink('https://www.youtube.com/', 3), isNull);
    expect(timeLink('/home/me/lecture.mp4', 3), isNull);
    expect(timeLink('lecture.mp4', 3), isNull);
    expect(timeLink('javascript:alert(1)', 3), isNull);
  });

  test('formatTranscript: paragraphs of about a minute, each with its time as a link', () {
    final segments = [for (var i = 0; i < 12; i++) TranscriptSegment(i * 10.0, i * 10.0 + 9, 'Part $i${i % 4 == 3 ? '.' : ''}')];
    final text = formatTranscript(Transcript(title: 'T', source: 'https://youtu.be/dQw4w9WgXcQ', segments: segments));
    final lines = text.split('\n').where((l) => l.isNotEmpty).toList();
    expect(lines.first, 'Source: <https://youtu.be/dQw4w9WgXcQ>');
    expect(lines[1], startsWith('[0:00](https://youtu.be/dQw4w9WgXcQ?t=0) Part 0'));
    expect(lines.length, greaterThan(2));
    expect(lines[2], contains('?t=')); // a second paragraph began
    expect(text, contains('Part 11'));
  });

  test('formatTranscript: a local file has bold times and no links; times can be left out', () {
    final t = Transcript(source: 'lecture.mp4', segments: const [TranscriptSegment(3725, 3727, 'Late'), TranscriptSegment(3727, 3728, 'on')]);
    expect(formatTranscript(t), 'Source: lecture.mp4\n\n**1:02:05** Late on');
    expect(formatTranscript(t, times: false), 'Source: lecture.mp4\n\nLate on');
    expect(formatTranscript(const Transcript(segments: [])), '');
  });
}
