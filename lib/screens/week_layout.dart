import '../sync/caldav_remote.dart';

/// A timed event placed in one day's time grid.
class PlacedEvent {
  final DayEvent event;

  /// Minutes from midnight; [endMinute] is at most 1440.
  final int startMinute;
  final int endMinute;

  /// Overlapping events share the width: this one is column [lane] of [lanes].
  final int lane;
  final int lanes;

  const PlacedEvent(this.event, this.startMinute, this.endMinute, this.lane, this.lanes);
}

/// Shortest height an event gets in the grid, so that short events can be read.
const int minEventMinutes = 25;

/// Places the timed (not all-day) events that touch [day] in a time grid.
/// An event across midnight appears on both days, clipped to each.
List<PlacedEvent> layoutDay(Iterable<DayEvent> events, DateTime day) {
  final dayStart = DateTime(day.year, day.month, day.day);
  final dayEnd = DateTime(day.year, day.month, day.day + 1);

  // (event, start, end) in minutes, clipped to the day
  final items = <(DayEvent, int, int)>[];
  for (final e in events) {
    if (e.allDay) continue;
    var end = e.end ?? e.start.add(const Duration(hours: 1));
    if (!end.isAfter(e.start)) end = e.start.add(const Duration(minutes: 30));
    if (!end.isAfter(dayStart) || !e.start.isBefore(dayEnd)) continue;

    final start = e.start.isBefore(dayStart) ? 0 : e.start.hour * 60 + e.start.minute;
    var stop = end.isAfter(dayEnd) ? 1440 : end.hour * 60 + end.minute;
    if (stop <= start) stop = start + minEventMinutes;
    if (stop - start < minEventMinutes) stop = start + minEventMinutes;
    items.add((e, start, stop > 1440 ? 1440 : stop));
  }
  items.sort((a, b) => a.$2 != b.$2 ? a.$2.compareTo(b.$2) : b.$3.compareTo(a.$3));

  final placed = <PlacedEvent>[];
  var cluster = <(DayEvent, int, int, int)>[]; // + lane
  var laneEnds = <int>[];
  var clusterEnd = 0;

  void closeCluster() {
    for (final c in cluster) {
      placed.add(PlacedEvent(c.$1, c.$2, c.$3, c.$4, laneEnds.length));
    }
    cluster = [];
    laneEnds = [];
  }

  for (final (event, start, end) in items) {
    if (cluster.isNotEmpty && start >= clusterEnd) closeCluster();
    var lane = laneEnds.indexWhere((laneEnd) => laneEnd <= start);
    if (lane == -1) {
      lane = laneEnds.length;
      laneEnds.add(end);
    } else {
      laneEnds[lane] = end;
    }
    cluster.add((event, start, end, lane));
    if (cluster.length == 1 || end > clusterEnd) clusterEnd = end;
  }
  closeCluster();
  return placed;
}
