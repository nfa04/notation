import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/framing.dart';

Uint8List frame(int id, int index, int count, int payload) {
  final f = Uint8List(Framer.headerBytes + payload);
  final d = ByteData.sublistView(f);
  d.setUint32(0, id);
  d.setUint16(4, index);
  d.setUint16(6, count);
  return f;
}

void main() {
  test('a message whose first piece is tiny cannot grow past the limit', () {
    final r = Reassembler(maxMessageBytes: 1000);
    // (the size the declared count allows is worked out from the first piece, which is one byte here: 1000 of them pass that check, and they are then followed by pieces of 100)
    expect(r.add(frame(1, 0, 1000, 1)), isNull);
    expect(r.pendingMessages, 1);
    for (var i = 1; i < 30; i++) {
      r.add(frame(1, i, 1000, 100)); // (different pieces: nothing but the count of real bytes can stop this)
      expect(r.pendingBytes, lessThanOrEqualTo(1000));
    }
    expect(r.pendingMessages, 0, reason: 'the message that went over the limit was given up');
  });

  test('an honest message still arrives', () {
    final r = Reassembler(maxMessageBytes: 1000);
    expect(r.add(frame(2, 0, 2, 10)), isNull);
    expect(r.add(frame(2, 1, 2, 5))?.length, 15);
  });
}
