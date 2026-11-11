import '../llm/onnx_session.dart';

/// 'cpu' to keep every model on the processor; anything else (or nothing): use the device's accelerator where it has one.
const onnxAccelerationSetting = 'onnx_acceleration';

/// Applies the saved choice: at the start of the app and after each change.
Future<void> applyOnnxAcceleration(Future<String?> Function(String key) get) async {
  onnxAccelerationEnabled = await get(onnxAccelerationSetting) != 'cpu';
}
