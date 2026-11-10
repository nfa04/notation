import '../util/apart.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;

/// From this many bytes on a hash is worked out on another isolate: it is Dart code, and a PDF of scans (hundreds of MB) takes seconds
/// that would stop the screen.
const int digestApartFrom = 1 << 20;

/// The SHA-256 of [bytes], as hex.
Future<String> sha256Of(Uint8List bytes) => bytes.length < digestApartFrom ? Future.value(sha256.convert(bytes).toString()) : compute(_hashBytes, bytes);

String _hashBytes(Uint8List bytes) => sha256.convert(bytes).toString();

/// The SHA-256 of the file at [path], as hex. The file is read in pieces on another isolate: it is never all in memory, and nothing is
/// copied to it.
Future<String> sha256OfFile(String path) => runApart(() async => (await sha256.bind(File(path).openRead()).first).toString());
