#include "ort_runtime.h"

#include <dlfcn.h>
#include <sys/stat.h>

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <mutex>

#include <onnxruntime_cxx_api.h>

namespace {

std::once_flag g_once;
std::string g_active;
std::string g_error;
std::string g_version;

std::string configDir() {
  const char *xdg = std::getenv("XDG_CONFIG_HOME");
  if (xdg != nullptr && xdg[0] != '\0') return std::string(xdg) + "/flutter_onnxruntime";
  const char *home = std::getenv("HOME");
  if (home != nullptr && home[0] != '\0') return std::string(home) + "/.config/flutter_onnxruntime";
  return "";
}

std::string configFile() {
  std::string dir = configDir();
  return dir.empty() ? "" : dir + "/library";
}

std::string readChosen() {
  const char *env = std::getenv("FLUTTER_ONNXRUNTIME_LIBRARY");
  if (env != nullptr && env[0] != '\0') return env;
  std::string file = configFile();
  if (file.empty()) return "";
  std::ifstream in(file);
  std::string line;
  if (in && std::getline(in, line)) {
    while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
    return line;
  }
  return "";
}

// The API table of the newest version both sides know: the headers of the plugin are of the bundled runtime, a pack may be older
// (an AMD build, say). The calls of the plugin are all of version 22 or older.
const OrtApi *negotiate(const OrtApiBase *base) {
  // The API version is the minor number of the version ("1.23.1" is 23). Asking for one the runtime does not have also logs an error.
  int minor = 0;
  std::sscanf(base->GetVersionString(), "%*d.%d", &minor);
  int v = minor < ORT_API_VERSION ? minor : ORT_API_VERSION;
  return v >= 22 ? base->GetApi(v) : nullptr;
}

void doInit() {
  const OrtApiBase *base = nullptr;
  std::string chosen = readChosen();
  if (!chosen.empty()) {
    void *handle = dlopen(chosen.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
      const char *why = dlerror();
      g_error = "could not open " + chosen + ": " + (why ? why : "unknown error");
    } else {
      auto getBase = reinterpret_cast<const OrtApiBase *(*)()>(dlsym(handle, "OrtGetApiBase"));
      if (getBase == nullptr) {
        g_error = chosen + " is not an ONNX Runtime library (no OrtGetApiBase)";
      } else if (negotiate(getBase()) == nullptr) {
        g_error = chosen + " is too old (needs ONNX Runtime 1.22 or newer)";
      } else {
        base = getBase();
        g_active = chosen;
      }
    }
    if (!g_error.empty()) std::cerr << "flutter_onnxruntime: " << g_error << "; using the bundled runtime" << std::endl;
  }
  if (base == nullptr) base = OrtGetApiBase();
  Ort::InitApi(negotiate(base));
  g_version = base->GetVersionString();
}

} // namespace

namespace ort_runtime {

void init() { std::call_once(g_once, doInit); }

std::string activePath() {
  init();
  return g_active;
}

std::string loadError() {
  init();
  return g_error;
}

std::string version() {
  init();
  return g_version;
}

std::string chooseForNextStart(const std::string &path) {
  std::string file = configFile();
  if (file.empty()) return "no config folder (HOME is not set)";
  if (path.empty()) {
    std::remove(file.c_str());
    return "";
  }
  struct stat st;
  if (stat(path.c_str(), &st) != 0) return "no such file: " + path;
  std::string dir = configDir();
  // mkdir -p of the two levels
  std::string parent = dir.substr(0, dir.find_last_of('/'));
  mkdir(parent.c_str(), 0755);
  mkdir(dir.c_str(), 0755);
  std::ofstream out(file, std::ios::trunc);
  if (!out) return "could not write " + file;
  out << path << "\n";
  return "";
}

std::string chosenForNextStart() { return readChosen(); }

} // namespace ort_runtime
