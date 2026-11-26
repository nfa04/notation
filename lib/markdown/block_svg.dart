import '../extensions/extension_service.dart' show BlockDrawing;
import 'extension_block.dart' show ExtensionBlocks;
import 'markdown_parser.dart';

/// A block an extension drew, as a picture for the exports (PDF, web page): [svg] is a complete SVG document of [width] x [height].
class BlockPicture {
  final String svg;
  final double width, height;
  const BlockPicture(this.svg, this.width, this.height);
}

/// The key a block is looked up by in the pictures [renderBlockPictures] made.
String blockPictureKey(String language, String code) => '${language.toLowerCase()}\u0000$code';

String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

String _hex(Object? v, String fallback) => v is String && RegExp(r'^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').hasMatch(v) ? v.substring(0, 7) : fallback;

String _n(num v) => v.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

/// What an extension drew (lines and texts), written as SVG in black on a transparent ground.
BlockPicture blockToSvg(BlockDrawing d) {
  final b = StringBuffer('<svg xmlns="http://www.w3.org/2000/svg" width="${_n(d.width)}" height="${_n(d.height)}" viewBox="0 0 ${_n(d.width)} ${_n(d.height)}">');
  for (final s in d.strokes) {
    final points = [for (final p in (s['points'] as List)) '${_n(p[0] as num)},${_n(p[1] as num)}'];
    if (points.length < 2) continue;
    final fill = s['fill'] == null ? 'none' : _hex(s['fill'], 'none');
    final dash = s['dash'];
    final w = (s['width'] as num?)?.toDouble() ?? 1.5;
    b.write('<polyline points="${points.join(' ')}" fill="$fill" stroke="${_hex(s['color'], '#000000')}" stroke-width="${_n(w)}" stroke-linecap="round" stroke-linejoin="round"'
        '${dash == 'dashed' ? ' stroke-dasharray="8 5"' : dash == 'dotted' ? ' stroke-dasharray="1.5 4"' : ''}/>');
  }
  for (final t in d.texts) {
    final size = (t['size'] as num?)?.toDouble() ?? 14;
    // (SVG puts the text on its baseline: the drawing puts its top at y)
    b.write('<text x="${_n(t['x'] as num)}" y="${_n((t['y'] as num) + size * 0.85)}" font-size="${_n(size)}" font-family="sans-serif" fill="${_hex(t['color'], '#000000')}">${_esc(t['text'] as String)}</text>');
  }
  b.write('</svg>');
  return BlockPicture(b.toString(), d.width, d.height);
}

/// Asks the extensions to draw every block of [text] they handle (once for the same block); a block that fails is left out, and stays
/// code in the export. [width] is the width of the text on the page.
Future<Map<String, BlockPicture>> renderBlockPictures(String text, {double width = 600}) async {
  final draw = ExtensionBlocks.draw;
  final out = <String, BlockPicture>{};
  if (draw == null || ExtensionBlocks.languages.isEmpty) return out;
  for (final b in parseMarkdown(text)) {
    if (b.type != MdBlockType.code || !ExtensionBlocks.handles(b.lang)) continue;
    final key = blockPictureKey(b.lang, b.code);
    if (out.containsKey(key)) continue;
    try {
      out[key] = blockToSvg(await draw(b.lang.toLowerCase(), b.code, width));
    } catch (_) {}
  }
  return out;
}
