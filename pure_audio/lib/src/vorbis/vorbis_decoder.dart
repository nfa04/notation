import 'dart:math' as math;
import 'dart:typed_data';

import '../bits.dart';
import '../mdct.dart';

class _Bits {
  final Uint8List d;
  int pos = 0; // in bits
  bool eop = false;
  _Bits(this.d);

  int read(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      final byte = pos >> 3;
      if (byte >= d.length) {
        eop = true;
        pos++;
        continue;
      }
      v |= ((d[byte] >> (pos & 7)) & 1) << i;
      pos++;
    }
    return v;
  }

  int bit() => read(1);
}

int _ilog(int v) => v <= 0 ? 0 : v.bitLength;

double _float32Unpack(int x) {
  var mantissa = (x & 0x1FFFFF).toDouble();
  final sign = x & 0x80000000;
  final exponent = (x & 0x7FE00000) >> 21;
  if (sign != 0) mantissa = -mantissa;
  return mantissa * math.pow(2, exponent - 788);
}

class _Codebook {
  int dims = 0, entries = 0;
  Int32List lengths = Int32List(0);
  // the code tree: node i has children left[i], right[i]; a leaf is encoded as -(entry+1)
  Int32List left = Int32List(0), right = Int32List(0);
  Float64List? vectors; // entries * dims

  void parse(_Bits b) {
    if (b.read(24) != 0x564342) throw const AudioFormatException('Vorbis: bad codebook.');
    dims = b.read(16);
    entries = b.read(24);
    lengths = Int32List(entries);
    final ordered = b.bit() == 1;
    if (!ordered) {
      final sparse = b.bit() == 1;
      for (var i = 0; i < entries; i++) {
        if (sparse) {
          lengths[i] = b.bit() == 1 ? b.read(5) + 1 : 0;
        } else {
          lengths[i] = b.read(5) + 1;
        }
      }
    } else {
      var current = b.read(5) + 1;
      var i = 0;
      while (i < entries) {
        final n = b.read(_ilog(entries - i));
        for (var j = 0; j < n && i < entries; j++) {
          lengths[i++] = current;
        }
        current++;
      }
    }
    _buildTree();
    final type = b.read(4);
    if (type == 0) return;
    if (type > 2) throw const AudioFormatException('Vorbis: bad codebook lookup.');
    final minV = _float32Unpack(b.read(32)), delta = _float32Unpack(b.read(32));
    final valueBits = b.read(4) + 1;
    final sequence = b.bit() == 1;
    int count;
    if (type == 1) {
      count = 0;
      while (math.pow(count + 1, dims) <= entries) {
        count++;
      }
    } else {
      count = entries * dims;
    }
    final mult = [for (var i = 0; i < count; i++) b.read(valueBits)];
    final v = Float64List(entries * dims);
    for (var e = 0; e < entries; e++) {
      var last = 0.0;
      var div = 1;
      for (var j = 0; j < dims; j++) {
        final idx = type == 1 ? (e ~/ div) % count : e * dims + j;
        final val = mult[idx] * delta + minV + last;
        if (sequence) last = val;
        v[e * dims + j] = val;
        if (type == 1) div *= count;
      }
    }
    vectors = v;
  }

