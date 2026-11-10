import 'dart:io';
import 'dart:typed_data';

/// Nothing to set up: this platform has real files.
void installWebFiles() {}

/// Nothing to keep: the files are on the disk.
Future<void> keepWebFiles(Object db) async {}

/// Nothing to read: the file is on the disk.
Future<void> ensureWebFile(String path) async {}

/// Nothing to let go of.
Future<void> releaseWebFile(String path) async {}

/// Only the web has files that are not on a disk.
Future<Uint8List> webFileBytes(String path) async => File(path).readAsBytes();
