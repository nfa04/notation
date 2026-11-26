import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/extensions/extension_service.dart';
import 'package:notes/markdown/block_svg.dart';
import 'package:notes/markdown/document_export.dart';
import 'package:notes/markdown/extension_block.dart';
import 'package:notes/models/rich_text.dart';
import 'package:notes/models/page_format.dart';

final pages = DocumentPages(format: PageFormat.a4, title: 'T', date: DateTime(2026, 1, 1));

void main() {
  tearDown(() {
    ExtensionBlocks.languages = {};
    ExtensionBlocks.draw = null;
  });

  const drawing = BlockDrawing(100, 50, [
    {'points': [[0, 0], [100, 50]], 'color': '#ff0000', 'dash': 'dashed'}
  ], [
    {'x': 5, 'y': 5, 'text': 'a<b', 'size': 10}
  ]);

  test('a drawing becomes an SVG with its lines and (escaped) texts', () {
    final p = blockToSvg(drawing);
    expect(p.width, 100);
    expect(p.svg, contains('<polyline points="0,0 100,50"'));
    expect(p.svg, contains('stroke="#ff0000"'));
    expect(p.svg, contains('stroke-dasharray'));
    expect(p.svg, contains('a&lt;b'));
  });

  test('blocks of an extension are drawn once per distinct block; one that fails stays code', () async {
    var asked = 0;
    ExtensionBlocks.languages = {'chess'};
    ExtensionBlocks.draw = (lang, code, width) async {
      asked++;
      if (code == 'bad') throw 'no';
      return drawing;
    };
    const text = '```chess\nx\n```\n\n```chess\nx\n```\n\n```chess\nbad\n```\n\n```dart\ny\n```\n';
    final pictures = await renderBlockPictures(text);
    expect(pictures.keys, [blockPictureKey('chess', 'x')]);
    expect(asked, 2);
    final html = documentHtml(text, const [], blockPictures: pictures);
    expect(html, contains('<div class="block"><svg'));
    expect(html, contains('language-dart'));
    expect(html, contains('bad'));
  });

  test('a PDF draws the block instead of its source', () async {
    ExtensionBlocks.languages = {'chess'};
    ExtensionBlocks.draw = (lang, code, width) async => drawing;
    const text = '```chess\nSECRETSOURCE\n```\n';
    final c = RichInlineTextController()..text = text;
    final pictures = await renderBlockPictures(text);
    final withPicture = await documentPdf(c, pages, blockPictures: pictures);
    final plain = await documentPdf(c, pages);
    expect(withPicture.length, isNot(plain.length));
    expect(latin1.decode(withPicture.sublist(0, 5)), '%PDF-');
  });
}
