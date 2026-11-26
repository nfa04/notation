import 'transcript.dart';

/// Something that can turn an address (or any text the person types) into a [Transcript]: an extension that talks to a video site.
/// [fetch] throws a [TranscriptSourceError] with a sentence for the person when it cannot.
class TranscriptSource {
  /// Unique, with the extension in it (`ext:<extension>/<source>`).
  final String id;
  final String title;

  /// One line that says what it takes ("A YouTube link").
  final String hint;
  final Future<Transcript> Function(String input) fetch;
  const TranscriptSource({required this.id, required this.title, this.hint = '', required this.fetch});
}

/// A source could not make the transcript; [message] is for the person.
class TranscriptSourceError implements Exception {
  final String message;
  const TranscriptSourceError(this.message);
  @override
  String toString() => message;
}
