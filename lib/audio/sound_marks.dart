/// The moment of a recording at which a stroke or a text box was written: "sound-synced notes". Playing the sound from a mark plays what
/// was being said while that line was written.
class SoundMark {
  final String elementId;
  final int page;
  final int offsetMs;

  const SoundMark(this.elementId, this.page, this.offsetMs);
}

/// Where in which recording an element of a note was written.
class SoundPoint {
  final String audioId;
  final int offsetMs;

  const SoundPoint(this.audioId, this.offsetMs);

  Duration get offset => Duration(milliseconds: offsetMs);
}

/// The marks of a recording as it goes on: every element that was not there before gets the moment it was first seen.
class MarkCollector {
  final Set<String> _known = {};
  final List<SoundMark> marks = [];

  /// What is on the pages as the recording starts: not marked, it was written before.
  void begin(Map<int, List<String>> idsByPage) {
    _known.clear();
    marks.clear();
    for (final ids in idsByPage.values) {
      _known.addAll(ids);
    }
  }

  /// Marks the elements of [idsByPage] that were not seen yet with [at] (how far the recording is). Returns how many are new.
  int observe(Map<int, List<String>> idsByPage, Duration at) {
    var added = 0;
    for (final e in idsByPage.entries) {
      for (final id in e.value) {
        if (_known.add(id)) {
          marks.add(SoundMark(id, e.key, at.inMilliseconds));
          added++;
        }
      }
    }
    return added;
  }
}

/// The marks of one recording in the order they were written, for asking "what was being written at this moment of the sound?" while
/// it plays (the lines that light up as the recording goes on).
class SoundTimeline {
  /// The recording these marks belong to.
  final String audioId;
  final List<int> _offsets = [];
  final List<String> _ids = [];
  final Map<String, int> _byId = {};

  /// The marks of [audioId] among [marks] (the element ids with where they were written, see `AudioRepository.marksOf`).
  SoundTimeline(this.audioId, Map<String, SoundPoint> marks) {
    final mine = [for (final e in marks.entries) if (e.value.audioId == audioId) (e.value.offsetMs, e.key)]
      ..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    for (final m in mine) {
      _offsets.add(m.$1);
      _ids.add(m.$2);
      _byId[m.$2] = m.$1;
    }
  }

  bool get isEmpty => _ids.isEmpty;

  /// The moments of the marks, earliest first (for ticks on the bar of the sound).
  List<int> get offsetsMs => List.unmodifiable(_offsets);

  /// The elements being written at [position]: the latest one that was written by then, with those that came up to [span] before it (the
  /// strokes of one word are not one moment). Nothing before the first mark, and nothing once [hold] has passed without a new one (a long
  /// stretch of speaking points at nothing).
  Set<String> idsAt(Duration position, {Duration span = const Duration(seconds: 3), Duration hold = const Duration(seconds: 30)}) {
    final at = position.inMilliseconds;
    // the last mark that is not after [at]
    var lo = 0, hi = _offsets.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_offsets[mid] <= at) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final last = lo - 1;
    if (last < 0 || at - _offsets[last] > hold.inMilliseconds) return const {};
    final from = _offsets[last] - span.inMilliseconds;
    final ids = <String>{};
    for (var i = last; i >= 0 && _offsets[i] >= from; i--) {
      ids.add(_ids[i]);
    }
    return ids;
  }

  /// Where in the sound to start so that [elementId] is heard as it was written (a little before, so that the first words are not cut);
  /// null when this recording does not know the element.
  Duration? startFor(String elementId, {Duration lead = const Duration(seconds: 2)}) {
    final ms = _byId[elementId];
    if (ms == null) return null;
    final from = Duration(milliseconds: ms) - lead;
    return from.isNegative ? Duration.zero : from;
  }
}
