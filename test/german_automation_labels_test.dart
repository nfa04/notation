import 'package:flutter_test/flutter_test.dart';
import 'package:notes/automations/automation.dart';
import 'package:notes/l10n/german.dart';

/// The labels of events, actions and their settings are constants that the dialog passes through `tr`, which the search of
/// german_coverage_test.dart cannot see: this looks them up directly.
void main() {
  test('the labels, placeholders and settings of the automations are in the German table', () {
    final missing = <String>{};
    void need(String? t) {
      if (t == null || t.isEmpty || !RegExp(r'[A-Za-z]{3}').hasMatch(t) || t.contains(r'$')) return;
      if (!germanTexts.containsKey(t)) missing.add(t);
    }

    for (final e in AutomationEvent.values) {
      need(e.label);
      for (final (_, what) in e.placeholders) {
        need(what);
      }
    }
    for (final a in AutomationAction.values) {
      need(a.label);
      for (final f in a.fields) {
        need(f.label);
        need(f.help);
        // titles and texts start from a template of the rule, which is a value and not shown as a text
        if (f.kind == FieldKind.choice) {
          f.choices.values.forEach(need);
        }
      }
    }
    expect(missing, isEmpty, reason: 'add these to lib/l10n/german.dart:\n${missing.join('\n')}');
  });
}