  void _buildTree() {
    final l = <int>[0], r = <int>[0];
    var first = -1;
    for (var i = 0; i < entries; i++) {
      if (lengths[i] > 0) {
        first = i;
        break;
      }
    }
    if (first < 0) {
      left = Int32List.fromList(l);
      right = Int32List.fromList(r);
      return;
    }
    final avail = List<int>.filled(33, 0);
    void insert(int code, int len, int entry) {
      var node = 0;
      for (var k = 0; k < len; k++) {
        final bit = (code >> (31 - k)) & 1;
        final list = bit == 0 ? l : r;
        if (k == len - 1) {
          list[node] = -(entry + 1);
        } else {
          var next = list[node];
          if (next <= 0) {
            l.add(0);
            r.add(0);
            next = l.length - 1;
            list[node] = next;
          }
          node = next;
        }
      }
    }

    insert(0, lengths[first], first);
    for (var i = 1; i <= lengths[first]; i++) {
      avail[i] = 1 << (32 - i);
    }
    for (var i = first + 1; i < entries; i++) {
      var z = lengths[i];
      if (z == 0) continue;
      while (z > 0 && avail[z] == 0) {
        z--;
      }
      if (z == 0) throw const AudioFormatException('Vorbis: codebook is over full.');
      final res = avail[z];
      avail[z] = 0;
      insert(res, lengths[i], i);
      for (var y = lengths[i]; y > z; y--) {
        avail[y] = res + (1 << (32 - y));
      }
    }
    left = Int32List.fromList(l);
    right = Int32List.fromList(r);
  }

  int decode(_Bits b) {
    var node = 0;
    while (true) {
      final next = b.bit() == 0 ? left[node] : right[node];
      if (next < 0) return -next - 1;
      if (next == 0 || b.eop) return b.eop ? 0 : throw const AudioFormatException('Vorbis: bad code.');
      node = next;
    }
  }
}

class _Floor {
  late List<int> partClass, classDims, classSub, classMaster;
  late List<List<int>> subBooks;
  int multiplier = 0, rangeBits = 0;
  late List<int> xs;
  late List<int> order; // indices sorted by x
  late List<int> lowN, highN;

  void parse(_Bits b) {
    final partitions = b.read(5);
    partClass = [for (var i = 0; i < partitions; i++) b.read(4)];
    final classes = partClass.isEmpty ? 0 : partClass.reduce(math.max) + 1;
    classDims = List.filled(classes, 0);
    classSub = List.filled(classes, 0);
    classMaster = List.filled(classes, 0);
    subBooks = [];
    for (var i = 0; i < classes; i++) {
      classDims[i] = b.read(3) + 1;
      classSub[i] = b.read(2);
      if (classSub[i] != 0) classMaster[i] = b.read(8);
      subBooks.add([for (var j = 0; j < (1 << classSub[i]); j++) b.read(8) - 1]);
    }
    multiplier = b.read(2) + 1;
    rangeBits = b.read(4);
    xs = [0, 1 << rangeBits];
    for (final c in partClass) {
      for (var j = 0; j < classDims[c]; j++) {
        xs.add(b.read(rangeBits));
      }
    }
    final n = xs.length;
    order = List.generate(n, (i) => i)..sort((a, c) => xs[a].compareTo(xs[c]));
    lowN = List.filled(n, 0);
    highN = List.filled(n, 1);
    for (var i = 2; i < n; i++) {
      var lo = 0, hi = 1;
      for (var j = 0; j < i; j++) {
        if (xs[j] < xs[i] && xs[j] > xs[lo]) lo = j;
        if (xs[j] > xs[i] && xs[j] < xs[hi]) hi = j;
      }
      lowN[i] = lo;
      highN[i] = hi;
    }
  }

  static final _dbTable = Float64List.fromList([for (var i = 0; i < 256; i++) math.pow(10, (i - 255) * 0.546875 / 20).toDouble()]);

