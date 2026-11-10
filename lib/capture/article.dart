import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

/// The readable part of a web page.
class Article {
  final String title;

  /// The name of the site or the author, when the page says.
  final String? source;

  /// The text as Markdown: headings, paragraphs, lists, links, quotes and code.
  final String markdown;

  const Article({required this.title, this.source, required this.markdown});
}

/// Page parts that are not the article: navigation, ads, forms, comments. Matched against the `class` and `id` of an element.
final _noise = RegExp(r'(^|[-_\s])(nav|navbar|menu|sidebar|footer|header|advert|ads?|promo|cookie|consent|banner|share|social|related|subscribe|newsletter|comment|comments|popup|modal|breadcrumb|toolbar|skip)([-_\s]|$)', caseSensitive: false);
const _dropTags = {'script', 'style', 'noscript', 'nav', 'aside', 'form', 'iframe', 'svg', 'template', 'button', 'select', 'input', 'textarea', 'dialog', 'canvas', 'audio', 'video', 'object', 'embed', 'head'};

String _text(Node n) => n.text?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';

bool _isNoise(Element e) {
  if (_dropTags.contains(e.localName)) return true;
  if (e.attributes.containsKey('hidden') || e.attributes['aria-hidden'] == 'true') return true;
  if (e.localName == 'footer' || e.localName == 'header') return true;
  final role = e.attributes['role'];
  if (role == 'navigation' || role == 'banner' || role == 'contentinfo' || role == 'complementary' || role == 'search') return true;
  final marks = '${e.className} ${e.id}';
  return marks.trim().isNotEmpty && _noise.hasMatch(marks) && !{'article', 'main', 'body', 'html'}.contains(e.localName);
}

/// How much article-like text an element holds directly: paragraph text counts, a lot of link text takes away.
double _score(Element e) {
  var text = 0.0, links = 0.0;
  void walk(Element x) {
    for (final c in x.children) {
      if (_isNoise(c)) continue;
      if (c.localName == 'p' || c.localName == 'li' || c.localName == 'pre' || c.localName == 'blockquote') {
        final t = _text(c).length;
        text += t;
        for (final a in c.querySelectorAll('a')) {
          links += _text(a).length;
        }
      } else {
        walk(c);
      }
    }
  }

  walk(e);
  return text - 2 * links;
}

/// The article of a page: its title and its main text as Markdown, without navigation and the like; null when the page has no
/// text worth keeping. [url] is used to make links absolute.
Article? extractArticle(String source, {Uri? url, int maxChars = 80000}) {
  final doc = html.parse(source);
  String? meta(String key) {
    for (final m in doc.querySelectorAll('meta')) {
      if (m.attributes['property'] == key || m.attributes['name'] == key) {
        final c = m.attributes['content']?.trim();
        if (c != null && c.isNotEmpty) return c;
      }
    }
    return null;
  }

  var title = meta('og:title') ?? meta('twitter:title') ?? _text(doc.querySelector('title') ?? Element.tag('title'));
  final site = meta('og:site_name') ?? meta('author') ?? meta('article:author');
  if (title.isEmpty) title = _text(doc.querySelector('h1') ?? Element.tag('h1'));
  // "Article name | Site name": the site is not part of the title
  if (site != null) {
    for (final sep in [' | ', ' - ', ' – ', ' — ', ' · ']) {
      if (title.endsWith('$sep$site')) title = title.substring(0, title.length - sep.length - site.length);
    }
  }

  final body = doc.body;
  if (body == null) return null;
  // the container with the most article text: the page's own <article> or <main> if it has enough, else the best block
  Element? best;
  for (final tag in ['article', 'main']) {
    final found = doc.querySelectorAll(tag).where((e) => !_isNoise(e));
    for (final e in found) {
      if (best == null || _score(e) > _score(best)) best = e;
    }
    if (best != null && _score(best) > 400) break;
  }
  if (best == null || _score(best) < 200) {
    for (final e in doc.querySelectorAll('div, section, td')) {
      if (_isNoise(e)) continue;
      if (best == null || _score(e) > _score(best)) best = e;
    }
  }
  best ??= body;
  if (_score(best) < 80 && _score(body) > _score(best)) best = body;

  final out = StringBuffer();
  _blocks(best, out, url);
  var markdown = out.toString().replaceAll(RegExp(r'[ \t]+\n'), '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  if (markdown.length < 40) return null;
  if (markdown.length > maxChars) markdown = '${markdown.substring(0, maxChars).trimRight()}\n\n...';
  // the title again as the first heading is not repeated
  final first = RegExp(r'^#{1,6}\s+(.+)$', multiLine: true).firstMatch(markdown);
  if (first != null && first.start == 0 && first.group(1)!.trim().toLowerCase() == title.toLowerCase()) {
    markdown = markdown.substring(first.end).trimLeft();
  }
  return Article(title: title.isEmpty ? (url?.host ?? '') : title, source: site, markdown: markdown);
}

String _inline(Node n, Uri? base) {
  if (n is Text) return n.text.replaceAll(RegExp(r'\s+'), ' ');
  if (n is! Element || _isNoise(n)) return '';
  String inner() => n.nodes.map((c) => _inline(c, base)).join();
  switch (n.localName) {
    case 'br':
      return '\n';
    case 'strong':
    case 'b':
      final t = inner().trim();
      return t.isEmpty ? '' : '**$t**';
    case 'em':
    case 'i':
      final t = inner().trim();
      return t.isEmpty ? '' : '*$t*';
    case 'code':
      final t = n.text.trim();
      return t.isEmpty ? '' : '`$t`';
    case 'a':
      final label = inner().trim();
      final href = n.attributes['href']?.trim();
      if (label.isEmpty) return '';
      if (href == null || href.isEmpty || href.startsWith('#') || href.startsWith('javascript:')) return label;
      final resolved = base == null ? Uri.tryParse(href) : base.resolve(href);
      if (resolved == null || !(resolved.scheme == 'http' || resolved.scheme == 'https' || resolved.scheme == 'mailto')) return label;
      return '[$label](${resolved.toString().replaceAll(' ', '%20').replaceAll(')', '%29')})';
    case 'img':
      return '';
    default:
      return inner();
  }
}

