/// Merge a vector overlay PDF onto an existing PDF without rewriting it.
///
/// ```dart
/// final merged = mergeOverlay(originalBytes, overlayBytes);
/// ```
library;

export 'src/comment.dart' show PdfComment;
export 'src/merger.dart' show mergeOverlay;
export 'src/objects.dart' show UnsupportedPdfException;
