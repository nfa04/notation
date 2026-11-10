import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/device_budget.dart';

/// When a device says it should not take over a session.
void main() {
  DeviceBudget budget() => DeviceBudget(() async => const BudgetReading());

  test('a battery at or below 20 percent that is not charging', () {
    final b = budget();
    b.take(const BudgetReading(batteryPercent: 50, charging: false));
    expect(b.value, isNull);
    b.take(const BudgetReading(batteryPercent: 21, charging: false));
    expect(b.value, isNull);
    b.take(const BudgetReading(batteryPercent: 20, charging: false));
    expect(b.value, 'battery');
    b.dispose();
  });

  test('fine again on the charger at once, or without it only at 30 percent', () {
    final b = budget()..take(const BudgetReading(batteryPercent: 15, charging: false));
    expect(b.value, 'battery');
    b.take(const BudgetReading(batteryPercent: 25, charging: false));
    expect(b.value, 'battery', reason: 'between the limits it stays as it was');
    b.take(const BudgetReading(batteryPercent: 30, charging: false));
    expect(b.value, isNull);
    b.take(const BudgetReading(batteryPercent: 25, charging: false));
    expect(b.value, isNull, reason: 'and the other way round too');
    b.take(const BudgetReading(batteryPercent: 10, charging: false));
    b.take(const BudgetReading(batteryPercent: 10, charging: true));
    expect(b.value, isNull);
    b.dispose();
  });

  test('a metered network; a low battery is the reason given before it', () {
    final b = budget()..take(const BudgetReading(metered: true));
    expect(b.value, 'metered');
    b.take(const BudgetReading(batteryPercent: 5, charging: false, metered: true));
    expect(b.value, 'battery');
    b.take(const BudgetReading(batteryPercent: 80, charging: false, metered: false));
    expect(b.value, isNull);
    b.dispose();
  });

  test('nothing known (a desktop, a browser): never', () {
    final b = budget()..take(const BudgetReading());
    expect(b.value, isNull);
    b.dispose();
  });

  test('looks now and then, and tells its listeners of a change only', () async {
    var percent = 50;
    final b = DeviceBudget(() async => BudgetReading(batteryPercent: percent, charging: false), every: const Duration(milliseconds: 20));
    final heard = <String?>[];
    b.addListener(() => heard.add(b.value));
    b.start();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    percent = 10;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    b.dispose();
    expect(heard, ['battery']);
  });

  test('a reading that fails changes nothing', () async {
    final b = DeviceBudget(() async => throw StateError('no battery service'));
    await b.look();
    expect(b.value, isNull);
    b.dispose();
  });
}
