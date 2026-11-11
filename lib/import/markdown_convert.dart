import '../markdown/mention.dart';
import 'path_index.dart';

/// A note (or PDF) of the import as the notes that link to it know it.
class PageRef {
  final String id;
  final String title;
  const PageRef(this.id, this.title);
}

/// What the conversion of one page needs to know and what it finds out: the pages and files links can point at, and what the page
/// asks for (tags, pictures) or lacks (links to something that is not in the import).
class ConvertEnv {
  final PathIndex<PageRef> pages;
  final PathIndex<String> files;

  /// The path of the page that is converted, in the source (links are relative to it).
  final String from;

  ConvertEnv({required this.pages, required this.files, required this.from, required this.pictures});

  /// The pictures of the whole import in the order they were asked for: a picture is written as [pictureMark] of its number until the
  /// import has kept the bytes and knows the target to write.
  final List<String> pictures;

  final tags = <String>{};

  /// What the page points at and the import does not hold: the names, once each.
  final missing = <String>{};

  /// Files the page points at that are no pictures (sound, video, Office files...) and are left out.
  final skippedFiles = <String>{};

  int links = 0;

  String _mark(String path) {
    var i = pictures.indexOf(path);
    if (i < 0) {
      pictures.add(path);
      i = pictures.length - 1;
    }
    return pictureMark(i);
  }
}

const _markStart = '\u0001';
const _markEnd = '\u0002';

/// The text that stands for the picture number [i] until its target is known.
String pictureMark(int i) => '${_markStart}P$i$_markEnd';

final pictureMarkPattern = RegExp('$_markStart' r'P(\d+)' '$_markEnd');

const pictureExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

String _extOf(String path) {
  final name = path.substring(path.lastIndexOf('/') + 1);
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/// Whether an ending is that of a file (`pdf`, `mp3`), not the end of a note's name ("Lecture 3.2 Graphs").
bool _looksLikeFile(String ext) => ext.isNotEmpty && ext.length <= 5 && RegExp(r'^[a-z][a-z0-9]*$').hasMatch(ext);

String _nameOf(String path) => path.substring(path.lastIndexOf('/') + 1);

final _fence = RegExp(r'^ {0,3}(`{3,}|~{3,})');
final _codeSpan = RegExp(r'`[^`]*`');
final _wikiLink = RegExp(r'(!?)\[\[([^\[\]\n]+?)\]\]');
final _markdownLink = RegExp(r'(!?)\[([^\]]*)\]\((<[^>]*>|[^()\s]*)(?:\s+"[^"]*")?\)');
final _callout = RegExp(r'^(\s*(?:>\s*)+)\[!([\w-]+)\][+-]?\s*(.*)$');
final _blockId = RegExp(r'\s\^[\w-]+\s*$');
final _inlineTag = RegExp(r'(?:^|(?<=\s))#([\p{L}\p{N}_\-/]*[\p{L}_\-/][\p{L}\p{N}_\-/]*)', unicode: true);
final _scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*:');

/// Text that is written the way Obsidian and Notion write Markdown, in the way this app reads it. The page is cut into lines and
/// every line outside code is looked at: links between notes become `[title](note:id)`, pictures become [pictureMark]s, `==`, `$`
/// and the rest are left as they are. With [wiki], `[[links]]` and `![[embeds]]` are read, and `#tags`, `%%comments%%`, callouts and
/// block ids are dealt with (Obsidian).
String convertMarkdown(String text, ConvertEnv env, {required bool wiki}) {
  var source = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll('﻿', '');
  if (wiki) source = _withoutComments(source);
  final lines = source.split('\n');
  final out = <String>[];
  String? fence;
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    final f = _fence.firstMatch(line);
    if (fence != null) {
      out.add(line);
      if (f != null && f.group(1)!.startsWith(fence[0]) && f.group(1)!.length >= fence.length && line.trim() == f.group(1)) fence = null;
      continue;
    }
    if (f != null) {
      fence = f.group(1);
      out.add(line);
      continue;
    }
    // a formula over several lines is one line here
    if (RegExp(r'\$\$').allMatches(line).length == 1) {
      final joined = <String>[line.trim()];
      var j = i + 1;
      while (j < lines.length && j < i + 40 && !lines[j].contains(r'$$')) {
        joined.add(lines[j].trim());
        j++;
      }
      if (j < lines.length && j < i + 40) {
        joined.add(lines[j].trim());
        out.add(joined.where((s) => s.isNotEmpty).join(' ').replaceAll(RegExp(r'\$\$\s+'), r'$$').replaceAll(RegExp(r'\s+\$\$'), r'$$'));
        i = j;
        continue;
      }
    }
    line = line.replaceFirstMapped(RegExp(r'^(\t+)'), (m) => '  ' * m.group(1)!.length);
    if (wiki) {
      final c = _callout.firstMatch(line);
      if (c != null) {
        final kind = c.group(2)!;
        final title = c.group(3)!.trim().isEmpty ? kind[0].toUpperCase() + kind.substring(1) : c.group(3)!.trim();
        line = '${c.group(1)}**$title**';
      }
      line = line.replaceFirst(_blockId, '');
    }
    out.add(_inlineLine(line, env, wiki));
  }
  return out.join('\n');
}

