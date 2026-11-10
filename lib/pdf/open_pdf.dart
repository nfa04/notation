import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:pdfrx/pdfrx.dart';

/// Opens the PDF at [path]. On the web a path is an address on the internet to the PDF engine, so the file (kept in memory,
/// see lib/web/web_files_web.dart) is read and handed over as bytes.
Future<PdfDocument> openPdfFile(String path) async =>
    kIsWeb ? PdfDocument.openData(await File(path).readAsBytes(), sourceName: path) : PdfDocument.openFile(path);
