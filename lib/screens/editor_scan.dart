part of 'fixed_page_note_editor.dart';

/// Scanning a photographed page into the note, and reading the text out of pictures.
extension _EditorScan on _FixedPageNoteEditorState {
  /// Phones and tablets have a camera to scan with; a computer scans from a picture file.
  bool get _hasCamera => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<Uint8List?> _pickPicture({required bool camera}) async {
    if (camera) {
      final shot = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 4000, imageQuality: 92);
      return shot == null ? null : await shot.readAsBytes();
    }
    final picked = await FilePicker.pickFile(type: FileType.image);
    return picked == null ? null : await picked.readAsBytes();
  }

  Future<void> _scanAction(String action) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final photo = await _pickPicture(camera: action == 'camera');
      if (photo == null || !mounted) return;
      if (action == 'read') {
        final ocr = widget.ocr;
        if (ocr == null || !ocr.installed) {
          messenger.showSnackBar(SnackBar(content: Text('Install the text reader in the settings first (AI and models).')));
          return;
        }
        final text = await readTextOf(context, photo, ocr);
        if (text == null || !mounted) return;
        if (text.trim().isEmpty) {
          messenger.showSnackBar(SnackBar(content: Text('No text was found in that picture.')));
          return;
        }
        final (page, scrolled) = _visiblePage();
        _addTextBoxAt(page, Offset(_visibleLeft + 40, scrolled + 40), initialText: text, width: 560);
        return;
      }
      final result = await scanPage(context, photo, ocr: widget.ocr);
      if (result == null || !mounted) return;
      final item = await _placeImage(result.page, isPng: result.isPng, isJpeg: !result.isPng, maxWidth: 700);
      final text = result.text;
      if (item != null && text != null && text.trim().isNotEmpty && mounted) {
        // the text goes under the page, or at the top of the next one when there is no room
        final page = _imagesPerPage.entries.firstWhere((e) => e.value.contains(item)).key;
        final under = item.position.dy + item.size.height + 16;
        final room = _heightOf(page) - under;
        if (room > 120) {
          _addTextBoxAt(page, Offset(item.position.dx, under), initialText: text, width: item.size.width);
        } else if (page + 1 < _pageCount) {
          _addTextBoxAt(page + 1, const Offset(40, 40), initialText: text, width: 700);
        } else {
          _addTextBoxAt(page, Offset(item.position.dx, math.max(0.0, _heightOf(page) - 140)), initialText: text, width: item.size.width);
        }
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text.verbatim(tr('Could not scan: {error}', {'error': e}))));
    }
  }
}
