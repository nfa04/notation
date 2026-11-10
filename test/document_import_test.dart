import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/markdown/document_import.dart';

void main() {
  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  test('Markdown and plain text come in as they are', () async {
    expect((await importDocumentFile('a.md', b('﻿# Title\r\n\r\n**bold**\n'))).text, '# Title\n\n**bold**');
    expect((await importDocumentFile('A.TXT', b('just text'))).text, 'just text');
  });

  test('a web page comes in as Markdown', () async {
    final read = await importDocumentFile('a.html', b('<h1>Title</h1><p>some <b>bold</b> text</p>'));
    expect(read.text, contains('# Title'));
    expect(read.text, contains('**bold**'));
  });

  test('an unknown type and a broken file are refused', () async {
    expect(importDocumentFile('a.xyz', b('x')), throwsFormatException);
    expect(importDocumentFile('a.docx', b('not a zip')), throwsFormatException);
  });
}