  /// Returns the floor curve of [n] values, or null when the channel has no floor in this packet.
  Float64List? decode(_Bits b, List<_Codebook> books, int n) {
    if (b.bit() == 0) return null;
    final range = const [256, 128, 86, 64][multiplier - 1];
    final y = List<int>.filled(xs.length, 0);
    y[0] = b.read(_ilog(range - 1));
    y[1] = b.read(_ilog(range - 1));
    var off = 2;
    for (final c in partClass) {
      final dim = classDims[c], cbits = classSub[c];
      final csub = (1 << cbits) - 1;
      var cval = 0;
      if (cbits > 0) cval = books[classMaster[c]].decode(b);
      for (var j = 0; j < dim; j++) {
        final book = subBooks[c][cval & csub];
        cval >>= cbits;
        y[off + j] = book >= 0 ? books[book].decode(b) : 0;
      }
      off += dim;
    }
    final cnt = xs.length;
    final finalY = List<int>.filled(cnt, 0);
    final step2 = List<bool>.filled(cnt, false);
    step2[0] = step2[1] = true;
    finalY[0] = y[0];
    finalY[1] = y[1];
    for (var i = 2; i < cnt; i++) {
      final lo = lowN[i], hi = highN[i];
      final predicted = _renderPoint(xs[lo], finalY[lo], xs[hi], finalY[hi], xs[i]);
      final val = y[i];
      final highroom = range - predicted, lowroom = predicted;
      final room = (highroom < lowroom ? highroom : lowroom) * 2;
      if (val != 0) {
        step2[lo] = step2[hi] = step2[i] = true;
        if (val >= room) {
          finalY[i] = highroom > lowroom ? val - lowroom + predicted : predicted - val + highroom - 1;
        } else {
          finalY[i] = val.isOdd ? predicted - ((val + 1) >> 1) : predicted + (val >> 1);
        }
      } else {
        step2[i] = false;
        finalY[i] = predicted;
      }
    }
    final out = Float64List(n);
    var hx = 0, hy = 0, lx = 0, ly = finalY[order[0]] * multiplier;
    for (var k = 1; k < cnt; k++) {
      final i = order[k];
      if (!step2[i]) continue;
      hy = finalY[i] * multiplier;
      hx = xs[i];
      _line(out, lx, ly, hx, hy, n);
      lx = hx;
      ly = hy;
    }
    if (hx < n) {
      for (var i = hx; i < n; i++) {
        out[i] = _dbTable[ly];
      }
    }
    return out;
  }

  static int _renderPoint(int x0, int y0, int x1, int y1, int x) {
    final dy = y1 - y0, adx = x1 - x0;
    final ady = dy.abs();
    final err = ady * (x - x0);
    final off = err ~/ adx;
    return dy < 0 ? y0 - off : y0 + off;
  }

  static void _line(Float64List out, int x0, int y0, int x1, int y1, int n) {
    final dy = y1 - y0, adx = x1 - x0;
    final ady = dy.abs();
    final base = dy ~/ adx; // truncating, as in C
    var x = x0, y = y0, err = 0;
    final sy = dy < 0 ? base - 1 : base + 1;
    final adyAdj = ady - base.abs() * adx;
    if (x < n) out[x] = _dbTable[y.clamp(0, 255)];
    for (x = x0 + 1; x < math.min(x1, n); x++) {
      err += adyAdj;
      if (err >= adx) {
        err -= adx;
        y += sy;
      } else {
        y += base;
      }
      out[x] = _dbTable[y.clamp(0, 255)];
    }
  }
}

class _Residue {
  int type = 0, begin = 0, end = 0, psize = 0, classifications = 0, classbook = 0;
  late List<List<int>> books; // [class][pass]

  void parse(_Bits b, int t) {
    type = t;
    begin = b.read(24);
    end = b.read(24);
    psize = b.read(24) + 1;
    classifications = b.read(6) + 1;
    classbook = b.read(8);
    final cascade = <int>[];
    for (var i = 0; i < classifications; i++) {
      var low = b.read(3);
      final flag = b.bit();
      if (flag == 1) low |= b.read(5) << 3;
      cascade.add(low);
    }
    books = [
      for (var i = 0; i < classifications; i++) [for (var j = 0; j < 8; j++) (cascade[i] & (1 << j)) != 0 ? b.read(8) : -1]
    ];
  }

