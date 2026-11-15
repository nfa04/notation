import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/llm/onnx_session.dart';
import 'package:notes/screens/onnx_places.dart';

void main() {
  setUp(() => onnxRuns.value = const {});

  Widget page(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('says where each model of a reading runs: the graphics card or the processor', (tester) async {
    final opened = DateTime.now().subtract(const Duration(seconds: 1));
    onnxNoteRun('whisper_base/encoder.onnx', 'CPU', running: true); // (before the dialog: not shown)
    onnxNoteRun('whisper_base/encoder.onnx', 'CPU', running: false);
    onnxRuns.value['whisper_base/encoder.onnx|CPU']!.at = opened.subtract(const Duration(minutes: 1));
    await tester.pumpWidget(page(OnnxPlaces(since: opened)));
    expect(find.byKey(const ValueKey('onnx-places')), findsNothing);

    onnxNoteRun('glm_ocr/vision-gpu.onnx', 'MIGRAPHX', running: true);
    onnxNoteRun('glm_ocr/text.onnx', 'CPU', running: true);
    await tester.pump();
    expect(find.text('GLM-OCR (handwriting), picture part: vision-gpu.onnx: graphics card (AMD MIGraphX)'), findsOneWidget);
    expect(find.text('GLM-OCR (handwriting), text part: text.onnx: processor (CPU)'), findsOneWidget);
    expect(find.textContaining('whisper'), findsNothing);

    // a size without a plan: the processor reads while the card makes it
    onnxNoteRun('glm_ocr/vision-gpu.onnx', 'MIGRAPHX', running: false);
    onnxNoteRun('glm_ocr/vision-gpu.onnx', onnxMakingPlan, running: true);
    onnxNoteRun('glm_ocr/vision-gpu.onnx', 'CPU', running: true);
    await tester.pump();
    expect(find.textContaining('GLM-OCR (handwriting), picture part: vision-gpu.onnx: the graphics card is making its plan'), findsOneWidget);
    expect(find.textContaining('processor (CPU)'), findsNWidgets(2));
    await tester.pump(onnxRunSettle * 2);
  });

  testWidgets('a formula reading shows the formula models only, not the handwriting reader of the background reading', (tester) async {
    final opened = DateTime.now().subtract(const Duration(seconds: 1));
    onnxNoteRun('glm_ocr/vision-gpu.onnx', 'MIGRAPHX', running: true);
    await tester.pumpWidget(page(OnnxPlaces(since: opened, folders: OnnxPlaces.formulaFolders)));
    expect(find.textContaining('GLM-OCR'), findsNothing);
    onnxNoteRun('glm_ocr/vision-gpu.onnx', 'MIGRAPHX', running: false);
    onnxNoteRun('texteller/encoder-gpu.onnx', 'MIGRAPHX', running: true);
    await tester.pump();
    expect(find.text('TexTeller (formulas), picture part: encoder-gpu.onnx: graphics card (AMD MIGraphX)'), findsOneWidget);
    expect(find.textContaining('GLM-OCR'), findsNothing);
    await tester.pump(onnxRunSettle * 2);
  });

  testWidgets('the short form names the places of what ran lately', (tester) async {
    onnxNoteRun('glm_ocr/vision-gpu.onnx', 'MIGRAPHX', running: true);
    onnxNoteRun('glm_ocr/vision-gpu.onnx', 'MIGRAPHX', running: false);
    onnxNoteRun('glm_ocr/text.onnx', 'CPU', running: true);
    await tester.pumpWidget(page(OnnxPlaces(since: DateTime.now(), compact: true)));
    expect(find.text('graphics card + processor'), findsOneWidget);
    await tester.pump(onnxRunSettle * 2);
  });

  test('a decoder that runs for every token tells the listeners once when it starts and once when it has stopped', () async {
    var told = 0;
    void count() => told++;
    onnxRuns.addListener(count);
    addTearDown(() => onnxRuns.removeListener(count));
    for (var i = 0; i < 20; i++) {
      onnxNoteRun('texteller/decoder.onnx', 'CPU', running: true);
      onnxNoteRun('texteller/decoder.onnx', 'CPU', running: false);
    }
    expect(told, 1);
    await Future<void>.delayed(onnxRunSettle * 2);
    expect(told, 2);
    expect(onnxModelName('/home/x/models/texteller/decoder.onnx'), 'texteller/decoder.onnx');
  });
}