void _blocks(Element e, StringBuffer out, Uri? base, {String indent = ''}) {
  for (final c in e.nodes) {
    if (c is Text) {
      final t = c.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t.isNotEmpty) out.write('$indent$t\n\n');
      continue;
    }
    if (c is! Element || _isNoise(c)) continue;
    switch (c.localName) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final t = _inline(c, base).replaceAll('\n', ' ').trim();
        if (t.isNotEmpty) out.write('$indent${'#' * int.parse(c.localName!.substring(1))} $t\n\n');
      case 'p':
        final t = _inline(c, base).trim();
        if (t.isNotEmpty) out.write('$indent$t\n\n');
      case 'ul':
      case 'ol':
        var n = 0;
        for (final li in c.children.where((x) => x.localName == 'li')) {
          n++;
          final mark = c.localName == 'ol' ? '$n.' : '-';
          // a list inside the item is its own block, indented
          final inner = StringBuffer();
          final nested = li.children.where((x) => x.localName == 'ul' || x.localName == 'ol').toList();
          final copy = li.clone(true);
          for (final x in copy.children.where((x) => x.localName == 'ul' || x.localName == 'ol').toList()) {
            x.remove();
          }
          final t = _inline(copy, base).trim().replaceAll(RegExp(r'\n+'), ' ');
          if (t.isNotEmpty) inner.write('$indent$mark $t\n');
          for (final sub in nested) {
            final subOut = StringBuffer();
            _blocks(Element.tag('div')..append(sub.clone(true)), subOut, base, indent: '$indent  ');
            inner.write(subOut.toString().replaceAll(RegExp(r'\n\n(?=\s*(-|\d+\.) )'), '\n').trimRight());
            inner.write('\n');
          }
          out.write(inner);
        }
        out.write('\n');
      case 'blockquote':
        final inner = StringBuffer();
        _blocks(c, inner, base);
        final t = inner.toString().trim();
        if (t.isNotEmpty) out.write('${t.split('\n').map((l) => l.isEmpty ? '>' : '> $l').join('\n')}\n\n');
      case 'pre':
        final t = c.text.trimRight();
        if (t.trim().isNotEmpty) out.write('```\n$t\n```\n\n');
      case 'hr':
        out.write('---\n\n');
      case 'table':
        final rows = [for (final r in c.querySelectorAll('tr')) [for (final cell in r.children.where((x) => x.localName == 'td' || x.localName == 'th')) _inline(cell, base).replaceAll('|', '/').replaceAll('\n', ' ').trim()]]
            .where((r) => r.isNotEmpty)
            .toList();
        if (rows.isNotEmpty) {
          final width = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
          String line(List<String> r) => '| ${[...r, for (var i = r.length; i < width; i++) ''].join(' | ')} |';
          out.write('${line(rows.first)}\n| ${List.filled(width, '---').join(' | ')} |\n');
          for (final r in rows.skip(1)) {
            out.write('${line(r)}\n');
          }
          out.write('\n');
        }
      case 'figure':
        final caption = c.querySelector('figcaption');
        if (caption != null && _text(caption).isNotEmpty) out.write('*${_text(caption)}*\n\n');
      case 'div':
      case 'section':
      case 'article':
      case 'main':
      case 'span':
      case 'body':
      case 'details':
      case 'dl':
      case 'dd':
      case 'dt':
        // a block of text with inline things in it is a paragraph; one with blocks in it is walked
        final hasBlocks = c.children.any((x) => const {'p', 'div', 'section', 'ul', 'ol', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'blockquote', 'pre', 'table', 'article', 'figure'}.contains(x.localName));
        if (hasBlocks) {
          _blocks(c, out, base, indent: indent);
        } else {
          final t = _inline(c, base).trim();
          if (t.isNotEmpty) out.write('$indent$t\n\n');
        }
      default:
        final t = _inline(c, base).trim();
        if (t.isNotEmpty) out.write('$indent$t\n\n');
    }
  }
}
