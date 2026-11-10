import 'dart:typed_data';
import '../l10n/language.dart';
import '../models/canvas_models.dart';
import '../models/image_item.dart';
import '../models/layers.dart';
import '../models/page_background.dart';
import '../models/page_format.dart';
import '../models/pdf_models.dart';
import '../models/rich_text.dart';

/// Row of the dashboard list.
class NoteSummary {
  final String id;
  final String title;
  final DateTime updatedAt;
  final bool isPdf;
  final String? folderId;

  /// Path of the note's banner image, if any.
  final String? themeImage;

  /// Starred by the person.
  final bool favorite;

  /// 0 not locked, 1 locked with a passcode, 2 encrypted (see `NoteLockService`).
  final int lockMode;

  bool get locked => lockMode != 0;

  /// What the lists call the note: its title, or that it is locked (a locked note shows nothing of itself).
  String get shownTitle => locked ? tr('Locked note') : (title.isEmpty ? tr('Untitled') : title);

  const NoteSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.isPdf,
    this.folderId,
    this.themeImage,
    this.favorite = false,
    this.lockMode = 0,
  });
}

/// A passage of a note, with the vector that tells what it is about (null when no model was there to read it).
class StoredChunk {
  final int? page;
  final String label;
  final String text;
  final Float32List? vector;
  const StoredChunk(this.page, this.label, this.text, this.vector);
}

/// Something the AI made of a note, kept with it: [kind] says what ('summary', 'presentation', ...), [key] tells apart several of a kind.
class NoteAiRow {
  final String noteId;
  final String kind;
  final String key;
  final String content;

  /// A hash of the text of the note when this was made; differs from the note's now when the note has changed since.
  final int sourceHash;
  final String model;
  final DateTime createdAt;

  const NoteAiRow({required this.noteId, required this.kind, this.key = '', required this.content, this.sourceHash = 0, this.model = '', required this.createdAt});
}

/// A fact taken from a note, for the graph view.
class StoredFact {
  final int? id;
  final String noteId;
  final int? page;
  final String title;
  final String tag;
  final String sentence;
  final List<String> keywords;
  final Float32List? vector;
  const StoredFact({this.id, required this.noteId, this.page, required this.title, this.tag = 'Fact', required this.sentence, this.keywords = const [], this.vector});
}

/// A note in the trash.
class TrashedNote {
  final String id;
  final String title;
  final DateTime deletedAt;
  final bool isPdf;
  final int lockMode;
  const TrashedNote({required this.id, required this.title, required this.deletedAt, required this.isPdf, this.lockMode = 0});
  String get shownTitle => lockMode != 0 ? tr('Locked note') : (title.isEmpty ? tr('Untitled') : title);
}

/// A template the person saved.
class SavedTemplate {
  final String id;
  final String name;
  final DateTime created;
  const SavedTemplate(this.id, this.name, this.created);
}

/// A folder with the number of notes directly inside it.
class FolderEntry {
  final String id;
  final String? parentId;
  final String name;
  final int noteCount;

  /// Path of the banner image shown at the top of the folder, if any.
  final String? themeImage;

  const FolderEntry({
    required this.id,
    required this.parentId,
    required this.name,
    required this.noteCount,
    this.themeImage,
  });
}

/// Everything stored for one note, in the editor's own model types.
class NoteData {
  final String id;
  String title;
  PageBackground background;
  PageFormat pageFormat;
  String? themeImage;

  /// Banner of the note's folder, shown while the note has none (not saved).
  String? folderThemeImage;
  bool landscape;
  double marginLeft;
  double marginRight;
  double marginTop;
  double marginBottom;
  String documentText;
  List<TextSpanAttribute> documentSpans;

  String? pdfName;
  String? pdfPath;
  String? pdfSha256;
  int? pdfPageCount;

  /// The pages (zero-based) of the PDF that are notebook pages: added ones, which show the note's paper instead of what the file has.
  Set<int> nativePages;

  /// The layers lines are drawn on (see `layers.dart`).
  LayerStack layers;

  Map<int, List<DrawingStroke>> strokes;
  Map<int, List<TextBoxWidgetModel>> textBoxes;
  Map<int, List<PdfHighlight>> highlights;
  Map<int, List<ImageItem>> images;

  NoteData({
    required this.id,
    this.title = '',
    this.background = PageBackground.blank,
    this.pageFormat = PageFormat.a4,
    this.themeImage,
    this.folderThemeImage,
    this.landscape = false,
    this.marginLeft = 56,
    this.marginRight = 56,
    this.marginTop = 56,
    this.marginBottom = 56,
    this.documentText = '',
    List<TextSpanAttribute>? documentSpans,
    this.pdfName,
    this.pdfPath,
    this.pdfSha256,
    this.pdfPageCount,
    Set<int>? nativePages,
    this.layers = LayerStack.plain,
    Map<int, List<DrawingStroke>>? strokes,
    Map<int, List<TextBoxWidgetModel>>? textBoxes,
    Map<int, List<PdfHighlight>>? highlights,
    Map<int, List<ImageItem>>? images,
  })  : documentSpans = documentSpans ?? [],
        nativePages = nativePages ?? {},
        strokes = strokes ?? {},
        textBoxes = textBoxes ?? {},
        highlights = highlights ?? {},
        images = images ?? {};
}