  /// Adds the residue vectors in [v] (each of length [n], or one of length ch*n for type 2).
  void decode(_Bits b, List<_Codebook> cbs, List<Float64List> v, List<bool> skip, int n) {
    final ch = v.length;
    final cb = cbs[classbook];
    final dims = cb.dims;
    final limit = type == 2 ? n * 1 : n;
    final endAt = math.min(end, limit), beginAt = math.min(begin, limit);
    final toRead = (endAt - beginAt) ~/ psize;
    if (toRead <= 0) return;
    final classes = [for (var j = 0; j < ch; j++) List<int>.filled(toRead + dims, 0)];
    for (var pass = 0; pass < 8; pass++) {
      var part = 0;
      while (part < toRead) {
        if (pass == 0) {
          for (var j = 0; j < ch; j++) {
            if (skip[j]) continue;
            var temp = cb.decode(b);
            for (var i = dims - 1; i >= 0; i--) {
              classes[j][part + i] = temp % classifications;
              temp ~/= classifications;
            }
          }
        }
        for (var i = 0; i < dims && part < toRead; i++, part++) {
          for (var j = 0; j < ch; j++) {
            if (skip[j]) continue;
            final book = books[classes[j][part]][pass];
            if (book < 0) continue;
            final bk = cbs[book];
            final vec = bk.vectors;
            if (vec == null) throw const AudioFormatException('Vorbis: residue book has no vectors.');
            final off = beginAt + part * psize;
            final d = bk.dims;
            if (type == 0) {
              final step = psize ~/ d;
              for (var s = 0; s < step; s++) {
                final e = bk.decode(b);
                for (var k = 0; k < d; k++) {
                  if (off + s + k * step < v[j].length) v[j][off + s + k * step] += vec[e * d + k];
                }
              }
            } else {
              for (var s = 0; s < psize; s += d) {
                final e = bk.decode(b);
                for (var k = 0; k < d; k++) {
                  if (off + s + k < v[j].length) v[j][off + s + k] += vec[e * d + k];
                }
              }
            }
            if (b.eop) return;
          }
        }
      }
    }
  }
}

class _Mapping {
  int submaps = 1;
  List<int> magnitude = [], angle = [], mux = [], floors = [], residues = [];
}

/// The decoder of Vorbis I (the three header packets, then audio packets).
class VorbisDecoder {
  int channels = 0, sampleRate = 0;
  int _bs0 = 0, _bs1 = 0;
  final _books = <_Codebook>[];
  final _floors = <_Floor>[];
  final _residues = <_Residue>[];
  final _mappings = <_Mapping>[];
  final _modes = <(bool, int)>[]; // (long, mapping)
  final _mdct = <int, Imdct>{};
  final _windows = <int, Float64List>{};
  List<Float64List> _tail = [];
  int _prevN = 0;

  VorbisDecoder(Uint8List ident, Uint8List setup) {
    final b = _Bits(ident);
    if (b.read(8) != 1 || !_isVorbis(ident)) throw const AudioFormatException('This is not a Vorbis stream.');
    b.pos = 56;
    if (b.read(32) != 0) throw const AudioFormatException('Unknown Vorbis version.');
    channels = b.read(8);
    sampleRate = b.read(32);
    b.read(32);
    b.read(32);
    b.read(32);
    final sizes = b.read(8);
    _bs0 = 1 << (sizes & 15);
    _bs1 = 1 << (sizes >> 4);
    _parseSetup(setup);
  }

  static bool _isVorbis(Uint8List p) => p.length > 7 && String.fromCharCodes(p.sublist(1, 7)) == 'vorbis';

