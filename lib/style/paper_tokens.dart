/// The measures of the paper look, in one place: screens take their gaps from here instead of typing numbers, so the rhythm is the
/// same everywhere and a change is made once.
abstract final class Paper {
  /// Gaps: between an icon and its text, between lines of a group, between groups, between sections.
  static const double gapS = 4;
  static const double gapM = 8;
  static const double gapL = 16;
  static const double gapXL = 24;

  /// The side margin of a page on a phone and elsewhere.
  static const double marginPhone = 16;
  static const double margin = 24;

  /// Corners: fields, buttons and chips; note pages and menus.
  static const double radius = 6;
  static const double radiusPage = 8;

  /// The height of a ruled row.
  static const double rowHeight = 48;
}
