import 'dart:typed_data';

/// Only the web needs an address for bytes in memory.
String blobUrlOf(Uint8List bytes, String mimeType) => throw UnsupportedError('only on the web');

void revokeBlobUrl(String url) {}

String handOverBytes(Uint8List bytes) => throw UnsupportedError('only on the web');

void forgetBytes(String name) {}
