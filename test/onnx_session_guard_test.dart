import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/llm/onnx_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_onnxruntime');

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    onnxSessionReport.clear();
  });

  test('a model that neither the accelerator nor the processor part of the runtime can open gives an error that says what to do', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final tried = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAvailableProviders') return ['MIGRAPHX', 'CPU'];
      tried.add(call.method);
      throw PlatformException(code: 'FAIL', message: 'Could not find an implementation for ConvInteger(10)');
    });
    await expectLater(
      openOnnxSession('/models/encoder.onnx'),
      throwsA(isA<StateError>().having((e) => e.message, 'message', allOf(contains('ConvInteger'), contains('The one in the app')))),
    );
    expect(tried, ['createSession', 'createSession']); // (with the accelerator, then without)
    expect(onnxSessionReport['encoder.onnx'], contains('not opened'));
  });
}
