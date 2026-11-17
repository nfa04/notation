# Translating the app

The words of the app are written in English in the code. Each language is one table, English text → text in that language, in
`lib/l10n/<language>.dart` (German: `german.dart`). A text that a table does not have is shown in English, so a table can be
filled in over time.

## Filling in a language that is started

`french.dart`, `spanish.dart` and `italian.dart` exist and are empty. While a table is empty its language is not offered in the
settings; the first entry makes it appear.

```
dart run tool/translation_todo.dart fr            # what is missing, as JSON {"English": ""}
dart run tool/translation_todo.dart fr --german   # the same with the German text as a hint
dart run tool/translation_todo.dart fr --dart     # the same as lines for the table:  'English': '',
dart run tool/translation_todo.dart fr --check    # problems in what was written
flutter test test/l10n_languages_test.dart        # the same check, for every language
```

The English texts are the keys of `germanTexts`; `test/german_coverage_test.dart` keeps that table complete, so it is the list of
everything the app says.

## Rules for an entry

* The key is the English text exactly as it is in the table of German. Do not change it.
* `{n}`, `{name}`, ... are filled in by the app: keep each one, spelled the same, once or as often as the English has it.
* Keep the line breaks (`\n`) and the Markdown (`**`, `` ` ``) of the English; keep names of things in the app as they are written in the
  English where they are proper names (Notation, Nextcloud).
* Counts are two entries in the code (`trCount`: one and many, both with `{n}`), so write both. Languages that have more forms of a
  plural than that need a change in `trCount`; ask before working around it in the texts.
* A key that is not in the table of German is dropped by `--check` as stale: a text that was reworded in the code is a new key.

## Adding a language that has no file yet

1. Make `lib/l10n/<language>.dart` with `const <language>Texts = <String, String>{};` (copy `french.dart`).
2. Add a `LanguageEntry('<code>', '<name in that language>', <language>Texts)` to `languageEntries` in `lib/l10n/language.dart`.
3. Add it to `_tables` in `tool/translation_todo.dart`.
4. A language written right to left (Arabic, Hebrew) also needs the layout checked; the app has not been tried that way.

Flutter's own widgets (date pickers, the Material texts) come with Flutter's localizations for the language; they are there for
French, Spanish and Italian.
