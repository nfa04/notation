import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;

import '../citations/citation_document.dart';
import '../l10n/language.dart';
import '../models/rich_text.dart';
import 'markdown_parser.dart';

/// The written document as a LaTeX file (`article` class) that compiles with the usual packages: headings, lists, tasks, quotes, tables,
/// code (`listings`), formulas as they are written, footnotes, links, citations as they read in the text with the list of sources at the
/// end, and the header and footer of the document. Pictures are put next to it in `figures/`.
class LatexDocument {
  final String tex;

  /// The pictures the file uses, by their path next to it (`figures/1.png`).
  final Map<String, Uint8List> figures;

  const LatexDocument(this.tex, this.figures);

  /// The file, or a ZIP of it and its pictures when it has any.
  ({Uint8List bytes, String extension}) pack(String name) {
    if (figures.isEmpty) return (bytes: Uint8List.fromList(utf8.encode(tex)), extension: 'tex');
    final archive = Archive()..add(ArchiveFile.bytes('$name.tex', utf8.encode(tex)));
    for (final f in figures.entries) {
      archive.add(ArchiveFile.bytes(f.key, f.value));
    }
    return (bytes: Uint8List.fromList(ZipEncoder().encodeBytes(archive)), extension: 'zip');
  }
}

/// [s] as text that LaTeX prints as it is.
String latexText(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    b.write(switch (c) {
      r'\' => r'\textbackslash{}',
      '&' => r'\&',
      '%' => r'\%',
      r'$' => r'\$',
      '#' => r'\#',
      '_' => r'\_',
      '{' => r'\{',
      '}' => r'\}',
      '~' => r'\textasciitilde{}',
      '^' => r'\textasciicircum{}',
      '<' => r'\textless{}',
      '>' => r'\textgreater{}',
      '|' => r'\textbar{}',
      '\u00A0' => '~',
      '\n' => ' ',
      _ => c,
    });
  }
  return b.toString();
}

/// The listings language for a language named after a code fence, or null when listings has no such one.
String? _listingsLanguage(String lang) => switch (lang.toLowerCase()) {
      'python' || 'py' => 'Python',
      'java' => 'Java',
      'c' => 'C',
      'cpp' || 'c++' || 'cc' => 'C++',
      'javascript' || 'js' => 'JavaScript',
      'html' => 'HTML',
      'xml' => 'XML',
      'sql' => 'SQL',
      'bash' || 'sh' || 'shell' => 'bash',
      'haskell' || 'hs' => 'Haskell',
      'tex' || 'latex' => 'TeX',
      'ruby' || 'rb' => 'Ruby',
      'php' => 'PHP',
      'perl' => 'Perl',
      'lisp' => 'Lisp',
      'ocaml' => 'Caml',
      _ => null,
    };

