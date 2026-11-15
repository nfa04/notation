// Which ONNX Runtime the plugin uses: the one bundled with the app (a build for the processor only) or a runtime pack that the user
// chose (a build with the providers of a graphics card: CUDA, OpenVINO, MIGraphX, ...).
//
// The provider libraries of a runtime are found next to its libonnxruntime.so, and must be of the same build, so the pack is a
// whole runtime (libonnxruntime.so and its provider libraries in one folder) that is opened instead of the bundled one. This has to
// happen before the first call into ONNX Runtime, so it is read at start: from the environment variable
// FLUTTER_ONNXRUNTIME_LIBRARY (a path of a libonnxruntime.so), or from the file ~/.config/flutter_onnxruntime/library (one line,
// the same). A pack that cannot be opened is left out (the bundled runtime is used) and the reason is kept for the app to show.
#pragma once

#include <string>

namespace ort_runtime {

/// Makes the choice, once: opens the chosen runtime and hands its API table to the C++ wrappers. Safe to call again and from any thread.
void init();

/// The path of the runtime in use, or "" for the bundled one.
std::string activePath();

/// Why the chosen pack was not used ("" when there was none, or it was used).
std::string loadError();

/// The version string of the runtime in use (for example "1.28.3").
std::string version();

/// Saves the choice for the next start of the app: the path of a libonnxruntime.so, or "" to go back to the bundled runtime.
/// Returns "" or an error text.
std::string chooseForNextStart(const std::string &path);

/// The path that is saved for the next start ("" for the bundled runtime).
std::string chosenForNextStart();

} // namespace ort_runtime
