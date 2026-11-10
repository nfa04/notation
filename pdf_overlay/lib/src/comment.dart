/// A comment on a PDF: a highlighted piece of text with a note, which viewers
/// show as a comment (Acrobat's "Highlight Text with a note").
class PdfComment {
  /// The page it is on, counted from 0.
  final int page;

  /// The marked areas (a line of text each): left, top, right, bottom in points
  /// of the page as it is displayed (after /Rotate and /CropBox), from the top left.
  final List<List<double>> rects;

  /// The colour of the mark, each of red, green and blue from 0 to 1, and how
  /// strongly it shows (0 to 1).
  final List<double> color;
  final double opacity;

  /// What was said, and who said it (either may be empty).
  final String contents;
  final String author;

  const PdfComment({
    required this.page,
    required this.rects,
    this.color = const [0.25, 0.45, 1.0],
    this.opacity = 0.3,
    this.contents = '',
    this.author = '',
  });
}
