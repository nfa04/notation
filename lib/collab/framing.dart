import 'dart:typed_data';

/// Data channels carry messages of a few kilobytes at most; a note can be megabytes (a PDF, a
/// picture). A message is cut into frames that each fit, and put together again at the other
/// end. Frames of one message arrive in order (the channel is ordered), but messages are told
/// apart by a number so that the pieces of two are never mixed.
class Framer {
  final int maxPayload;
  int _next = 0;

  Framer({this.maxPayload = 12000});

  static const headerBytes = 8;

  /// [message] as frames: id (4 bytes), index (2), count (2), then a piece of the message.
  List<Uint8List> split(Uint8List message) {
    final count = message.isEmpty ? 1 : (message.length + maxPayload - 1) ~/ maxPayload;
    if (count > 0xFFFF) throw ArgumentError('the message is too big to send');
    final id = _next++ & 0xFFFFFFFF;
    return [
      for (var i = 0; i < count; i++)
        () {
          final from = i * maxPayload;
          final to = from + maxPayload > message.length ? message.length : from + maxPayload;
          final frame = Uint8List(headerBytes + to - from);
          final d = ByteData.sublistView(frame);
          d.setUint32(0, id);
          d.setUint16(4, i);
          d.setUint16(6, count);
          frame.setRange(headerBytes, frame.length, message, from);
          return frame;
        }(),
    ];
  }
}

/// Frames that carry no message but a question about the link itself. A frame with no pieces (count 0) is ignored by every reader that
/// does not know them - an older app skips them - so they can be sent to any device; the index says which it is.
enum FrameControl {
  /// "Are you there?" - answered at once with a [pong].
  ping(1),
  pong(2);

  final int code;
  const FrameControl(this.code);

  /// The frame that says it: id 0, the code, no pieces.
  Uint8List get frame {
    final out = Uint8List(Framer.headerBytes);
    ByteData.sublistView(out).setUint16(4, code);
    return out;
  }

  /// Which control [frame] is, or null when it is a piece of a message (or nonsense).
  static FrameControl? of(Uint8List frame) {
    if (frame.length != Framer.headerBytes) return null;
    final d = ByteData.sublistView(frame);
    if (d.getUint16(6) != 0) return null;
    final code = d.getUint16(4);
    for (final c in values) {
      if (c.code == code) return c;
    }
    return null;
  }
}

/// Puts the frames of messages back together.
///
/// The frames are not sealed (only the whole message is), so whoever is on the other end of the channel decides what arrives here
/// before anything could tell whether it is from a member. Because of that the memory it may take is bounded: a channel is ordered and
/// reliable, so the pieces of one message follow each other, and a message that is begun while another one is not finished means the
/// other one was given up - it is dropped, and a sender that starts thousands of messages and finishes none holds on to one.
class Reassembler {
  /// The most that one message may come to; bigger ones are ignored.
  final int maxMessageBytes;

  /// How many unfinished messages are kept (a sender of this app has one; a few more are allowed for senders that interleave).
  final int maxPartial;

  Reassembler({this.maxMessageBytes = 256 * 1024 * 1024, this.maxPartial = 4});

  final Map<int, List<Uint8List?>> _partial = {}; // (in the order they were begun)
  final Map<int, int> _got = {};

  /// The message that [frame] completes, or null while there are pieces missing. A frame that is not
  /// one (too short, nonsense numbers) is ignored.
  Uint8List? add(Uint8List frame) {
    if (frame.length < Framer.headerBytes) return null;
    final d = ByteData.sublistView(frame);
    final id = d.getUint32(0), index = d.getUint16(4), count = d.getUint16(6);
    if (count == 0 || index >= count) return null;
    var parts = _partial[id];
    if (parts == null) {
      // (an honest sender's pieces are all the size of the first one, but for the last)
      final piece = frame.length - Framer.headerBytes;
      if (piece > 0 && (count - 1) * piece > maxMessageBytes) return null;
      while (_partial.length >= maxPartial) {
        final oldest = _partial.keys.first;
        _partial.remove(oldest);
        _got.remove(oldest);
      }
      parts = _partial[id] = List<Uint8List?>.filled(count, null);
    }
    if (parts.length != count || parts[index] != null) return null;
    parts[index] = Uint8List.sublistView(frame, Framer.headerBytes);
    final got = _got[id] = (_got[id] ?? 0) + 1;
    if (got < count) return null;
    _partial.remove(id);
    _got.remove(id);
    final out = BytesBuilder(copy: false);
    for (final p in parts) {
      out.add(p!);
    }
    return out.takeBytes();
  }
}
