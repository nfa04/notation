import 'package:flutter_test/flutter_test.dart';
import 'package:notes/capture/article.dart';

const _page = '''
<!doctype html>
<html><head>
<title>How plants breathe | The Science Blog</title>
<meta property="og:site_name" content="The Science Blog">
<style>body { color: red }</style>
<script>var tracking = 1;</script>
</head>
<body>
<header><a href="/">Home</a> <a href="/about">About</a></header>
<nav class="main-nav"><ul><li><a href="/a">Menu entry that must go</a></li></ul></nav>
<div class="cookie-banner">We use cookies. Accept?</div>
<article>
  <h1>How plants breathe</h1>
  <p>Plants take in <strong>carbon dioxide</strong> through tiny pores called <em>stomata</em>, as described in <a href="/guide/stomata">this guide</a> and <a href="https://example.org/x?a=1">another page</a>.</p>
  <h2>The details</h2>
  <p>Each stoma is opened and closed by two guard cells. The cells swell with water and the pore opens, which lets gases pass in and out of the leaf.</p>
  <ul><li>Light opens them</li><li>Drought closes them<ul><li>to save water</li></ul></li></ul>
  <ol><li>First</li><li>Second</li></ol>
  <blockquote><p>Nothing in biology makes sense except in the light of evolution.</p></blockquote>
  <pre>print("hello")</pre>
  <table><tr><th>Gas</th><th>Direction</th></tr><tr><td>CO2</td><td>in</td></tr></table>
  <p>Enough words follow here to make this paragraph clearly the main text of the page, so that the extractor keeps it.</p>
</article>
<aside class="sidebar"><p>Related: ten things you did not know about moss.</p></aside>
<div class="comments"><p>Great post! Click here for a free phone.</p></div>
<footer>Copyright 2026</footer>
</body></html>
''';

void main() {
  test('the title loses the name of the site, the text keeps its structure and links are made absolute', () {
    final a = extractArticle(_page, url: Uri.parse('https://blog.example.com/posts/plants'))!;
    expect(a.title, 'How plants breathe');
    expect(a.source, 'The Science Blog');
    final md = a.markdown;
    expect(md, contains('Plants take in **carbon dioxide** through tiny pores called *stomata*'));
    expect(md, contains('[this guide](https://blog.example.com/guide/stomata)'));
    expect(md, contains('[another page](https://example.org/x?a=1)'));
    expect(md, contains('## The details'));
    expect(md, contains('- Light opens them'));
    expect(md, contains('- Drought closes them\n  - to save water'));
    expect(md, contains('1. First\n2. Second'));
    expect(md, contains('> Nothing in biology makes sense except in the light of evolution.'));
    expect(md, contains('```\nprint("hello")\n```'));
    expect(md, contains('| Gas | Direction |\n| --- | --- |\n| CO2 | in |'));
  });

  test('navigation, cookies, sidebars, comments, scripts and footers are not in it; the title is not repeated as a heading', () {
    final md = extractArticle(_page)!.markdown;
    for (final noise in ['Menu entry', 'cookies', 'moss', 'free phone', 'Copyright', 'tracking', 'color: red', 'Home']) {
      expect(md, isNot(contains(noise)), reason: noise);
    }
    expect(md.startsWith('# How plants breathe'), isFalse);
  });

  test('without an <article> the block with the most paragraph text is taken', () {
    const page = '''
<html><head><title>Plain page</title></head><body>
<div id="top"><a href="/1">one</a> <a href="/2">two</a> <a href="/3">three</a></div>
<div id="content">
  <p>The first paragraph of a page that has no article element, long enough to count as text and not as a menu entry.</p>
  <p>The second paragraph goes on in the same way, so this block is the one with the most text in the page by far.</p>
</div>
<div id="links"><a href="/x">a link</a> <a href="/y">another link</a></div>
</body></html>''';
    final a = extractArticle(page)!;
    expect(a.title, 'Plain page');
    expect(a.markdown, contains('The first paragraph'));
    expect(a.markdown, contains('The second paragraph'));
    expect(a.markdown, isNot(contains('another link')));
  });

  test('the title can come from og:title, and a page with no text gives nothing', () {
    final a = extractArticle('<html><head><meta property="og:title" content="Shared title"><title>x</title></head><body><p>${'word ' * 30}</p></body></html>')!;
    expect(a.title, 'Shared title');
    expect(extractArticle('<html><body><p>hi</p></body></html>'), isNull);
    expect(extractArticle(''), isNull);
  });

  test('a very long page is cut', () {
    final long = '<html><body><article>${'<p>${'lorem ipsum ' * 50}</p>' * 200}</article></body></html>';
    final a = extractArticle(long, maxChars: 2000)!;
    expect(a.markdown.length, lessThan(2100));
    expect(a.markdown.endsWith('...'), isTrue);
  });

  test('links that are not web links are only their words', () {
    final md = extractArticle('<html><body><article><p>See <a href="javascript:void(0)">this</a>, <a href="#top">that</a> and <a href="mailto:a@b.c">mail</a>. ${'filler text ' * 12}</p></article></body></html>')!.markdown;
    expect(md, contains('See this, that and [mail](mailto:a@b.c).'));
  });
}
