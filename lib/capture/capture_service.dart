import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/note_repository.dart';
import '../data/pdf_note.dart';
import '../l10n/language.dart';
import '../models/image_item.dart';
import '../util/public_host.dart';
import 'article.dart';

/// A note that capturing made.
class Captured {
  final String noteId;
  final String title;

  /// What it was: `note` (typed or shared text), `clip` (a selection of a page), `page` (a web page), `pdf`, `picture`.
  final String kind;

  /// The address it came from, for a page or a clip.
  final String url;

  /// The name of the site or the author, when the page says.
  final String site;

  const Captured(this.noteId, this.title, {this.kind = 'note', this.url = '', this.site = ''});
}

/// Gets text, web pages and files into the app from outside: a note typed in a moment, a page clipped from a browser, something
/// shared from another app. They land in an Inbox folder, to be sorted later.
class CaptureService {
  final NoteRepository repository;
  final Future<Directory> Function() _support;
  final Future<String> Function(Uri url) _fetch;
  final DateTime Function() _now;

  /// Told about every note that capturing made, once it is complete (what an automation reacts to).
  void Function(Captured captured)? onCaptured;

  CaptureService({
    required this.repository,
    Future<Directory> Function()? supportDirectory,
    Future<String> Function(Uri url)? fetch,
    DateTime Function()? clock,
  })  : _support = supportDirectory ?? getApplicationSupportDirectory,
        _fetch = fetch ?? fetchPage,
        _now = clock ?? DateTime.now;

  /// The folder captured notes go to; made the first time.
  Future<String> inboxFolder() async {
    final names = {'Inbox', tr('Inbox')};
    for (final f in await repository.listFolders()) {
      if (f.parentId == null && names.contains(f.name)) return f.id;
    }
    return repository.createFolder(tr('Inbox'));
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  String _stamp() {
    final t = _now();
    return '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';
  }

  /// A title for [text]: its first line, cleaned of Markdown signs and cut short; null for text with no words.
  static String? titleOf(String text) {
    for (final line in text.split('\n')) {
      final t = line.replaceFirst(RegExp(r'^\s*(#{1,6}\s+|[-*+>]\s+|\d+\.\s+)'), '').replaceAll(RegExp(r'[*_`]'), '').trim();
      if (RegExp(r'\p{L}|\p{N}', unicode: true).hasMatch(t)) return t.length > 60 ? '${t.substring(0, 57).trimRight()}...' : t;
    }
    return null;
  }

  Captured _done(Captured c) {
    onCaptured?.call(c);
    return c;
  }

  Future<Captured> _make(String title, String markdown, {String? folderId, String kind = 'note', String url = '', String site = ''}) async {
    final id = await repository.createNote(title: title, folderId: folderId ?? await inboxFolder());
    final note = (await repository.loadNote(id))!;
    note.documentText = markdown;
    await repository.saveNote(note);
    return _done(Captured(id, title, kind: kind, url: url, site: site));
  }

  /// A note of [text] in the Inbox. [title] is what the sender called it (the subject of a shared text).
  Future<Captured> quickNote(String text, {String? title}) {
    final t = text.trim();
    final name = (title != null && title.trim().isNotEmpty ? title.trim() : titleOf(t)) ?? tr('Quick note {date}', {'date': _stamp()});
    return _make(name, '$t\n');
  }

  /// A note of what was selected on a web page, with where it comes from.
  Future<Captured> clipSelection({required Uri url, String? title, required String text}) {
    final name = (title != null && title.trim().isNotEmpty ? title.trim() : url.host);
    final quoted = text.trim().split('\n').map((l) => l.isEmpty ? '>' : '> $l').join('\n');
    return _make(name, '# $name\n\n${_source(url)}\n\n$quoted\n', kind: 'clip', url: '$url', site: url.host);
  }

  String _source(Uri url) => '${tr('Source: {url}', {'url': '<$url>'})}  \n${tr('Saved {date}', {'date': _stamp()})}';

  /// A note of the article on the web page at [url]. Throws when the page cannot be fetched or has no text.
  Future<Captured> clipPage(Uri url, {String? fallbackTitle}) async {
    if (url.scheme != 'http' && url.scheme != 'https') throw StateError(tr('Only web addresses (http or https) can be saved.'));
    final String source;
    try {
      source = await _fetch(url);
    } catch (e) {
      throw StateError(tr('The page could not be loaded: {error}', {'error': '$e'.replaceFirst('Bad state: ', '')}));
    }
    final article = extractArticle(source, url: url);
    if (article == null) throw StateError(tr('There is no text to save on that page.'));
    final title = article.title.isEmpty ? (fallbackTitle ?? url.host) : article.title;
    return _make(title, '# $title\n\n${_source(url)}${article.source == null ? '' : '  \n${article.source}'}\n\n${article.markdown}\n', kind: 'page', url: '$url', site: article.source ?? url.host);
  }

  /// Text another app shared: a web address alone is a page to clip, anything else is a note.
  Future<Captured> sharedText(String text, {String? subject}) {
    final t = text.trim();
    final uri = Uri.tryParse(t);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty && !t.contains(RegExp(r'\s'))) {
      return clipPage(uri, fallbackTitle: subject);
    }
    return quickNote(t, title: subject);
  }

