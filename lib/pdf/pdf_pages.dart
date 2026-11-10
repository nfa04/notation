import 'dart:io';
import 'dart:ui' show Size;

import 'package:path/path.dart' as p;

import '../data/file_digest.dart';
import 'pdf_content_editor.dart';

/// Which pages a PDF has after pages were moved, added or deleted: [order] is the new list, each the number of the page it was (zero-based,
/// at most once; the pages left out are gone), or null for a new blank page of [blank] points. [from] is how many pages the PDF had
/// before, to know it is the same PDF it is done on.
class PageArrangement {
  final List<int?> order;
  final int from;
  final Size blank;

  const PageArrangement(this.order, this.from, this.blank);

  Map<String, Object?> toJson() => {'o': [for (final i in order) i ?? -1], 'from': from, 'w': blank.width, 'h': blank.height};

  /// The most pages an arrangement may have, and the biggest side a new page may have (PDF allows 200 inches): what a peer sends beyond
  /// that is not an arrangement.
  static const maxPages = 100000;
  static const maxSide = 14400.0;

  /// The arrangement [json] says, or null when it is not one that can be done to a PDF of the pages it says: every number a whole one,
  /// each page there is used at most once, and at least one page left.
  static PageArrangement? fromJson(Object? json) {
    if (json is! Map) return null;
    final order = json['o'], from = json['from'], w = json['w'], h = json['h'];
    if (order is! List || from is! int || w is! num || h is! num) return null;
    if (order.isEmpty || order.length > maxPages || from < 1 || from > maxPages) return null;
    if (!(w > 0 && w <= maxSide && h > 0 && h <= maxSide)) return null; // (NaN fails both)
    final list = <int?>[];
    final seen = <int>{};
    for (final i in order) {
      if (i is! int) return null;
      if (i < 0) {
        list.add(null);
        continue;
      }
      if (i >= from || !seen.add(i)) return null;
      list.add(i);
    }
    return PageArrangement(list, from, Size(w.toDouble(), h.toDouble()));
  }
}

/// Writes a copy of the PDF at [path] with its pages as [order] says (see [PageArrangement]), next to it as [fileName]; the new blank
/// pages are as big as [blank], or as page [blankLike] when that is null. Gives the file, what it holds, and the size the new pages got.
Future<({String path, String sha256, int pages, Size blank})> arrangePdfFile(
  String path,
  List<int?> order, {
  required String fileName,
  int blankLike = 0,
  Size? blank,
}) async {
  final editor = await PdfContentEditor.open(await File(path).readAsBytes());
  try {
    final size = blank ?? await editor.pageSize(blankLike);
    await editor.arrange(order, size);
    final bytes = await editor.save();
    final out = p.join(p.dirname(path), fileName);
    await File(out).writeAsBytes(bytes, flush: true);
    return (path: out, sha256: await sha256OfFile(out), pages: order.length, blank: size);
  } finally {
    await editor.close().catchError((Object _) {});
  }
}
