import 'dart:typed_data';

/// A PDF dictionary. Always create it as `<String, Object?>{}` so `is PdfDict` works.
typedef PdfDict = Map<String, Object?>;

/// Thrown when the input PDF (or overlay) uses something this library does not
/// handle: encryption, a damaged cross-reference table, an unsupported stream
/// filter, ...
///
/// It is safe to catch this and fall back to another export strategy; no output
/// is produced in that case.
class UnsupportedPdfException implements Exception {
  final String message;
  UnsupportedPdfException(this.message);

  @override
  String toString() => 'UnsupportedPdfException: $message';
}

/// A PDF name object (`/Type`).
class PdfName {
  final String value;
  const PdfName(this.value);

  @override
  bool operator ==(Object other) => other is PdfName && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '/$value';
}

/// An indirect reference (`12 0 R`).
class PdfRef {
  final int num;
  final int gen;
  const PdfRef(this.num, [this.gen = 0]);

  @override
  bool operator ==(Object other) =>
      other is PdfRef && other.num == num && other.gen == gen;

  @override
  int get hashCode => Object.hash(num, gen);

  @override
  String toString() => '$num $gen R';
}

/// A PDF string (literal or hex). Kept as raw bytes.
class PdfString {
  final Uint8List bytes;
  const PdfString(this.bytes);
}

/// A stream object: its dictionary plus the still-encoded bytes.
class PdfStream {
  final PdfDict dict;
  final Uint8List raw;
  PdfStream(this.dict, this.raw);
}

/// Result of parsing `12 0 obj ... endobj`.
class IndirectObject {
  final int num;
  final int gen;
  final Object? value;
  const IndirectObject(this.num, this.gen, this.value);
}
