import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:pure_audio/src/mdct.dart';

void main() {
  for (final m in [8, 128, 1024]) {
    test('the fast inverse MDCT of $m coefficients is the sum it is defined by', () {
      final random = math.Random(m);
      final x = Float64List.fromList([for (var i = 0; i < m; i++) random.nextDouble() - 0.5]);
      final out = Float64List(2 * m);
      Imdct(m, 0.5).run(x, out);
      for (var n = 0; n < 2 * m; n += m > 100 ? 37 : 1) {
        var s = 0.0;
        for (var k = 0; k < m; k++) {
          s += x[k] * math.cos(math.pi / m * (n + 0.5 + m / 2) * (k + 0.5));
        }
        expect(out[n], closeTo(s * 0.5, 1e-9), reason: 'n=$n');
      }
    });
  }
}
