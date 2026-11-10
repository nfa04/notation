import 'package:flutter_test/flutter_test.dart';
import 'package:notes/algebra/checker.dart';
import 'package:notes/algebra/units.dart';

LineCheck one(String line) => checkLines([line]).single;

void main() {
  group('reading units', () {
    test('what follows a number', () {
      expect(readUnits(r'9.81 m/s^2')?.clean, '9.81');
      expect(readUnits(r'0.5 kg')?.clean, '0.5');
      expect(readUnits(r'5 cm')?.clean, r'5 \cdot 10^{-2}');
      expect(readUnits(r'2 km')?.clean, r'2 \cdot 10^{3}');
      expect(readUnits(r'100 g')?.clean, isNull, reason: 'a lone g is a quantity until something shows it is a unit');
      expect(readUnits(r'100 g + 2 kg')?.clean, r'100 \cdot 10^{-3} + 2');
      expect(readUnits(r'0.5\,\mathrm{kg}')?.clean, '0.5');
      expect(readUnits(r'3 \cdot 10^{8}\,\mathrm{m/s}')?.clean, r'3 \cdot 10^{8}');
      expect(readUnits(r'12 kg \, m / s^2')?.clean, '12');
      expect(readUnits(r'7 \frac{kg}{m^3}')?.clean, '7');
    });

    test('letters that are quantities stay as they are', () {
      expect(readUnits(r'2 m a'), isNull);
      expect(readUnits(r'0.5 m v^2'), isNull);
      expect(readUnits(r'0.5 kg \cdot m v^2')?.clean, isNotNull);
      expect(readUnits(r'0.5 kg + 0.5 m v^2')?.clean, '0.5 + 0.5 m v^2');
      expect(readUnits(r'3 m + 2 m'), isNull, reason: 'nothing shows these are units; as letters they add up just as well');
      expect(readUnits(r'x = 3'), isNull);
      expect(readUnits(r'\frac{1}{2} m v^2'), isNull);
    });

    test('the units as numbers of base units', () {
      final r = readUnits(r'4.81 N + 2 kg')!;
      expect(r.dims, contains('Q_{u0}^{1}'));
      expect(r.dims, contains('Q_{u1}^{1}'));
      expect(r.dims, contains('Q_{u2}^{-2}'));
      expect(unitTex([1, 1, -2, 0, 0, 0]), r'\mathrm{N}');
      expect(unitTex([0, 1, -1, 0, 0, 0]), r'\mathrm{m/s}');
      expect(unitTex([1, 2, -3, 0, -1, 0]), r'\mathrm{kg\,m^{2}/(s^{3}\,K)}');
    });
  });

  group('the checker with units', () {
    test('the sheet: a sum with units that is right', () {
      expect(one(r'0.5 kg \cdot (9.81 m/s^2 - 0.192 m/s^2) \approx 4.81 N').verdict, Verdict.rounded);
      expect(one(r'2F_z = m(g-a) = 0.5kg \cdot (9.81 m/s^2 - 0.192 m/s^2) \approx 4.81 N').verdict, Verdict.rounded);
      expect(one(r'0.5\,\mathrm{kg} \cdot (9.81\,\mathrm{m/s^2} - 0.192\,\mathrm{m/s^2}) \approx 4.81\,\mathrm{N}').verdict, Verdict.rounded);
    });

    test('the sheet: a root with units', () {
      expect(one(r'v = \sqrt{2 \cdot 0.192 m/s^2 \cdot 0.5 m} \approx 0.438 m/s').verdict, Verdict.rounded);
      expect(one(r'\sqrt{2 \cdot 0.192 m/s^2 \cdot 0.5 m} \approx 0.5 m/s').verdict, Verdict.wrong);
    });

    test('the sum is wrong', () {
      final c = one(r'0.5 kg \cdot (9.81 m/s^2 - 0.192 m/s^2) \approx 5.81 N');
      expect(c.verdict, Verdict.wrong);
      expect(c.reason, Reason.arithmetic);
    });

    test('units that do not fit', () {
      final c = one(r'0.5 kg \cdot (9.81 m/s^2 - 0.192 m/s^2) \approx 4.81 J');
      expect(c.verdict, Verdict.wrong);
      expect(c.reason, Reason.units);
      expect(c.counter, r'\mathrm{N} \neq \mathrm{J}');
      expect(one(r'9.81 m/s^2 - 0.192 kg = 9.618').reason, Reason.units);
      expect(one(r'3 m/s \cdot 2 s = 6 m').verdict, Verdict.right);
      expect(one(r'3 m/s \cdot 2 s = 6 m/s').reason, Reason.units);
    });

    test('other prefixes are the same quantity', () {
      expect(one(r'5 cm = 0.05 m').verdict, Verdict.right);
      expect(one(r'2 km = 2000 m').verdict, Verdict.right);
      expect(one(r'100 g = 0.1 kg').verdict, Verdict.right);
      expect(one(r'1 kPa = 1000 Pa').verdict, Verdict.right);
      expect(one(r'5 cm = 0.5 m').verdict, Verdict.wrong);
      expect(one(r'5 cm = 0.05 kg').reason, Reason.units);
      expect(one(r'1 N = 1 kg \cdot m/s^2').verdict, Verdict.right);
      expect(one(r'1 kJ = 1000 N \cdot m').verdict, Verdict.right);
      expect(one(r'1 J = 1 N \cdot m').verdict, isNull, reason: 'nothing here shows N and J are units and not quantities');
      expect(one(r'2N + 1 = 2N + 1').verdict, Verdict.right);
      expect(one(r'1 W = 1 J/s').verdict, Verdict.right);
    });

    test('a side with letters, or with no units, is not judged on its units', () {
      expect(one(r'F = 0.5 kg \cdot 9.81 m/s^2').reason, isNot(Reason.units));
      // (a number that has lost its unit on the way, `0.5 kg \cdot 9.81 = 4.905 N`, is a mismatch of units: that is what is said)
      expect(one(r'0.5 kg \cdot 9.81 = 4.905 N').reason, Reason.units);
      expect(one(r'\sin(2 s) = 0.909').reason, isNot(Reason.units));
    });

    test('lines without units are not touched', () {
      expect(one(r'17 \cdot 24 = 408').verdict, Verdict.right);
      expect(one(r'2 m a = 2 a m').verdict, Verdict.right);
      expect(one(r'x = 2 m').verdict, isNull);
      expect(one(r'\frac{1}{2} m v^2 = \frac{m v^2}{2}').verdict, Verdict.right);
    });
  });
}
