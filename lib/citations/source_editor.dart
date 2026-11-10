import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';
import 'citation_service.dart';
import 'source.dart';
import '../style/platform_dialog.dart';

/// "Smith, John" per line → people. A line with no comma and several words is read as "John Smith".
List<Person> _people(String text) => [
      for (final line in text.split('\n'))
        if (line.trim().isNotEmpty) Person.parse(line),
    ];

String _lines(List<Person> people) => people.map((p) => p.inverted).join('\n');

/// A form to enter or change a source. [source] null: a new one ([initial] may fill it in, from a lookup). Returns what was
/// saved, or null when cancelled.
Future<CitationSource?> showSourceEditor(BuildContext context, CitationService service, {CitationSource? source, CitationSource? initial}) {
  return showDialog<CitationSource>(
    context: context,
    builder: (_) => _SourceEditor(service: service, source: source, initial: initial),
  );
}

class _SourceEditor extends StatefulWidget {
  final CitationService service;
  final CitationSource? source;
  final CitationSource? initial;

  const _SourceEditor({required this.service, this.source, this.initial});

  @override
  State<_SourceEditor> createState() => _SourceEditorState();
}

class _SourceEditorState extends State<_SourceEditor> {
  late final CitationSource _from = widget.source ?? widget.initial ?? const CitationSource(id: '', title: '');
  late SourceType _type = _from.type;
  late final _key = TextEditingController(text: _from.id);
  late final _title = TextEditingController(text: _from.title);
  late final _authors = TextEditingController(text: _lines(_from.authors));
  late final _editors = TextEditingController(text: _lines(_from.editors));
  late final _year = TextEditingController(text: _from.year?.toString() ?? '');
  late final _month = TextEditingController(text: _from.month?.toString() ?? '');
  late final _day = TextEditingController(text: _from.day?.toString() ?? '');
  late final _container = TextEditingController(text: _from.container);
  late final _publisher = TextEditingController(text: _from.publisher);
  late final _place = TextEditingController(text: _from.place);
  late final _volume = TextEditingController(text: _from.volume);
  late final _issue = TextEditingController(text: _from.issue);
  late final _pages = TextEditingController(text: _from.pages);
  late final _edition = TextEditingController(text: _from.edition);
  late final _doi = TextEditingController(text: _from.doi);
  late final _url = TextEditingController(text: _from.url);
  late final _isbn = TextEditingController(text: _from.isbn);
  late final _accessed = TextEditingController(text: _from.accessed);
  String? _error;

  @override
  void dispose() {
    for (final c in [_key, _title, _authors, _editors, _year, _month, _day, _container, _publisher, _place, _volume, _issue, _pages, _edition, _doi, _url, _isbn, _accessed]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _containerLabel => switch (_type) {
        SourceType.article => 'Journal',
        SourceType.chapter => 'Book',
        SourceType.conference => 'Conference or proceedings',
        SourceType.webpage => 'Web site',
        _ => 'Series or container',
      };

  Widget _field(TextEditingController c, String label, {int lines = 1, TextInputType? type, String? hint, Key? key}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          key: key,
          controller: c,
          minLines: 1,
          maxLines: lines,
          keyboardType: type,
          decoration: InputDecoration(labelText: tr(label), hintText: hint == null ? null : tr(hint), border: const OutlineInputBorder(), isDense: true),
        ),
      );

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = tr('A source needs a title.'));
      return;
    }
    var key = _key.text.trim();
    final others = {for (final s in widget.service.sources) if (s.id != widget.source?.id) s.id};
    if (key.isNotEmpty && !RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_:.\-/]*$').hasMatch(key)) {
      setState(() => _error = tr('A key has letters, digits and _ : . - only.'));
      return;
    }
    if (others.contains(key)) {
      setState(() => _error = tr('Another source has this key.'));
      return;
    }
    final built = CitationSource(
      id: key,
      type: _type,
      title: title,
      authors: _people(_authors.text),
      editors: _people(_editors.text),
      year: int.tryParse(_year.text.trim()),
      month: int.tryParse(_month.text.trim())?.clamp(1, 12),
      day: int.tryParse(_day.text.trim())?.clamp(1, 31),
      container: _container.text.trim(),
      publisher: _publisher.text.trim(),
      place: _place.text.trim(),
      volume: _volume.text.trim(),
      issue: _issue.text.trim(),
      pages: _pages.text.trim(),
      edition: _edition.text.trim(),
      doi: _doi.text.trim().replaceFirst(RegExp(r'^https?://(dx\.)?doi\.org/'), ''),
      url: _url.text.trim(),
      isbn: _isbn.text.trim(),
      accessed: _accessed.text.trim(),
    );
    if (key.isEmpty) key = widget.service.freeKey(built);
    Navigator.pop(context, built.copyWith(id: key));
  }

  @override
  Widget build(BuildContext context) {
    final isArticle = _type == SourceType.article;
    final inBook = _type == SourceType.chapter || _type == SourceType.conference;
    return PlatformAlertDialog(
      title: Text(widget.source == null ? 'Add a source' : 'Edit the source'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: DropdownButtonFormField<SourceType>(
                key: const ValueKey('source-type'),
                initialValue: _type,
                decoration: InputDecoration(labelText: tr('Kind of source'), border: const OutlineInputBorder(), isDense: true),
                items: [for (final t in SourceType.values) DropdownMenuItem(value: t, child: Text.verbatim(tr(t.title)))],
                onChanged: (t) => setState(() => _type = t ?? _type),
              ),
            ),
            _field(_title, 'Title', lines: 3, key: const ValueKey('source-title')),
            _field(_authors, 'Authors', lines: 6, hint: 'One per line: Family, Given', key: const ValueKey('source-authors')),
            Row(children: [
              Expanded(flex: 2, child: _field(_year, 'Year', type: TextInputType.number, key: const ValueKey('source-year'))),
              const SizedBox(width: 8),
              Expanded(child: _field(_month, 'Month', type: TextInputType.number)),
              const SizedBox(width: 8),
              Expanded(child: _field(_day, 'Day', type: TextInputType.number)),
            ]),
            if (_type != SourceType.book && _type != SourceType.thesis && _type != SourceType.report) _field(_container, _containerLabel),
            if (inBook || _type == SourceType.book) _field(_editors, 'Editors', lines: 4, hint: 'One per line: Family, Given'),
            if (!isArticle) _field(_publisher, _type == SourceType.thesis ? 'University' : 'Publisher'),
            if (!isArticle && _type != SourceType.webpage) _field(_place, 'Place of publication'),
            if (isArticle) Row(children: [
              Expanded(child: _field(_volume, 'Volume')),
              const SizedBox(width: 8),
              Expanded(child: _field(_issue, 'Issue')),
            ]),
            if (isArticle || inBook) _field(_pages, 'Pages', hint: '12-34'),
            if (_type == SourceType.book || _type == SourceType.report) _field(_edition, 'Edition', hint: '2nd'),
            _field(_doi, 'DOI', key: const ValueKey('source-doi')),
            _field(_url, 'Web address', type: TextInputType.url),
            if (_type == SourceType.book) _field(_isbn, 'ISBN'),
            if (_type == SourceType.webpage) _field(_accessed, 'Read on', hint: 'YYYY-MM-DD'),
            _field(_key, 'Key', hint: 'Left empty, one is made (smith2020)', key: const ValueKey('source-key')),
            if (_error != null) Text.verbatim(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('source-save'), onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
