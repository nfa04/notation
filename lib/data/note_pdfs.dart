import 'dart:convert';

/// One PDF file of a note: kept as it is, under its own name, in the app's storage.
class NotePdf {
  final String name;
  final String path;
  final String sha256;

  /// How many pages the file has.
  final int pages;

  const NotePdf({required this.name, required this.path, required this.sha256, required this.pages});

  NotePdf copyWith({String? path, String? sha256, int? pages}) => NotePdf(name: name, path: path ?? this.path, sha256: sha256 ?? this.sha256, pages: pages ?? this.pages);

  Map<String, Object?> toJson() => {'name': name, 'path': path, 'sha256': sha256, 'pages': pages};

  static NotePdf? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'], path = json['path'], sha = json['sha256'], pages = json['pages'];
    if (name is! String || path is! String || sha is! String || pages is! int || pages < 0) return null;
    return NotePdf(name: name, path: path, sha256: sha, pages: pages);
  }
}

/// What is on one page of a note with several PDFs: page [page] (zero-based) of file number [file], or a blank notebook page
/// ([file] is [blank]).
class PdfPageRef {
  static const _none = -1;
  final int file;
  final int page;
  const PdfPageRef(this.file, this.page);
  const PdfPageRef.blank() : this(_none, 0);

  bool get isBlank => file == _none;

  @override
  bool operator ==(Object other) => other is PdfPageRef && other.file == file && other.page == page;

  @override
  int get hashCode => Object.hash(file, page);

  @override
  String toString() => isBlank ? 'blank' : '$file:$page';
}

/// The PDFs of a note that has several, and which of their pages are shown in which order. The files are never changed by moving,
/// deleting or adding pages: only [layout] is. Page `n` of the note is `layout[n]`; a page of a file that is in no entry is
/// hidden (it is still in its file).
class NotePdfs {
  final List<NotePdf> files;
  final List<PdfPageRef> layout;

  NotePdfs(List<NotePdf> files, List<PdfPageRef> layout)
      : files = List.unmodifiable(files),
        layout = List.unmodifiable(layout);

  /// All the pages of [files], one file after the other.
  factory NotePdfs.inOrder(List<NotePdf> files) => NotePdfs(files, [
        for (var f = 0; f < files.length; f++)
          for (var p = 0; p < files[f].pages; p++) PdfPageRef(f, p),
      ]);

  int get pageCount => layout.length;

  /// The first page of each file (the page number of the first entry of it), or null for a file with no page shown.
  int? firstPageOf(int file) {
    final i = layout.indexWhere((r) => r.file == file);
    return i < 0 ? null : i;
  }

  NotePdfs withLayout(List<PdfPageRef> next) => NotePdfs(files, next);

  /// The same with [added] after the files there are, and their pages (all of them) put in as page [at] and on.
  NotePdfs adding(List<NotePdf> added, {required int at}) {
    final next = [...files, ...added];
    final refs = <PdfPageRef>[];
    for (var f = files.length; f < next.length; f++) {
      for (var p = 0; p < next[f].pages; p++) {
        refs.add(PdfPageRef(f, p));
      }
    }
    final i = at.clamp(0, layout.length);
    return NotePdfs(next, [...layout.sublist(0, i), ...refs, ...layout.sublist(i)]);
  }

  /// The same without file number [file] and its pages; the others are numbered again.
  NotePdfs removing(int file) => NotePdfs(
        [for (var f = 0; f < files.length; f++) if (f != file) files[f]],
        [for (final r in layout) if (r.file != file) r.isBlank ? r : PdfPageRef(r.file > file ? r.file - 1 : r.file, r.page)],
      );

  /// The same with the file [file] taken from another place (an edit of its pages).
  NotePdfs replacing(int file, NotePdf by) => NotePdfs([for (var f = 0; f < files.length; f++) f == file ? by : files[f]], layout);

  String toJsonText() => jsonEncode({
        'files': [for (final f in files) f.toJson()],
        'layout': [for (final r in layout) [r.file, r.page]],
      });

  /// What [toJsonText] wrote, or null when it is not a table that fits its files (every file used, every page in range, none twice).
  static NotePdfs? fromJsonText(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      return fromJson(jsonDecode(text));
    } catch (_) {
      return null;
    }
  }

  static NotePdfs? fromJson(Object? json) {
    if (json is! Map) return null;
    final rawFiles = json['files'], rawLayout = json['layout'];
    if (rawFiles is! List || rawLayout is! List || rawFiles.isEmpty) return null;
    final files = <NotePdf>[];
    for (final f in rawFiles) {
      final file = NotePdf.fromJson(f);
      if (file == null) return null;
      files.add(file);
    }
    final layout = <PdfPageRef>[];
    final seen = <PdfPageRef>{};
    for (final r in rawLayout) {
      if (r is! List || r.length != 2 || r[0] is! int || r[1] is! int) return null;
      final ref = PdfPageRef(r[0] as int, r[1] as int);
      if (ref.isBlank) {
        layout.add(const PdfPageRef.blank());
        continue;
      }
      if (ref.file < 0 || ref.file >= files.length || ref.page < 0 || ref.page >= files[ref.file].pages || !seen.add(ref)) return null;
      layout.add(ref);
    }
    if (layout.isEmpty) return null;
    return NotePdfs(files, layout);
  }
}
