import '../llm/onnx_session.dart';

/// 'cpu' to keep every model on the processor; anything else (or nothing): use the device's accelerator where it has one.
const onnxAccelerationSetting = 'onnx_acceleration';

/// Applies the saved choice: at the start of the app and after each change.
Future<void> applyOnnxAcceleration(Future<String?> Function(String key) get) async {
  onnxAccelerationEnabled = await get(onnxAccelerationSetting) != 'cpu';
}

/// 'off' to feed pictures to the networks at the size they have; anything else (or nothing): pad them to a few fixed sizes
/// (see [padToFixedSizes]).
const onnxPadSetting = 'onnx_pad_fixed_sizes';

Future<void> applyOnnxPadding(Future<String?> Function(String key) get) async {
  padToFixedSizes = await get(onnxPadSetting) != 'off';
}
