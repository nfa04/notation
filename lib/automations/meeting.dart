import '../data/note_data.dart';

/// The note made for the meeting of a calendar event ("Standup") that came before this one: the note changed last among those whose title
/// starts with the event's title (any case), leaving out [exceptId] (the note being made now) and locked notes. Null for the first
/// meeting of a series.
NoteSummary? previousMeetingNote(Iterable<NoteSummary> notes, String eventTitle, {required String exceptId}) {
  final name = eventTitle.trim().toLowerCase();
  if (name.length < 3) return null;
  NoteSummary? best;
  for (final n in notes) {
    if (n.id == exceptId || n.lockMode != 0 || !n.title.trim().toLowerCase().startsWith(name)) continue;
    if (best == null || n.updatedAt.isAfter(best.updatedAt)) best = n;
  }
  return best;
}

/// The text the note of a meeting starts with: what the meeting is, the lines still to do from the last one ([open], as they were
/// written, without their marker; at most [maxOpen]) and a place for notes. [previous] is the title of that last note.
String meetingNoteText({
  required String title,
  required String day,
  required String start,
  String? previous,
  List<String> open = const [],
  int maxOpen = 12,
}) {
  final b = StringBuffer('**$title**  ·  $day${start.isEmpty ? '' : ' $start'}');
  if (open.isNotEmpty) {
    b.write('\n\n**Still open from last time**${previous == null ? '' : ' ($previous)'}');
    for (final item in open.take(maxOpen)) {
      b.write('\n☐ $item');
    }
    if (open.length > maxOpen) b.write('\n… and ${open.length - maxOpen} more');
  }
  b.write('\n\n**Notes**\n');
  return b.toString();
}
