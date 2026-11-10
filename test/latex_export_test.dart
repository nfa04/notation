import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/markdown/latex_export.dart';

/// A picture of one red pixel.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==');

const _document = r'''[header]: {title}
[footer]: Page {page}

# Notes on sorting

A paragraph with **bold**, *italic*, `code_in_text`, ~~struck~~, a [link](https://example.org/a_b?x=1&y=2#top) and the signs & % $ # _ { } ~ ^ \ < >.
Inline maths $O(n \log n)$ and a footnote[^1].

$$\sum_{k=1}^{n} k = \frac{n(n+1)}{2}$$

## Lists

- first
  - nested
- second
1. one
2. two
- [ ] open
- [x] done

> a quote

| Algorithm | Time | Space |
|:--|:-:|--:|
| Quick | n log n | log n |
| Merge | n log n | n |

```python
def f(x):
    return x % 2
```

![a red pixel](image:pixel.png)

Figure: the pixel {#fig:pixel}

See {@fig:pixel}.

---

\pagebreak

[^1]: The footnote text with 50% & more.
''';

void main() {
  group('the document as LaTeX', () {
    test('the parts of a document', () {
      final doc = documentLatex(_document, const [], title: 'Sorting', pictures: {'image:pixel.png': _png});
      final tex = doc.tex;
      expect(tex, contains(r'\documentclass'));
      expect(tex, contains(r'\section{Notes on sorting}'));
      expect(tex, contains(r'\subsection{Lists}'));
      expect(tex, contains(r'\textbf{bold}'));
      expect(tex, contains(r'\textit{italic}'));
      expect(tex, contains(r'\texttt{code\_in\_text}'));
      expect(tex, contains(r'\sout{struck}'));
      expect(tex, contains(r'\href{https://example.org/a_b?x=1&y=2\#top}{link}'));
      expect(tex, contains(r'\& \% \$ \# \_ \{ \} \textasciitilde{} \textasciicircum{} \textbackslash{} \textless{} \textgreater{}'));
      expect(tex, contains(r'$O(n \log n)$'));
      expect(tex, contains('\\[\n\\sum_{k=1}^{n} k = \\frac{n(n+1)}{2}\n\\]'));
      expect(tex, contains(r'\footnote{The footnote text with 50\% \& more.}'));
      expect(tex, contains(r'\begin{itemize}'));
      expect(tex, contains(r'\item[$\boxtimes$] done'));
      expect(tex, contains(r'\item[$\square$] open'));
      expect(tex, contains(r'\begin{enumerate}'));
      expect(tex, contains(r'\begin{quote}'));
      expect(tex, contains(r'\begin{tabular}{|l|c|r|}'));
      expect(tex, contains(r'\textbf{Algorithm} & \textbf{Time} & \textbf{Space}'));
      expect(tex, contains(r'\begin{lstlisting}[language=Python]'));
      expect(tex, contains(r'\newpage'));
      expect(tex, contains(r'\hyperlink{fig-pixel}{Figure 1}'));
      expect(tex, contains(r'\fancyhead[C]{Sorting}'));
      expect(tex, contains(r'\fancyfoot[C]{Page \thepage{}}'));
      expect(tex, contains(r'\title{Sorting}'));
      expect(doc.figures.keys, ['figures/1.png']);
      expect(tex, contains('figures/1.png'));
    });

    test('nesting of lists is closed in order', () {
      final tex = documentLatex('- a\n  - b\n- c\n\ntext', const []).tex;
      final begins = RegExp(r'\\begin\{itemize\}').allMatches(tex).length;
      final ends = RegExp(r'\\end\{itemize\}').allMatches(tex).length;
      expect(begins, 2);
      expect(ends, 2);
      expect(tex.indexOf(r'\item b') < tex.indexOf(r'\item c'), isTrue);
    });

    test('a numbered list keeps its first number', () {
      expect(documentLatex('3. three\n4. four', const []).tex, contains(r'\begin{enumerate}[start=3]'));
    });

    test('the title is left out when the document starts with it', () {
      expect(documentLatex('# Sorting\n\ntext', const [], title: 'Sorting').tex, isNot(contains(r'\maketitle')));
      expect(documentLatex('text', const [], title: 'Sorting').tex, contains(r'\maketitle'));
    });

    test('a picture that is not there is named in italics; one that is goes into a ZIP', () {
      expect(documentLatex('![a cat](image:cat.png)', const []).tex, contains(r'\textit{[Picture: a cat]}'));
      final packed = documentLatex('![a cat](image:cat.png)', const [], pictures: {'image:cat.png': _png}).pack('Cats');
      expect(packed.extension, 'zip');
      final names = ZipDecoder().decodeBytes(packed.bytes).files.map((f) => f.name).toList()..sort();
      expect(names, ['Cats.tex', 'figures/1.png']);
      expect(documentLatex('plain', const []).pack('x').extension, 'tex');
    });

    test('latexText', () {
      expect(latexText('50% of a_b & c'), r'50\% of a\_b \& c');
      expect(latexText('a\nb'), 'a b');
    });

    // (a check of the output with a real TeX, on a computer that has one: the app itself never runs a program)
    final haveLatex = () {
      try {
        return Process.runSync('pdflatex', ['--version']).exitCode == 0;
      } catch (_) {
        return false;
      }
    }();
    test('it compiles with pdflatex', () async {
      final dir = Directory.systemTemp.createTempSync('latex_export');
      try {
        // (ulem and lastpage are left out: a minimal TeX installation does not have them)
        final doc = documentLatex(_document.replaceAll('~~struck~~', 'struck'), const [], title: 'Sorting', pictures: {'image:pixel.png': Uint8List.fromList(_png)});
        File('${dir.path}/doc.tex').writeAsStringSync(doc.tex);
        for (final f in doc.figures.entries) {
          File('${dir.path}/${f.key}')
            ..createSync(recursive: true)
            ..writeAsBytesSync(f.value);
        }
        // (twice: the page count and the contents settle on the second run)
        late ProcessResult r;
        for (var i = 0; i < 2; i++) {
          r = await Process.run('pdflatex', ['-interaction=nonstopmode', '-halt-on-error', 'doc.tex'], workingDirectory: dir.path);
        }
        expect(r.exitCode, 0, reason: '${r.stdout}'.split('\n').where((l) => l.startsWith('!') || l.startsWith('l.')).join('\n'));
        expect(File('${dir.path}/doc.pdf').existsSync(), isTrue);
      } finally {
        dir.deleteSync(recursive: true);
      }
    }, skip: haveLatex ? false : 'pdflatex is not installed');
  });
}