  void _parseSetup(Uint8List p) {
    if (p.length < 8 || p[0] != 5 || !_isVorbis(p)) throw const AudioFormatException('Vorbis: bad setup header.');
    final b = _Bits(p)..pos = 56;
    final nBooks = b.read(8) + 1;
    for (var i = 0; i < nBooks; i++) {
      _books.add(_Codebook()..parse(b));
    }
    final nTimes = b.read(6) + 1;
    for (var i = 0; i < nTimes; i++) {
      b.read(16);
    }
    final nFloors = b.read(6) + 1;
    for (var i = 0; i < nFloors; i++) {
      if (b.read(16) != 1) throw const AudioFormatException('Vorbis floors of type 0 cannot be read yet.');
      _floors.add(_Floor()..parse(b));
    }
    final nRes = b.read(6) + 1;
    for (var i = 0; i < nRes; i++) {
      final t = b.read(16);
      if (t > 2) throw const AudioFormatException('Vorbis: bad residue type.');
      _residues.add(_Residue()..parse(b, t));
    }
    final nMaps = b.read(6) + 1;
    for (var i = 0; i < nMaps; i++) {
      if (b.read(16) != 0) throw const AudioFormatException('Vorbis: bad mapping type.');
      final m = _Mapping();
      m.submaps = b.bit() == 1 ? b.read(4) + 1 : 1;
      if (b.bit() == 1) {
        final steps = b.read(8) + 1;
        for (var s = 0; s < steps; s++) {
          m.magnitude.add(b.read(_ilog(channels - 1)));
          m.angle.add(b.read(_ilog(channels - 1)));
        }
      }
      if (b.read(2) != 0) throw const AudioFormatException('Vorbis: bad mapping.');
      m.mux = [for (var c = 0; c < channels; c++) m.submaps > 1 ? b.read(4) : 0];
      for (var s = 0; s < m.submaps; s++) {
        b.read(8);
        m.floors.add(b.read(8));
        m.residues.add(b.read(8));
      }
      _mappings.add(m);
    }
    final nModes = b.read(6) + 1;
    for (var i = 0; i < nModes; i++) {
      final long = b.bit() == 1;
      b.read(16);
      b.read(16);
      _modes.add((long, b.read(8)));
    }
  }

  Float64List _window(int n, bool long, bool prevLong, bool nextLong) {
    final key = n * 4 + (prevLong ? 2 : 0) + (nextLong ? 1 : 0);
    return _windows.putIfAbsent(key, () {
      final w = Float64List(n);
      final leftN = long && !prevLong ? _bs0 ~/ 2 : n ~/ 2;
      final leftStart = long && !prevLong ? n ~/ 4 - leftN ~/ 2 : 0;
      final rightN = long && !nextLong ? _bs0 ~/ 2 : n ~/ 2;
      final rightStart = long && !nextLong ? n * 3 ~/ 4 - rightN ~/ 2 : n ~/ 2;
      double slope(int i, int len) => math.sin(math.pi / 2 * math.pow(math.sin((i + .5) / len * math.pi / 2), 2));
      for (var i = 0; i < n ~/ 2; i++) {
        w[i] = i < leftStart ? 0 : (i < leftStart + leftN ? slope(i - leftStart, leftN) : 1);
      }
      for (var i = n ~/ 2; i < n; i++) {
        w[i] = i < rightStart ? 1 : (i < rightStart + rightN ? slope(rightN - 1 - (i - rightStart), rightN) : 0);
      }
      return w;
    });
  }

