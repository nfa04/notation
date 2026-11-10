# ONNX Runtime's native code finds these Java classes, fields and constructors
# by exact name and signature; shrinking or renaming them crashes the app
# the moment a model runs.
-keep class ai.onnxruntime.** { *; }
-keep class com.masicai.flutteronnxruntime.** { *; }

# LiteRT / TensorFlow Lite (handwriting): same reason, plus optional GPU classes
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.gpu.**
