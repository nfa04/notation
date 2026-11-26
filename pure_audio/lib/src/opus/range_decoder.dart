import 'dart:typed_data';

import '../bits.dart';

const _symBits = 8, _codeBits = 32, _codeTop = 1 << 31, _codeBot = 1 << 23, _codeExtra = 7, _uintBits = 8, _windowSize = 32;
const _mask32 = 0xFFFFFFFF;

/// The number of bits in [v] (0 for 0).
int ilog(int v) => v <= 0 ? 0 : v.bitLength;

/// The range decoder of Opus (RFC 6716, section 4.1): the front of the packet is read with arithmetic coding, the end with raw bits.
class RangeDecoder {
  final Uint8List buf;
  int storage;
  int _offs = 0, _endOffs = 0, _endWindow = 0, nendBits = 0;
  int nbitsTotal = 0;
  int rng = 0, val = 0, _rem = 0, _ext = 0;
  bool error = false;

  RangeDecoder(this.buf, [int? length]) : storage = length ?? buf.length {
    nbitsTotal = _codeBits + 1 - ((_codeBits - _codeExtra) ~/ _symBits) * _symBits;
    rng = 1 << _codeExtra;
    _rem = _readByte();
    val = rng - 1 - (_rem >> (_symBits - _codeExtra));
    _normalize();
  }

  int _readByte() => _offs < storage ? buf[_offs++] : 0;
  int _readByteFromEnd() => _endOffs < storage ? buf[storage - (++_endOffs)] : 0;

  void _normalize() {
    while (rng <= _codeBot) {
      nbitsTotal += _symBits;
      rng = (rng << _symBits) & _mask32;
      var sym = _rem;
      _rem = _readByte();
      sym = ((sym << _symBits) | _rem) >> (_symBits - _codeExtra);
      val = (((val << _symBits) + (255 & ~sym)) & (_codeTop - 1));
    }
  }

  int decode(int ft) {
    _ext = rng ~/ ft;
    final s = val ~/ _ext;
    return ft - (s + 1 < ft ? s + 1 : ft);
  }

  int decodeBin(int bits) {
    _ext = rng >> bits;
    final s = val ~/ _ext;
    final top = 1 << bits;
    return top - (s + 1 < top ? s + 1 : top);
  }

  void update(int fl, int fh, int ft) {
    final s = (_ext * (ft - fh)) & _mask32;
    val -= s;
    rng = fl > 0 ? (_ext * (fh - fl)) & _mask32 : rng - s;
    _normalize();
  }

  /// A bit that is one with the probability 1/2^[logp].
  int bitLogp(int logp) {
    final r = rng, d = val, s = r >> logp;
    final ret = d < s;
    if (!ret) val = d - s;
    rng = ret ? s : r - s;
    _normalize();
    return ret ? 1 : 0;
  }

  /// A symbol from an inverse cumulative table (the entries are 8 bit in the 8 bit tables, or 16 bit); [ftb] is the table's bit size.
  int icdf(List<int> table, int ftb, [int offset = 0]) {
    var s = rng, t = 0, ret = -1;
    final d = val, r = s >> ftb;
    do {
      t = s;
      s = (r * table[offset + ++ret]) & _mask32;
    } while (d < s);
    val = d - s;
    rng = t - s;
    _normalize();
    return ret;
  }

  int uint(int ft) {
    ft--;
    var ftb = ilog(ft);
    if (ftb > _uintBits) {
      ftb -= _uintBits;
      final f = (ft >> ftb) + 1;
      final s = decode(f);
      update(s, s + 1, f);
      final t = (s << ftb) | bits(ftb);
      if (t <= ft) return t;
      error = true;
      return ft;
    }
    ft++;
    final s = decode(ft);
    update(s, s + 1, ft);
    return s;
  }

  int bits(int n) {
    var window = _endWindow, available = nendBits;
    if (available < n) {
      do {
        window |= _readByteFromEnd() << available;
        available += _symBits;
      } while (available <= _windowSize - _symBits);
    }
    final ret = window & ((1 << n) - 1);
    window >>= n;
    available -= n;
    _endWindow = window;
    nendBits = available;
    nbitsTotal += n;
    return ret;
  }

  /// Whole bits used so far.
  int tell() => nbitsTotal - ilog(rng);

  /// Eighths of bits used so far.
  int tellFrac() {
    const correction = [35733, 38967, 42495, 46340, 50535, 55109, 60097, 65535];
    final nbits = nbitsTotal << 3;
    var l = ilog(rng);
    final r = rng >> (l - 16);
    var b = (r >> 12) - 8;
    if (r > correction[b]) b++;
    l = (l << 3) + b;
    return nbits - l;
  }

  /// Fails with a plain sentence if the data was damaged badly enough for the decoder to notice.
  void check() {
    if (error) throw const AudioFormatException('An Opus packet is damaged.');
  }
}
