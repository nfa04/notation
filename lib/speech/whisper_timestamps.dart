import 'dart:math' as math;

/// A stretch of speech with its time in the window it was heard in (seconds from the window's start).
class TimedText {
  final double start, end;
  final String text;
  const TimedText(this.start, this.end, this.text);

  @override
  String toString() => '[$start-$end] $text';
}

/// The tokens of Whisper that are times: `<|0.00|>` is 50364, then one for every 0.02 seconds up to `<|30.00|>`.
const whisperFirstTimestamp = 50364;
const whisperLastTimestamp = whisperFirstTimestamp + 1500;
const _endOfText = 50257;
const _space = 220;
const _firstSpecial = 50258;

/// The seconds a timestamp token stands for.
double timestampSeconds(int token) => (token - whisperFirstTimestamp) * 0.02;

bool isTimestamp(int token) => token >= whisperFirstTimestamp;

/// The next token of a decoding that writes times, chosen the way the reference implementation of Whisper does:
///  - the text comes as `<start> words <end>`, the next stretch starts with `<start>` again, so times come in pairs;
///  - the first token is a time (not later than a second in), and times never go back;
///  - where the probability of all times together is larger than that of the best word, a time is written.
/// [scores] are the raw scores of all tokens, [written] the tokens chosen so far, [suppressed] the ones the model must not write.
/// Returns -1 when nothing can be written.
int pickTimedToken(List<double> scores, List<int> written, Set<int> suppressed, {double firstTimeLimit = 1.0}) {
  final n = scores.length;
  final s = List<double>.of(scores);
  const off = double.negativeInfinity;
  for (final t in suppressed) {
    if (t < n) s[t] = off;
  }
  // (the markers of language, task and "no times" are never written; the end of the text and the words stay)
  for (var t = _firstSpecial; t < whisperFirstTimestamp && t < n; t++) {
    s[t] = off;
  }
  final last = written.isNotEmpty && isTimestamp(written.last);
  final beforeLast = written.length < 2 || isTimestamp(written[written.length - 2]);
  if (written.isEmpty) {
    s[_space] = off;
    s[_endOfText] = off;
  }
  if (last) {
    if (beforeLast) {
      // a pair is complete: words must follow
      for (var t = whisperFirstTimestamp; t < n; t++) {
        s[t] = off;
      }
    } else {
      // an end time was written: the next start time or the end of the text follows
      for (var t = 0; t < _endOfText; t++) {
        s[t] = off;
      }
    }
  }
  final times = [for (final t in written) if (isTimestamp(t)) t];
  if (times.isNotEmpty) {
    final from = (last && !beforeLast) ? times.last : times.last + 1;
    for (var t = whisperFirstTimestamp; t < from && t < n; t++) {
      s[t] = off;
    }
  }
  if (written.isEmpty) {
    final limit = whisperFirstTimestamp + (firstTimeLimit / 0.02).round();
    for (var t = 0; t < n; t++) {
      if (t < whisperFirstTimestamp || t > limit) s[t] = off;
    }
  }
  // together, are the times more likely than any word?
  var top = off, timeMass = 0.0;
  final peak = _maxOf(s);
  if (peak == off) return -1;
  for (var t = 0; t < n; t++) {
    if (s[t] == off) continue;
    final e = math.exp(s[t] - peak);
    if (t >= whisperFirstTimestamp) {
      timeMass += e;
    } else if (s[t] > top) {
      top = s[t];
    }
  }
  if (top != off && timeMass > math.exp(top - peak)) {
    for (var t = 0; t < whisperFirstTimestamp && t < n; t++) {
      s[t] = off;
    }
  }
  var best = -1;
  var bestScore = off;
  for (var t = 0; t < n; t++) {
    if (s[t] > bestScore) {
      bestScore = s[t];
      best = t;
    }
  }
  return best;
}

double _maxOf(List<double> v) {
  var m = double.negativeInfinity;
  for (final x in v) {
    if (x > m) m = x;
  }
  return m;
}

/// The stretches of speech in the tokens a timed decoding wrote. [decode] turns word tokens into text. A stretch that was not closed
/// by an end time (the model stopped, or was stopped) ends at [windowSeconds]. Stretches are in order, do not go back in time and stay
/// inside the window; empty ones are left out.
List<TimedText> segmentsFromTokens(List<int> tokens, String Function(List<int>) decode, {required double windowSeconds}) {
  final out = <TimedText>[];
  var start = 0.0;
  var words = <int>[];
  var previousEnd = 0.0;
  void close(double end) {
    if (words.isEmpty) return;
    final text = decode(words).trim();
    words = [];
    if (text.isEmpty) return;
    final from = start.clamp(previousEnd, windowSeconds).toDouble();
    final to = end.clamp(from, windowSeconds).toDouble();
    out.add(TimedText(from, to, text));
    previousEnd = to;
  }

  for (final t in tokens) {
    if (isTimestamp(t)) {
      final at = timestampSeconds(t);
      if (words.isEmpty) {
        start = at;
      } else {
        close(at);
      }
    } else if (t < _endOfText) {
      words.add(t);
    }
  }
  close(windowSeconds);
  return out;
}
