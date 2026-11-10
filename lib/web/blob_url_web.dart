import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// An address the browser can play or show [bytes] from, without copying them into a long text as a data address would. Give it
/// back with [revokeBlobUrl] when it is no longer used.
String blobUrlOf(Uint8List bytes, String mimeType) =>
    web.URL.createObjectURL(web.Blob(<JSAny>[bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType)));

void revokeBlobUrl(String url) => web.URL.revokeObjectURL(url);

int _handedOver = 0;

JSObject get _shelf => globalContext['__ortBytes'] as JSObject;

/// A name under which the runtime of the models finds [bytes] itself (see web/index.html): no blob, and so no copy of the model
/// made by fetching it. Give it back with [forgetBytes].
String handOverBytes(Uint8List bytes) {
  final name = 'bytes:${_handedOver++}';
  _shelf.setProperty(name.toJS, bytes.toJS);
  return name;
}

void forgetBytes(String name) => _shelf.setProperty(name.toJS, null);