  /// The samples (one list per channel) that this audio packet completes; the first packet gives none.
  List<Float64List> decode(Uint8List packet) {
    final b = _Bits(packet);
    if (b.bit() != 0) return [for (var c = 0; c < channels; c++) Float64List(0)];
    final modeBits = _ilog(_modes.length - 1);
    final modeIdx = b.read(modeBits);
    if (modeIdx >= _modes.length) throw const AudioFormatException('Vorbis: bad mode.');
    final (long, mapIdx) = _modes[modeIdx];
    var prevLong = true, nextLong = true;
    if (long) {
      prevLong = b.bit() == 1;
      nextLong = b.bit() == 1;
    }
    final n = long ? _bs1 : _bs0;
    final half = n ~/ 2;
    final map = _mappings[mapIdx];
    final floors = <Float64List?>[];
    for (var c = 0; c < channels; c++) {
      floors.add(_floors[map.floors[map.mux[c]]].decode(b, _books, half));
    }
    final noRes = [for (final f in floors) f == null];
    for (var s = 0; s < map.magnitude.length; s++) {
      if (!noRes[map.magnitude[s]] || !noRes[map.angle[s]]) {
        noRes[map.magnitude[s]] = false;
        noRes[map.angle[s]] = false;
      }
    }
    final spectra = [for (var c = 0; c < channels; c++) Float64List(half)];
    for (var s = 0; s < map.submaps; s++) {
      final chans = [for (var c = 0; c < channels; c++) if (map.mux[c] == s) c];
      if (chans.isEmpty) continue;
      final res = _residues[map.residues[s]];
      if (res.type == 2) {
        if (chans.every((c) => noRes[c])) continue;
        final v = [Float64List(half * chans.length)];
        res.decode(b, _books, v, [false], half * chans.length);
        for (var i = 0; i < half; i++) {
          for (var k = 0; k < chans.length; k++) {
            spectra[chans[k]][i] = v[0][i * chans.length + k];
          }
        }
      } else {
        final v = [for (final c in chans) spectra[c]];
        res.decode(b, _books, v, [for (final c in chans) noRes[c]], half);
      }
    }
    for (var s = map.magnitude.length - 1; s >= 0; s--) {
      final m = spectra[map.magnitude[s]], a = spectra[map.angle[s]];
      for (var i = 0; i < half; i++) {
        final mv = m[i], av = a[i];
        double nm, na;
        if (mv > 0) {
          if (av > 0) {
            nm = mv;
            na = mv - av;
          } else {
            na = mv;
            nm = mv + av;
          }
        } else {
          if (av > 0) {
            nm = mv;
            na = mv + av;
          } else {
            na = mv;
            nm = mv - av;
          }
        }
        m[i] = nm;
        a[i] = na;
      }
    }
    final imdct = _mdct.putIfAbsent(half, () => Imdct(half, 1.0));
    final w = _window(n, long, prevLong, nextLong);
    final cur = <Float64List>[];
    for (var c = 0; c < channels; c++) {
      final out = Float64List(n);
      final f = floors[c];
      if (f != null) {
        final sp = spectra[c];
        for (var i = 0; i < half; i++) {
          sp[i] *= f[i];
        }
        imdct.run(sp, out);
        for (var i = 0; i < n; i++) {
          out[i] *= w[i];
        }
      }
      cur.add(out);
    }
    List<Float64List> result;
    if (_prevN == 0) {
      result = [for (var c = 0; c < channels; c++) Float64List(0)];
    } else {
      final e = _prevN ~/ 4 + n ~/ 4;
      final off = _prevN ~/ 4 - n ~/ 4;
      result = [];
      for (var c = 0; c < channels; c++) {
        final o = Float64List(e);
        for (var t = 0; t < e; t++) {
          var v = 0.0;
          if (t < _tail[c].length) v += _tail[c][t];
          final j = t - off;
          if (j >= 0 && j < n) v += cur[c][j];
          o[t] = v;
        }
        result.add(o);
      }
    }
    _tail = [for (final c in cur) Float64List.sublistView(c, half)];
    _prevN = n;
    return result;
  }

  /// The three header packets out of the Matroska CodecPrivate (Xiph lacing).
  static (Uint8List, Uint8List)? splitXiph(Uint8List p) {
    if (p.isEmpty || p[0] != 2) return null;
    var pos = 1;
    int len() {
      var v = 0;
      while (pos < p.length) {
        final x = p[pos++];
        v += x;
        if (x < 255) break;
      }
      return v;
    }

    final l1 = len(), l2 = len();
    if (pos + l1 + l2 > p.length) return null;
    final ident = Uint8List.sublistView(p, pos, pos + l1);
    final setup = Uint8List.sublistView(p, pos + l1 + l2);
    return (ident, setup);
  }
}
