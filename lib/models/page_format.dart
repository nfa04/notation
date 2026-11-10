/// Paper sizes offered for the blank notebook (imported PDFs keep their own).
/// A page has the size of the paper: the editor lays it out in units of 800 for the width of an A4 sheet, so an A5 sheet is narrower
/// and an A3 one wider (and the height follows).
enum PageFormat {
  a4('A4', 297 / 210, 210),
  a5('A5', 210 / 148, 148),
  a3('A3', 420 / 297, 297),
  b5('B5', 250 / 176, 176),
  letter('Letter', 11 / 8.5, 215.9),
  legal('Legal', 14 / 8.5, 215.9),
  square('Square', 1, 210),

  /// Not a sheet at all: one surface to draw and write on that goes on in every direction (see `canvas_view.dart`). Its page is
  /// the surface; it cannot be cut into pages, so it has no paper size and is not offered in the list of sizes.
  infinite('Infinite canvas', 1, 210);

  final String label;

  /// Height divided by width when upright.
  final double ratio;

  /// The width of the paper in millimetres when upright.
  final double widthMm;

  const PageFormat(this.label, this.ratio, this.widthMm);

  bool get isInfinite => this == infinite;

  /// The sizes of paper there are to choose from.
  static List<PageFormat> get papers => [for (final f in values) if (!f.isInfinite) f];

  /// The units a page of A4 width is across in the editor's page space.
  static const double a4Units = 800;

  /// The width of the page in the editor's page space (a sheet of A4 upright is [a4Units]).
  double widthUnits({required bool landscape}) => a4Units * (landscape ? widthMm * ratio : widthMm) / 210;

  /// Height divided by width, turned on its side if [landscape].
  double aspect({required bool landscape}) => landscape ? 1 / ratio : ratio;
}
