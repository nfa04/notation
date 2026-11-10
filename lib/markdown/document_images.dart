import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The pictures in the written document: `![...](image:<file>)` is a picture the app keeps in its `images` folder (where the
/// pictures placed on pages are kept too); any other target is a path or a web address.
class DocumentImages {
  /// The folder the app keeps pictures in, once it is known ([init]).
  static String? dir;

  static Future<void> init() async {
    dir ??= p.join((await getApplicationSupportDirectory()).path, 'images');
  }

  /// The file of a picture's [target]; null for anything but a picture the app keeps (`image:`), or while the folder is not known.
  /// A path or `file://` address is not followed: a note that came from someone else could name any file of this device and have it
  /// shown, or put into an export that is then passed on.
  static File? fileOf(String target) {
    if (!target.startsWith('image:')) return null;
    final d = dir;
    return d == null ? null : File(p.join(d, p.basename(target.substring(6))));
  }

  /// Keeps [bytes] (a picture of type [ext]) for the document of note [noteId], and gives the target to write for it.
  static Future<String> keep(String noteId, Uint8List bytes, String ext) async {
    await init();
    final folder = Directory(dir!);
    await folder.create(recursive: true);
    final name = '$noteId-doc-${DateTime.now().microsecondsSinceEpoch}.$ext';
    await File(p.join(folder.path, name)).writeAsBytes(bytes);
    return 'image:$name';
  }

  /// A picture of any kind the device can read, as the document keeps it: PNG, JPEG and GIF as they are, any other (WebP, say) as a PNG,
  /// because that is what the exports know. (An animation of another kind is kept as its first image.)
  static Future<({Uint8List bytes, String ext})> forKeeping(Uint8List bytes) async {
    if (bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) return (bytes: bytes, ext: 'jpeg');
    if (bytes.length > 3 && bytes[0] == 0x47 && bytes[1] == 0x49) return (bytes: bytes, ext: 'gif');
    if (bytes.length > 7 && bytes[0] == 0x89 && bytes[1] == 0x50) return (bytes: bytes, ext: 'png');
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      try {
        final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
        if (png == null) throw const FormatException('The picture could not be read.');
        return (bytes: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes), ext: 'png');
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  /// The bytes of a picture's [target] (null: it cannot be read here, or is on the web).
  static Future<Uint8List?> read(String target) async {
    final f = fileOf(target);
    if (f == null || !await f.exists()) return null;
    return f.readAsBytes();
  }
}
