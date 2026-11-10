import 'package:flutter/material.dart' hide Text;
import 'package:notes/l10n/text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/citations/citation_document.dart';
import 'package:notes/citations/citation_repository.dart';
import 'package:notes/citations/citation_service.dart';
import 'package:notes/citations/citation_style.dart';
import 'package:notes/citations/cite_picker.dart';
import 'package:notes/citations/source.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/markdown/markdown_parser.dart';
import 'package:notes/markdown/markdown_view.dart';
import 'package:notes/models/rich_text.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const smith = CitationSource(id: 'smith2020', type: SourceType.article, title: 'Alpha', authors: [Person('Smith', 'J')], year: 2020, container: 'J');
const doe = CitationSource(id: 'doe2019', title: 'Beta', authors: [Person('Doe', 'J')], year: 2019, publisher: 'P');

void main() {
  setUpAll(AppDatabase.initFfi);

  late Database db;
  late CitationService service;

  setUp(() async {
    db = await AppDatabase.open(path: inMemoryDatabasePath);
    service = CitationService(CitationRepository(SettingsRepository(db)));
    await service.add(smith);
    await service.add(doe);
  });
  tearDown(() => db.close());

  group('changing a citation in the text', () {
    test('the citation under the cursor is found, in it or right after it', () {
      const text = 'See [@smith2020, p. 4] and more.';
      expect(citationAround(text, 10)!.items.single.key, 'smith2020');
      expect(citationAround(text, 22)!.items.single.key, 'smith2020'); // right after the bracket
      expect(citationAround(text, 2), isNull);
      expect(citationAround(text, 28), isNull);
    });

    test('it is replaced where it stands, or taken out with the space before it', () {
      const text = 'See [@smith2020, p. 4] and more.';
      final mark = citationAround(text, 10)!;
      const value = TextEditingValue(text: text);
      expect(replaceCitation(value, mark, '[@doe2019; @smith2020]').text, 'See [@doe2019; @smith2020] and more.');
      expect(replaceCitation(value, mark, '').text, 'See and more.');
    });
  });

  test('the line goes on lines of its own wherever the cursor is', () {
    TextEditingValue at(String text, int offset) => withBibliography(TextEditingValue(text: text, selection: TextSelection.collapsed(offset: offset)));
    expect(at('', 0).text, '[bibliography]');
    expect(at('end', 3).text, 'end\n\n[bibliography]');
    expect(at('a\nb', 2).text, 'a\n\n[bibliography]\n\nb');
    expect(at('ab', 1).text, 'a\n\n[bibliography]\n\nb');
    expect(at('ab', 1).selection.baseOffset, 'a\n\n[bibliography]'.length);
  });

  group('the bibliography line', () {
    test('is a block of its own, other brackets are not', () {
      expect(parseMarkdown('[bibliography]').single.type, MdBlockType.bibliography);
      expect(parseMarkdown('  [bibliography]  ').single.type, MdBlockType.bibliography);
      expect(parseMarkdown('see [bibliography] here').single.type, MdBlockType.paragraph);
    });
  });

  Widget app(List<RichInlineTextController> controllers, {String Function()? whole, ValueChanged<MdRun>? onCitation, bool bibliography = false, String? style}) => MaterialApp(
        home: CitationScope(
          service: service,
          child: CitationStyleScope(
            style: style == null ? null : citationStyleById(style),
            wholeText: whole,
            child: Scaffold(
              body: Column(children: [
                for (final c in controllers) MarkdownView(controller: c, fontSize: 16, onCitation: onCitation, bibliography: bibliography),
              ]),
            ),
          ),
        ),
      );

  testWidgets('a tapped citation says which one it is and what it cites', (tester) async {
    final c = RichInlineTextController()..text = 'Claim [@smith2020, p. 4] and [@doe2019].';
    final tapped = <MdRun>[];
    await tester.pumpWidget(app([c], onCitation: tapped.add));
    expect(find.text('(Smith, 2020, p. 4)', findRichText: true), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('citation-6')));
    expect(tapped.single.text, '[@smith2020, p. 4]');
    expect(tapped.single.src, 6);
    expect(tapped.single.cite!.single.key, 'smith2020');
    expect(tapped.single.cite!.single.locator!.text(), 'p. 4');
  });

  testWidgets('without a handler the citation is plain text', (tester) async {
    final c = RichInlineTextController()..text = 'Claim [@smith2020].';
    await tester.pumpWidget(app([c]));
    expect(find.byKey(const ValueKey('citation-6')), findsNothing);
    expect(find.textContaining('(Smith, 2020)', findRichText: true), findsOneWidget);
  });

  testWidgets('the texts of a note are numbered and listed as one', (tester) async {
    final a = RichInlineTextController()..text = 'First [@doe2019].';
    final b = RichInlineTextController()..text = 'Then [@smith2020] and [@doe2019].\n[bibliography]';
    // a note's boxes in order: what the first box cites comes first
    await tester.pumpWidget(app([a, b], whole: () => '${a.text}\n${b.text}', style: 'ieee'));
    expect(find.textContaining('First [1].', findRichText: true), findsOneWidget);
    expect(find.textContaining('Then [2] and [1].', findRichText: true), findsOneWidget);
    // the line puts the list where it stands, in the order of first use
    expect(find.textContaining('References', findRichText: true), findsOneWidget);
    expect(find.textContaining('[1] J. Doe', findRichText: true), findsOneWidget);
    expect(find.textContaining('[2] J. Smith', findRichText: true), findsOneWidget);
  });

  testWidgets('the line puts the list where it stands, and the document does not list it again', (tester) async {
    final c = RichInlineTextController()..text = '[bibliography]\n\nClaim [@smith2020].';
    await tester.pumpWidget(app([c], bibliography: true));
    expect(find.textContaining('References', findRichText: true), findsOneWidget);
  });

  testWidgets('with no source cited the line stays as written', (tester) async {
    final c = RichInlineTextController()..text = '[bibliography]';
    await tester.pumpWidget(app([c]));
    expect(find.text('[bibliography]'), findsOneWidget);
  });

  testWidgets('the sheet opens with what the citation cites and returns the changed one', (tester) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showCitePicker(context, service, editing: const [CiteRef('smith2020')]),
            child: const Text.verbatim('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Change the citation'), findsOneWidget);
    expect(find.byKey(const ValueKey('cite-locator-smith2020')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('cite-locator-smith2020')), '12-14');
    await tester.tap(find.byKey(const ValueKey('cite-doe2019')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cite-insert')));
    await tester.pumpAndSettle();
    expect(result, '[@smith2020, pp. 12–14; @doe2019]');
  });

  testWidgets('and offers to take the citation out', (tester) async {
    String? result = 'unchanged';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showCitePicker(context, service, editing: const [CiteRef('smith2020')]),
            child: const Text.verbatim('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cite-remove')));
    await tester.pumpAndSettle();
    expect(result, '');
  });
}
