import 'extension_host.dart';

/// The most text one reading of a PDF gives back.
const pdfReadLimit = 12000;

/// The pages [from] to [to] (from 1; default: the first, and as many as fit in [limit] characters) of a PDF whose page texts are
/// [pages], each under "Page N:". A page with no text says so (a scan or a picture has none). When the pages asked for do not fit, it
/// stops after the last that does and says where to go on. Fails with [ExtensionError] when the pages are not there.
String readPdfPages(List<String> pages, {int? from, int? to, int limit = pdfReadLimit}) {
  if (pages.isEmpty) throw ExtensionError('This PDF has no pages.');
  final first = from ?? 1;
  final last = to ?? pages.length;
  if (first < 1 || first > pages.length) throw ExtensionError('There is no page $first: the PDF has ${pages.length} pages.');
  if (last < first) throw ExtensionError('"to" is before "from".');
  final end = last > pages.length ? pages.length : last;
  final out = StringBuffer('The PDF has ${pages.length} pages.');
  for (var i = first; i <= end; i++) {
    final text = pages[i - 1].trim();
    final block = '\n\nPage $i:\n${text.isEmpty ? '(no text on this page: a scan, or only pictures)' : text}';
    if (out.length + block.length > limit && i > first) {
      out.write('\n\n(Stopped before page $i because of the length. Read on with "from": $i.)');
      return out.toString();
    }
    if (out.length + block.length > limit) {
      // (one page alone is longer than the limit: its start)
      out.write(block.substring(0, limit - out.length));
      out.write('\n\n(Page $i goes on: it is cut here. Read on with "from": ${i + 1}.)');
      return out.toString();
    }
    out.write(block);
  }
  if (end < last) out.write('\n\n(The PDF ends at page ${pages.length}.)');
  return out.toString();
}

/// The pages of a PDF that have all the words of [query]: `page` (from 1) and a `snippet` around the first word, at most [limit].
List<Map<String, Object?>> searchPdfPages(List<String> pages, String query, {int limit = 20}) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) throw ExtensionError('"query" is empty.');
  final found = <Map<String, Object?>>[];
  for (var i = 0; i < pages.length && found.length < limit; i++) {
    final low = pages[i].toLowerCase();
    if (words.any((w) => !low.contains(w))) continue;
    final at = low.indexOf(words.first);
    final text = pages[i];
    found.add({'page': i + 1, 'snippet': text.substring((at - 60).clamp(0, text.length), (at + words.first.length + 100).clamp(0, text.length)).replaceAll(RegExp(r'\s+'), ' ').trim()});
  }
  return found;
}
