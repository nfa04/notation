import 'package:flutter/foundation.dart';

import '../models/canvas_models.dart';

/// Where a downloadable model stands: not on the device, being downloaded, or ready to use.
enum HandwritingStatus { notInstalled, downloading, installed }

/// A model that is downloaded on request and can be removed again.
abstract class DownloadableModel extends ChangeNotifier {
  HandwritingStatus get status;

  /// 0..1 while downloading.
  double get progress;

  /// What went wrong the last time, if anything.
  String? get error;

  /// Size of the download, for the question to the user.
  int get sizeMb;

  Future<void> load();
  Future<void> install();
  Future<void> remove();
}

/// Something that reads drawings and has a model to download first: the
/// handwriting reader and the formula reader.
abstract class InkRecognizer extends DownloadableModel {
  /// The text (or LaTeX) written by [strokes]. Throws if the model is not
  /// installed or cannot run on this device.
  Future<String> recognize(List<DrawingStroke> strokes);

  /// [recognize], with the words of the text that the reader was unsure of (it may have misread them): none for a reader that does not say.
  Future<({String text, List<String> unsure})> recognizeScored(List<DrawingStroke> strokes) async => (text: await recognize(strokes), unsure: const <String>[]);

  /// Other readings of the same writing, each from another way of looking at it (the formula reader draws the pen thinner and thicker): a
  /// person who doubts what was read can be shown them. Empty when there is no other way to look, or the model is not installed.
  Future<List<String>> recognizeAgain(List<DrawingStroke> strokes) async => const [];
}
