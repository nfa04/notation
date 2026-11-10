
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:path_provider/path_provider.dart';

import '../data/card_repository.dart';
import '../data/note_repository.dart';
import '../export/anki_export.dart';
import '../export/anki_import.dart';
import '../ai/flashcards.dart';
import '../export/file_dialogs.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';

/// Saves the review cards (those of [source], a note; null: all) as an Anki package. Each note the cards are from becomes a deck of its
/// own, named after the note ([repository] knows the names).
Future<void> exportCardsToAnki(BuildContext context, CardRepository cards, {NoteRepository? repository, String? source}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final all = await cards.all(source: source);
    if (all.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('There are no cards to export'))));
      return;
    }
    final names = <String, String>{};
    for (final id in {for (final c in all) c.source}) {
      final info = id == CardRepository.graphSource || id.startsWith(ankiSourcePrefix) || repository == null ? null : await repository.noteInfo(id);
      final title = info?.title.trim() ?? '';
      names[id] = id.startsWith(ankiSourcePrefix) ? id.substring(ankiSourcePrefix.length) : id == CardRepository.graphSource ? tr('Facts of all notes') : (title.isEmpty ? tr('Untitled') : title);
    }
    final bytes = await ankiPackage([for (final c in all) AnkiCard.of(c, deck: names[c.source]!)], workDirectory: await getTemporaryDirectory());
    final path = await saveWithDialog(dialogTitle: tr('Export to Anki'), fileName: 'Notation cards.apkg', extension: 'apkg', bytes: bytes);
    if (path == null) return;
    messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Exported {n} cards to {path}', {'n': all.length, 'path': path}))));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Could not export the cards: {error}', {'error': e})), duration: const Duration(seconds: 8)));
  }
}

/// The source of cards that come from an Anki deck (the rest of it is the deck's name).
const ankiSourcePrefix = 'anki:';

/// Asks for an Anki package and keeps its cards for review, a deck at a time, with the schedule they had in Anki. Returns how many cards
/// were new (the same card imported twice is kept once), or null when nothing was imported.
Future<int?> importCardsFromAnki(BuildContext context, CardRepository cards) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['apkg']);
    if (picked.isEmpty) return null;
    final bytes = await picked.first.readAsBytes();
    final read = await readAnkiPackage(bytes, workDirectory: await getTemporaryDirectory());
    if (read.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('There are no cards in this package'))));
      return null;
    }
    var added = 0;
    // (a package made by this app has its own deck above the others: that name is not kept)
    String nameOf(String deck) => deck.startsWith('Notation::') ? deck.substring('Notation::'.length) : deck;
    for (final deck in {for (final c in read) nameOf(c.deck)}) {
      added += await cards.addScheduled('$ankiSourcePrefix$deck', [for (final c in read) if (nameOf(c.deck) == deck) (Flashcard(c.front, c.back), c.schedule)]);
    }
    messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Imported {n} new cards ({total} in the package)', {'n': added, 'total': read.length}))));
    return added;
  } on AnkiImportException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text.verbatim(tr(e.message)), duration: const Duration(seconds: 8)));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Could not import the cards: {error}', {'error': e})), duration: const Duration(seconds: 8)));
  }
  return null;
}