String _anchor(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-');

String _hexColor(int argb) => (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

String _mimeExtension(Uint8List bytes) {
  if (bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) return 'jpg';
  return 'png';
}

/// The document as LaTeX. [text] is its Markdown and [attributes] the formatting picked for its words; [pictures] holds the bytes of each
/// picture by what the text calls it; [title] is put at the top unless the document begins with a heading of that name.
LatexDocument documentLatex(
  String text,
  List<TextSpanAttribute> attributes, {
  String title = '',
  CitationDocument? citations,
  Map<String, Uint8List> pictures = const {},
}) {
  final blocks = parseMarkdown(text);
  final notes = footnoteNumbers(blocks);
  final refs = crossReferences(blocks, figure: tr('Figure'), table: tr('Table'));
  final captions = captionNumbers(blocks);
  final settings = documentSettings(blocks);
  final figures = <String, Uint8List>{};
  final figureNames = <String, String>{};
  final footnoteText = <String, List<MdRun>>{
    for (final b in blocks)
      if (b.type == MdBlockType.footnote) b.label: b.runs,
  };

  String figureFile(String key, Uint8List bytes) => figureNames.putIfAbsent(key, () {
        final name = 'figures/${figureNames.length + 1}.${_mimeExtension(bytes)}';
        figures[name] = bytes;
        return name;
      });

  // packages that not every installation has are only asked for when the document needs them
  var usesColor = false, usesUlem = false, usesAdjust = false, usesEnumitem = false;

  String runs(List<MdRun> list, {bool allowNotes = true}) {
    final b = StringBuffer();
    for (final r in list) {
      if (r.comment || r.deleted) continue;
      if (r.ref != null) {
        final label = latexText(refs[r.ref] ?? r.ref!);
        b.write('\\hyperlink{${_anchor(r.ref!)}}{$label}');
      } else if (r.footnote != null) {
        final body = footnoteText[r.footnote];
        if (body != null && allowNotes) {
          b.write('\\footnote{${runs(body, allowNotes: false)}}');
        } else {
          b.write('\\textsuperscript{${latexText(notes[r.footnote]?.toString() ?? r.footnote!)}}');
        }
      } else if (r.image != null) {
        final bytes = pictures[r.image];
        if (bytes == null) {
          b.write('\\textit{[${latexText(tr('Picture'))}${r.text.isEmpty ? '' : ': ${latexText(r.text)}'}]}');
        } else {
          usesAdjust = true;
          b.write('\\adjustbox{max width=\\linewidth}{\\includegraphics{${figureFile(r.image!, bytes)}}}');
        }
      } else if (r.math) {
        b.write('\$${r.text}\$');
      } else if (r.cite != null && citations != null) {
        b.write(latexText(citations.inText(r.cite!)));
      } else {
        for (final s in segmentsOf(r, attributes)) {
          var t = latexText(s.text);
          if (s.code) {
            t = '\\texttt{$t}';
          }
          if (s.bold) t = '\\textbf{$t}';
          if (s.italic) t = '\\textit{$t}';
          if (s.underline) {
            t = '\\uline{$t}';
            usesUlem = true;
          }
          if (s.strike) {
            t = '\\sout{$t}';
            usesUlem = true;
          }
          if (s.superscript) t = '\\textsuperscript{$t}';
          if (s.subscript) t = '\\textsubscript{$t}';
          if (s.color != null) {
            t = '\\textcolor[HTML]{${_hexColor(s.color!)}}{$t}';
            usesColor = true;
          }
          if (s.highlight || s.highlightColor != null) {
            t = '\\colorbox[HTML]{${_hexColor(s.highlightColor ?? 0xFFFFF176)}}{$t}';
            usesColor = true;
          }
          if (r.link != null && !r.link!.startsWith('note:')) {
            t = '\\href{${r.link!.replaceAll('\\', '').replaceAll('%', r'\%').replaceAll('#', r'\#')}}{$t}';
          }
          b.write(t);
        }
      }
    }
    return b.toString();
  }

  String target(MdBlock b, String body) {
    final id = b.markup.where((m) => m.kind == MdMarkupKind.anchor).firstOrNull?.id;
    return id == null ? body : '\\hypertarget{${_anchor(id)}}{$body}';
  }

  String wrapAligned(MdBlock b, String body) => switch (b.format.align) {
        'center' => '\\begin{center}\n$body\n\\end{center}',
        'right' => '\\begin{flushright}\n$body\n\\end{flushright}',
        _ => body,
      };

  final body = StringBuffer();
  // the lists being written, one entry for each depth (`itemize`, `enumerate`)
  final open = <String>[];
  void closeLists([int keep = 0]) {
    while (open.length > keep) {
      body.writeln('${'  ' * (open.length - 1)}\\end{${open.removeLast()}}');
    }
  }

  var usesCode2 = false;

  for (final b in blocks) {
    final listKind = switch (b.type) { MdBlockType.bullet || MdBlockType.task => 'itemize', MdBlockType.numbered => 'enumerate', _ => null };
    if (listKind == null) {
      closeLists();
    } else {
      final depth = b.depth.clamp(0, 3);
      closeLists(depth + 1);
      // a list of the other kind at this depth: the old one ends and the new one starts
      if (open.length == depth + 1 && open[depth] != listKind) closeLists(depth);
      while (open.length < depth + 1) {
        open.add(listKind);
        final start = listKind == 'enumerate' && open.length == depth + 1 && b.level > 1 ? '[start=${b.level}]' : '';
        if (start.isNotEmpty) usesEnumitem = true;
        body.writeln('${'  ' * (open.length - 1)}\\begin{$listKind}$start');
      }
    }
    final pad = '  ' * (open.length);
    switch (b.type) {
      case MdBlockType.setting || MdBlockType.footnote:
        break;
      case MdBlockType.heading:
        final cmd = switch (b.level) { 1 => 'section', 2 => 'subsection', 3 => 'subsubsection', 4 => 'paragraph', _ => 'subparagraph' };
        body.writeln('\\$cmd{${runs(b.runs)}}');
        final id = b.markup.where((m) => m.kind == MdMarkupKind.anchor).firstOrNull?.id;
        if (id != null) body.writeln('\\hypertarget{${_anchor(id)}}{}');
      case MdBlockType.caption:
        body.writeln(wrapAligned(
            b,
            target(
                b,
                '\\begin{center}\\small\\textit{${latexText(captionPrefix(b, captions, figure: tr('Figure'), table: tr('Table')))}${runs(b.runs)}}\\end{center}')));
      case MdBlockType.paragraph:
        if (b.runs.isEmpty) {
          body.writeln();
        } else {
          final onlyPicture = b.runs.length == 1 && b.runs.single.image != null;
          body.writeln(onlyPicture ? '\\begin{center}\n${runs(b.runs)}\n\\end{center}\n' : '${wrapAligned(b, runs(b.runs))}\n');
        }
      case MdBlockType.bullet || MdBlockType.numbered:
        body.writeln('$pad\\item ${runs(b.runs)}');
      case MdBlockType.task:
        body.writeln('$pad\\item[${b.checked ? r'$\boxtimes$' : r'$\square$'}] ${runs(b.runs)}');
      case MdBlockType.quote:
        body.writeln('\\begin{quote}\n${runs(b.runs)}\n\\end{quote}\n');
      case MdBlockType.rule:
        body.writeln('\\noindent\\rule{\\linewidth}{0.4pt}\n');
      case MdBlockType.pageBreak:
        body.writeln('\\newpage\n');
      case MdBlockType.math:
        body.writeln('\\[\n${b.runs.single.text}\n\\]\n');
      case MdBlockType.code:
        usesCode2 = true;
        final language = _listingsLanguage(b.lang);
        body.writeln('\\begin{lstlisting}${language == null ? '' : '[language=$language]'}\n${b.code.replaceAll(r'\end{lstlisting}', r'\end {lstlisting}')}\n\\end{lstlisting}\n');
      case MdBlockType.table:
        final columns = b.rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
        final spec = [
          for (var c = 0; c < columns; c++)
            switch (c < b.aligns.length ? b.aligns[c] : '') { 'center' => 'c', 'right' => 'r', _ => 'l' },
        ].join('|');
        body.writeln('\\begin{center}\n\\begin{tabular}{|$spec|}\n\\hline');
        for (var r = 0; r < b.rows.length; r++) {
          final cells = [
            for (var c = 0; c < columns; c++)
              c < b.rows[r].length ? (r == 0 ? '\\textbf{${runs(b.rows[r][c])}}' : runs(b.rows[r][c])) : '',
          ];
          body.writeln('${cells.join(' & ')} \\\\ \\hline');
        }
        body.writeln('\\end{tabular}\n\\end{center}\n');
      case MdBlockType.toc:
        body.writeln('\\tableofcontents\n');
      case MdBlockType.bibliography:
        if (citations != null && citations.cited.isNotEmpty) {
          body.writeln('\\section*{${latexText(tr('References'))}}');
          for (final e in citations.bibliography()) {
            body.writeln('\\noindent ${latexText(e)}\\par\\smallskip');
          }
          body.writeln();
        }
    }
  }
  closeLists();

  // header and footer
  String edge(String template) => latexText(template)
      .replaceAll(r'\{page\}', r'\thepage{}')
      .replaceAll(r'\{pages\}', r'\pageref{LastPage}')
      .replaceAll(r'\{title\}', latexText(title))
      .replaceAll(r'\{date\}', r'\today{}');

  final columns = (int.tryParse(settings['columns']?.trim() ?? '') ?? 1).clamp(1, 4);
  final header = settings['header'], footer = settings['footer'];
  final usesLastPage = [header, footer].any((s) => s != null && s.contains('{pages}'));
  final firstHeading = blocks.where((b) => b.type == MdBlockType.heading).firstOrNull;
  final firstHeadingText = firstHeading?.runs.map((r) => r.text).join().trim();
  final showTitle = title.trim().isNotEmpty && firstHeadingText != title.trim();

  final pre = StringBuffer()
    ..writeln('% Written by Notation. Compile with pdflatex, xelatex or lualatex.')
    ..writeln(r'\documentclass[11pt,a4paper]{article}')
    ..writeln(r'\usepackage[T1]{fontenc}')
    ..writeln(r'\usepackage[utf8]{inputenc}')
    ..writeln(r'\usepackage{lmodern}')
    ..writeln(r'\usepackage{amsmath,amssymb}')
    ..writeln(r'\usepackage{graphicx}')
    ..writeln(r'\usepackage{textcomp}')
    ..writeln(r'\usepackage[colorlinks=true,linkcolor=black,urlcolor=blue]{hyperref}');
  if (usesAdjust) pre.writeln(r'\usepackage{adjustbox}');
  if (usesUlem) pre.writeln(r'\usepackage[normalem]{ulem}');
  if (usesEnumitem) pre.writeln(r'\usepackage{enumitem}');
  if (usesColor && !usesCode2) pre.writeln(r'\usepackage{xcolor}');
  if (usesCode2) {
    pre
      ..writeln(r'\usepackage{xcolor}')
      ..writeln(r'\usepackage{listings}')
      ..writeln(r'\lstset{basicstyle=\ttfamily\small,breaklines=true,columns=fullflexible,frame=single,backgroundcolor=\color[gray]{0.96},showstringspaces=false}');
  }
  if (columns > 1) pre.writeln(r'\usepackage{multicol}');
  if (header != null || footer != null) {
    pre
      ..writeln(r'\usepackage{fancyhdr}')
      ..writeln(r'\pagestyle{fancy}')
      ..writeln(r'\fancyhf{}');
    if (usesLastPage) pre.writeln(r'\usepackage{lastpage}');
    if (header != null && header.trim().isNotEmpty) pre.writeln('\\fancyhead[C]{${edge(header)}}');
    if (footer != null && footer.trim().isNotEmpty) pre.writeln('\\fancyfoot[C]{${edge(footer)}}');
  }
  if (showTitle) {
    pre
      ..writeln('\\title{${latexText(title.trim())}}')
      ..writeln(r'\author{}')
      ..writeln(r'\date{}');
  }
  pre
    ..writeln(r'\setlength{\parindent}{0pt}')
    ..writeln(r'\setlength{\parskip}{0.6em}')
    ..writeln(r'\begin{document}');
  if (showTitle) pre.writeln(r'\maketitle');

  final tex = StringBuffer()
    ..write(pre)
    ..writeln(columns > 1 ? '\\begin{multicols}{$columns}' : '')
    ..write(body)
    ..writeln(columns > 1 ? '\\end{multicols}' : '')
    ..writeln(r'\end{document}');
  return LatexDocument(tex.toString(), figures);
}
