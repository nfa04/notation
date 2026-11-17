import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/markdown/chat_markdown.dart';
import 'package:notes/screens/assistant_panel.dart';

void main() {
  test('formulas as models write them become the Markdown the app draws', () {
    expect(chatMarkdown(r'The area is \(\pi r^2\).'), r'The area is $\pi r^2$.');
    expect(chatMarkdown('So\n\\[\n  a^2 + b^2 = c^2\n\\]\nholds.'), 'So\n\n\$\$a^2 + b^2 = c^2\$\$\n\nholds.');
    expect(chatMarkdown('So\n\$\$\n\\frac{1}{2}\n\$\$\nend'), 'So\n\n\$\$\\frac{1}{2}\$\$\n\nend');
    expect(chatMarkdown(r'inline $$x$$ stays'), r'inline $$x$$ stays');
    expect(chatMarkdown(r'Already $x$ and **bold**'), r'Already $x$ and **bold**');
    expect(chatMarkdown('a\r\nb'), 'a\nb');
  });

  testWidgets('an answer shows its formulas drawn, inline and on a line of their own, and its Markdown', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: ChatText('**Pythagoras**: \\(a^2+b^2=c^2\\), so\n\\[c = \\sqrt{a^2+b^2}\\]', color: Colors.black)),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Math), findsNWidgets(2));
    expect(find.textContaining(r'\('), findsNothing);
    expect(find.textContaining('**'), findsNothing);
    // a formula that cannot be read shows what was written
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ChatText(r'Broken $\frac{1$ here', color: Colors.black))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