String _withoutComments(String text) {
  final out = StringBuffer();
  var inFence = false;
  final pending = StringBuffer();
  void flush() {
    if (pending.isEmpty) return;
    out.write(pending.toString().replaceAll(RegExp(r'%%[\s\S]*?%%'), ''));
    pending.clear();
  }

  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final isFence = _fence.hasMatch(lines[i]);
    if (isFence) {
      flush();
      inFence = !inFence;
      out.write(lines[i]);
    } else if (inFence) {
      out.write(lines[i]);
    } else {
      pending.write(lines[i]);
    }
    if (i < lines.length - 1) {
      if (isFence || inFence) {
        out.write('\n');
      } else {
        pending.write('\n');
      }
    }
  }
  flush();
  return out.toString();
}

String _inlineLine(String line, ConvertEnv env, bool wiki) {
  final out = StringBuffer();
  var at = 0;
  for (final m in _codeSpan.allMatches(line)) {
    out.write(_inlineText(line.substring(at, m.start), env, wiki));
    out.write(m.group(0));
    at = m.end;
  }
  out.write(_inlineText(line.substring(at), env, wiki));
  return out.toString();
}

String _inlineText(String s, ConvertEnv env, bool wiki) {
  if (wiki) {
    for (final m in _inlineTag.allMatches(s)) {
      env.tags.add(m.group(1)!);
    }
    s = s.replaceAllMapped(_wikiLink, (m) => _wikiTarget(m.group(1) == '!', m.group(2)!, env));
  }
  return s.replaceAllMapped(_markdownLink, (m) => _markdownTarget(m.group(1) == '!', m.group(2)!, m.group(3)!, m.group(0)!, env));
}

/// `[[Note]]`, `[[Note|text]]`, `[[Note#Heading]]`, `![[picture.png|300]]`, `![[Note]]`.
String _wikiTarget(bool embed, String inside, ConvertEnv env) {
  final bar = inside.indexOf('|');
  var target = bar < 0 ? inside : inside.substring(0, bar);
  final alias = bar < 0 ? '' : inside.substring(bar + 1).trim();
  String? heading;
  final hash = target.indexOf('#');
  if (hash >= 0) {
    heading = target.substring(hash + 1).trim();
    target = target.substring(0, hash);
  }
  target = target.trim();
  if (target.isEmpty) return alias.isNotEmpty ? alias : (heading ?? ''); // a link inside the same note
  final ext = _extOf(target);
  if (embed && pictureExtensions.contains(ext)) {
    final file = env.files.find(target, env.from);
    if (file != null) {
      final alt = RegExp(r'^\d+(x\d+)?$').hasMatch(alias) ? '' : alias;
      return '![$alt](${env._mark(file)})';
    }
  }
  final page = env.pages.find(target, env.from);
  if (page == null) {
    final file = _looksLikeFile(ext) ? env.files.find(target, env.from) : null;
    if (file != null) {
      env.skippedFiles.add(_nameOf(file));
      return alias.isNotEmpty ? alias : _nameOf(file);
    }
    env.missing.add(target);
    return alias.isNotEmpty ? alias : (heading == null || heading.isEmpty || heading.startsWith('^') ? target : '$target > $heading');
  }
  env.links++;
  final shownHeading = heading != null && heading.isNotEmpty && !heading.startsWith('^') ? heading : null;
  return noteLink(page.id, alias.isNotEmpty ? alias : (shownHeading == null ? page.title : '${page.title} > $shownHeading'));
}

/// `[text](other%20note.md)` and `![alt](folder/picture.png)`; an address on the internet is left alone (a link to a page of
/// Notion that is in the export becomes a link to the note).
String _markdownTarget(bool image, String label, String raw, String whole, ConvertEnv env) {
  if (raw.startsWith(_markStart)) return whole;
  var target = raw.startsWith('<') && raw.endsWith('>') ? raw.substring(1, raw.length - 1) : raw;
  if (target.isEmpty || target.startsWith('#')) return image ? label : whole;
  if (_scheme.hasMatch(target)) {
    if (!image && RegExp(r'^https?://([\w-]+\.)?notion\.(so|site)/', caseSensitive: false).hasMatch(target)) {
      final page = env.pages.find(target, env.from);
      if (page != null) {
        env.links++;
        return noteLink(page.id, label.isEmpty ? page.title : label);
      }
    }
    return whole;
  }
  target = target.replaceFirst(RegExp(r'[?#].*$'), '');
  try {
    target = Uri.decodeFull(target);
  } catch (_) {}
  final ext = _extOf(target);
  if (image || pictureExtensions.contains(ext)) {
    final file = env.files.find(target, env.from);
    if (file != null && pictureExtensions.contains(_extOf(file))) return '![$label](${env._mark(file)})';
    if (file == null) {
      env.missing.add(target);
    } else {
      env.skippedFiles.add(_nameOf(file));
    }
    return label;
  }
  final page = env.pages.find(target, env.from);
  if (page != null) {
    env.links++;
    return noteLink(page.id, label.isEmpty ? page.title : label);
  }
  final file = env.files.find(target, env.from);
  if (file != null) {
    env.skippedFiles.add(_nameOf(file));
  } else {
    env.missing.add(target);
  }
  return label.isEmpty ? _nameOf(target) : label;
}
