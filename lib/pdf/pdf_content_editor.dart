/// Editing what an imported PDF really contains. PDFium does the work: through dart:ffi where that exists, in the browser through
/// the WebAssembly PDFium that runs on the page; elsewhere there is nothing to edit with and [pdfContentEditingSupported] is false.
library;

export 'pdf_edit_types.dart';
export 'pdf_content_editor_stub.dart'
    if (dart.library.ffi) 'pdf_content_editor_ffi.dart'
    if (dart.library.js_interop) 'pdf_content_editor_web.dart';
