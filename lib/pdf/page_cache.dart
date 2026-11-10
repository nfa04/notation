/// What the pages of a PDF that are kept in memory may take together (the rendered pages, 4 bytes a pixel: 24 MB for one at 250 dpi).
/// A PDF of scans is a lot of pages: a long read through one would otherwise keep every page it passed, and a phone runs out of
/// memory before the end. A page that is let go of is rendered again in 10 to 100 ms when it is asked for.
///
/// This holds the page in view with the five ahead of it and the two behind (what is read ahead), so that those do not go right
/// after they were read.
const int pageCacheBudget = 208 << 20;

/// The pages next to the one in view always stay, whatever they take: they are on screen, or about to be.
const int pagesKeptAround = 3;

/// Which of the kept pages to let go of so that the rest fit in [budget]: the ones farthest from page [near] first, never one within
/// [keep] pages of it. [sizes] is what each kept page takes.
List<int> pagesToDrop(Map<int, int> sizes, {required int near, int keep = pagesKeptAround, int budget = pageCacheBudget}) {
  var total = 0;
  for (final size in sizes.values) {
    total += size;
  }
  if (total <= budget) return const [];
  final far = [for (final page in sizes.keys) if ((page - near).abs() > keep) page]
    ..sort((a, b) {
      final byDistance = (b - near).abs().compareTo((a - near).abs());
      return byDistance != 0 ? byDistance : b.compareTo(a); // (behind the page in view before ahead of it, at the same distance: reading goes forward)
    });
  final drop = <int>[];
  for (final page in far) {
    if (total <= budget) break;
    total -= sizes[page]!;
    drop.add(page);
  }
  return drop;
}
