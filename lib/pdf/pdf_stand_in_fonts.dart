import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'pdf_content_editor.dart';

/// The fonts that stand in for a PDF's own: Liberation Sans, Serif and Mono match the widths of Arial/Helvetica, Times and
/// Courier, the fonts PDFs most often use or name, so text set in them takes the room of the text it replaces.
const _files = {'sans': 'LiberationSans', 'serif': 'LiberationSerif', 'mono': 'LiberationMono'};
const _styles = {'': 'Regular', '-bold': 'Bold', '-italic': 'Italic', '-bolditalic': 'BoldItalic'};

Map<String, Uint8List>? _loaded;

/// The font with the symbols (arrows, maths, signs, pictographs) the others lack, in the same four looks.
const _symbolsFiles = {'': 'DejaVuSans', '-bold': 'DejaVuSans-Bold', '-italic': 'DejaVuSans-Oblique', '-bolditalic': 'DejaVuSans-BoldOblique'};

/// The stand-in fonts' files by [PdfFontInfo.key], for the PDF editor to set text in when the PDF's own font lacks the characters.
Future<Map<String, Uint8List>> loadStandInFonts() async => _loaded ??= {
      for (final MapEntry(key: kind, value: file) in _files.entries)
        for (final MapEntry(key: suffix, value: style) in _styles.entries)
          '$kind$suffix': (await rootBundle.load('assets/fonts/$file-$style.ttf')).buffer.asUint8List(),
      for (final MapEntry(key: suffix, value: file) in _symbolsFiles.entries)
        'symbols$suffix': (await rootBundle.load('assets/fonts/$file.ttf')).buffer.asUint8List(),
    };

/// The names a PDF font may be installed under: "BAAAAA+LiberationSerif-Bold" is "LiberationSerif" or "Liberation Serif".
List<String> systemFamilyNames(PdfFontInfo info) {
  final base = info.name.replaceFirst(RegExp(r'^[A-Z]{6}\+'), '').split(RegExp(r'[-,]')).first.trim();
  if (base.isEmpty) return const [];
  // (a name made of words: split before the last one ("DejaVu Sans"), or before every one ("Liberation Serif"))
  final lastWord = base.replaceFirstMapped(RegExp(r'(?<=[a-z0-9])(?=[A-Z][a-z0-9]*$)'), (_) => ' ');
  final everyWord = base.replaceAllMapped(RegExp(r'(?<=[a-z0-9])(?=[A-Z])'), (_) => ' ');
  return {base, lastWord, everyWord}.toList();
}

final _installed = <String, bool>{};

/// Whether the font the PDF names is installed on this device (so that the text can be set in the very font of the PDF): naming it
/// changes how a text lays out, where naming a font that is not there does not.
bool systemFontInstalled(PdfFontInfo info) {
  final names = systemFamilyNames(info);
  if (names.isEmpty) return false;
  return _installed.putIfAbsent(names.first, () {
    double width(String? family, List<String> fallback) {
      final painter = TextPainter(
        text: TextSpan(text: 'Hamburgefonstiv Qxz 0123 ∑', style: TextStyle(fontSize: 40, fontFamily: family, fontFamilyFallback: fallback)),
        textDirection: TextDirection.ltr,
      )..layout();
      final w = painter.width;
      painter.dispose();
      return w;
    }

    final missing = width('NoSuchFontForThePdfEditor', const []);
    return (width(names.first, names.skip(1).toList()) - missing).abs() > 0.5;
  });
}

/// How text looks in the stand-in for [info]'s font; [family] ("sans", "serif", "mono", "dejavu") overrides the kind. What the
/// stand-in lacks (symbols) comes from DejaVu Sans.
TextStyle standInStyle(PdfFontInfo info, {String? family}) {
  final kind = family ?? (info.mono ? 'mono' : (info.serif ? 'serif' : 'sans'));
  final names = kind == 'system' ? systemFamilyNames(info) : const <String>[];
  return TextStyle(
    color: Colors.black,
    fontFamily: kind == 'system' && names.isNotEmpty
        ? names.first
        : switch (kind) { 'mono' => 'LiberationMono', 'serif' => 'LiberationSerif', 'dejavu' => 'DejaVuSans', _ => 'LiberationSans' },
    fontFamilyFallback: [...names.skip(1), 'LiberationSerif', 'DejaVuSans'],
    fontWeight: info.bold ? FontWeight.bold : FontWeight.normal,
    fontStyle: info.italic ? FontStyle.italic : FontStyle.normal,
  );
}

/// The stand-in for [line] and how much to scale it so that the text takes the room it takes in the PDF: the kind the font says
/// it is, unless another kind (sans or serif) fits clearly better, and a size that makes the widths equal (within limits; [minFactor]
/// is how small it may get).
({String family, double factor, TextStyle style}) fitStandIn(PdfEditObject line, PdfFontInfo info, {double minFactor = 0.85}) {
  final text = line.text ?? '';
  final size = line.fontSize ?? 12;
  double ratioOf(String family) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: standInStyle(info, family: family).copyWith(fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width <= 0 ? 1 : line.rect.width / painter.width;
  }

  final named = systemFontInstalled(info) ? 'system' : (info.mono ? 'mono' : (info.serif ? 'serif' : 'sans'));
  var family = named;
  var ratio = ratioOf(named);
  // (the PDF's own font, where it is installed, is not second-guessed)
  if (named != 'system' && !info.mono && text.trim().length > 3) {
    // (a font that says nothing of itself, as symbol fonts do, may be a serif or a wide sans: the width tells)
    for (final other in const ['sans', 'serif', 'dejavu']) {
      if (other == named || (other == 'dejavu' && info.serif && !info.name.toLowerCase().contains('dejavu'))) continue;
      final otherRatio = ratioOf(other);
      final prefersName = other == 'dejavu' && info.name.toLowerCase().contains('dejavu');
      if (prefersName || ((ratio - 1).abs() > 0.04 && (otherRatio - 1).abs() < (ratio - 1).abs() - 0.03)) {
        family = other;
        ratio = otherRatio;
      }
    }
  }
  final factor = ratio.clamp(minFactor, 1.2);
  return (family: family, factor: factor, style: standInStyle(info, family: family));
}