  /// A file another app shared: a PDF becomes a note to write on, a picture a note with the picture on its first page, a text file a
  /// note of its text. Throws for anything else.
  Future<Captured> sharedFile(String path) async {
    final ext = p.extension(path).toLowerCase();
    // (a file the share of Android copied is called <time>-<name>)
    final name = p.basenameWithoutExtension(path).replaceFirst(RegExp(r'^\d{10,}-'), '');
    if (ext == '.pdf') {
      final folder = await inboxFolder();
      final id = await createNoteFromPdf(repository, path, folderId: folder, directory: Directory(p.join((await _support()).path, 'pdfs')));
      return _done(Captured(id, name, kind: 'pdf'));
    }
    if (const {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'}.contains(ext)) return _picture(path, name, ext);
    if (const {'.txt', '.md', '.markdown', ''}.contains(ext)) {
      final text = utf8.decode(await File(path).readAsBytes(), allowMalformed: true);
      return quickNote(text, title: name.isEmpty ? null : name);
    }
    throw StateError(tr('A file of this kind ({kind}) cannot be saved as a note.', {'kind': ext.isEmpty ? '?' : ext}));
  }

  Future<Captured> _picture(String path, String name, String ext) async {
    final bytes = await File(path).readAsBytes();
    final dir = await Directory(p.join((await _support()).path, 'images')).create(recursive: true);
    final copy = p.join(dir.path, '${_now().microsecondsSinceEpoch}$ext');
    await File(copy).writeAsBytes(bytes, flush: true);
    var size = const ui.Size(600, 400);
    try {
      final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
      final image = (await codec.getNextFrame()).image;
      final w = image.width.toDouble(), h = image.height.toDouble();
      image.dispose();
      codec.dispose();
      final scale = w > 688 ? 688 / w : 1.0;
      size = ui.Size(w * scale, h * scale);
    } catch (_) {
      // a picture that cannot be measured is given a size the person can change
    }
    final title = name.isEmpty ? tr('Picture {date}', {'date': _stamp()}) : name;
    final id = await repository.createNote(title: title, folderId: await inboxFolder());
    final note = (await repository.loadNote(id))!;
    note.images[0] = [ImageItem(id: NoteRepository.newId(), path: copy, position: const ui.Offset(56, 56), size: size)];
    await repository.saveNote(note);
    return _done(Captured(id, title, kind: 'picture'));
  }
}

/// Fetches a web page as text (at most 3 MB, in the character set the server names, else UTF-8). Every address it is sent on to is
/// checked like the first, so a page cannot lead the clipper into a private network.
Future<String> fetchPage(Uri url) async {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
    followRedirects: false,
    validateStatus: (s) => s != null && s < 400,
    responseType: ResponseType.stream,
    headers: {'User-Agent': 'Mozilla/5.0 (compatible; Notation web clipper)', 'Accept': 'text/html,application/xhtml+xml'},
  ));
  try {
    Response<ResponseBody> response;
    var at = url;
    for (var hop = 0;; hop++) {
      if (at.scheme != 'http' && at.scheme != 'https') throw StateError(tr('Only web addresses (http or https) can be saved.'));
      await checkPublicHost(at);
      response = await dio.getUri<ResponseBody>(at);
      final status = response.statusCode ?? 200;
      final next = response.headers.value('location');
      if (status < 300 || status >= 400 || next == null) break;
      await response.data?.stream.drain<void>();
      if (hop >= 5) throw StateError(tr('The page sends on too many times.'));
      at = at.resolve(next);
    }
    final type = response.headers.value('content-type') ?? '';
    if (type.isNotEmpty && !type.contains('html') && !type.contains('xml') && !type.contains('text')) {
      throw StateError(tr('That address is not a web page.'));
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.data!.stream) {
      bytes.add(chunk);
      if (bytes.length > 3 << 20) throw StateError(tr('The page is too big.'));
    }
    final charset = RegExp(r'charset=([\w-]+)', caseSensitive: false).firstMatch(type)?.group(1)?.toLowerCase();
    if (charset == 'iso-8859-1' || charset == 'latin1' || charset == 'windows-1252') return latin1.decode(bytes.takeBytes());
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  } finally {
    dio.close();
  }
}

/// The bookmarklet that saves the page it is used on (and the text selected on it) into the app: put it in the bookmarks bar of a
/// browser and press it on a page. The app asks before it saves anything.
const webClipperBookmarklet =
    "javascript:(function(){location.href='notation://clip?u='+encodeURIComponent(location.href)+'&t='+encodeURIComponent(document.title)+'&x='+encodeURIComponent(String(window.getSelection()).slice(0,20000));})();";
