import 'dart:typed_data';

import 'import_source.dart';

/// A PDF inside a GoodNotes file: the pages the notebook was made on, with whatever GoodNotes has flattened into them.
class GoodnotesPdf {
  final String name;
  final Uint8List bytes;
  const GoodnotesPdf(this.name, this.bytes);
}

/// The PDFs of a `.goodnotes` file. GoodNotes keeps what is written in its own binary format, which nothing documents and this app
/// does not read; what can be taken out safely are the PDFs that are inside (the pages the notebook lies on). So the file is
/// searched for anything that is a PDF by its first bytes, whatever it is called and wherever it lies.
///
/// Throws a [FormatException] when [bytes] is no zip, and a [FormatException] saying so when no PDF is inside.
Future<List<GoodnotesPdf>> goodnotesPdfs(Uint8List bytes, {required String name}) async {
  final ImportSource source;
  try {
    source = sourceFromZip(bytes, name: name);
  } on FormatException {
    throw const FormatException('This is not a GoodNotes file. In GoodNotes, choose Share → Export as PDF and open that PDF here.');
  }
  final found = <GoodnotesPdf>[];
  for (final file in source.files) {
    if (file.size < 8) continue;
    final data = await file.read();
    if (!_isPdf(data)) continue;
    found.add(GoodnotesPdf(file.name, data));
  }
  if (found.isEmpty) {
    throw const FormatException('There is no PDF in this GoodNotes file, and what is written in it cannot be read. In GoodNotes, choose Share → Export as PDF and open that PDF here.');
  }
  // the biggest first: a notebook's own pages, not a thumbnail or a one-page attachment
  found.sort((a, b) => b.bytes.length.compareTo(a.bytes.length));
  return found;
}

bool _isPdf(Uint8List d) {
  // "%PDF" may follow a few bytes of junk, the specification allows 1024
  final limit = d.length < 1024 ? d.length - 4 : 1024;
  for (var i = 0; i <= limit; i++) {
    if (d[i] == 0x25 && d[i + 1] == 0x50 && d[i + 2] == 0x44 && d[i + 3] == 0x46) return true;
  }
  return false;
}
