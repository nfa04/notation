// Doing the long calls (opening a model, running it) apart from the thread of the screen, at a low priority when asked.
//
// * Worker: a thread that does the jobs it is given one after the other. One made with `low_priority` runs at the lowest priority.
// * LowPriorityThreads: what ONNX Runtime is given (SessionOptionsSetCustomCreateThreadFn) so that the threads of a session made with
//   `lowPriority` are started at the lowest priority too: on Windows a thread does not take the priority of the one that starts it.
// * Outcome / CollectedResult: the handlers answer through a MethodResult, which must be used on the thread of the screen; on the
//   worker they answer into an Outcome, which is given to the real MethodResult on the thread of the screen afterwards.
#pragma once

#include <windows.h>

#include <flutter/method_result.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <onnxruntime_cxx_api.h>

#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

namespace flutter_onnxruntime {

class Worker {
public:
  explicit Worker(bool low_priority) : low_priority_(low_priority), thread_([this] { Loop(); }) {}

  ~Worker() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopping_ = true;
    }
    wake_.notify_one();
    thread_.join(); // (the jobs still queued are done first)
  }

  void Post(std::function<void()> job) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      jobs_.push_back(std::move(job));
    }
    wake_.notify_one();
  }

private:
  void Loop() {
    if (low_priority_) SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_LOWEST);
    for (;;) {
      std::function<void()> job;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        wake_.wait(lock, [this] { return stopping_ || !jobs_.empty(); });
        if (jobs_.empty()) return;
        job = std::move(jobs_.front());
        jobs_.pop_front();
      }
      job();
    }
  }

  const bool low_priority_;
  std::mutex mutex_;
  std::condition_variable wake_;
  std::deque<std::function<void()>> jobs_;
  bool stopping_ = false;
  std::thread thread_; // (last: started when everything above exists)
};

namespace low_priority_threads {

struct Start {
  OrtThreadWorkerFn function;
  void *parameter;
};

inline DWORD WINAPI Main(LPVOID data) {
  std::unique_ptr<Start> start(static_cast<Start *>(data));
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_LOWEST);
  start->function(start->parameter);
  return 0;
}

inline OrtCustomThreadHandle Create(void * /*options*/, OrtThreadWorkerFn function, void *parameter) {
  auto start = std::make_unique<Start>(Start{function, parameter});
  HANDLE thread = CreateThread(nullptr, 0, Main, start.get(), 0, nullptr);
  if (thread == nullptr) return nullptr;
  start.release(); // (the thread owns it now)
  return reinterpret_cast<OrtCustomThreadHandle>(thread);
}

inline void Join(OrtCustomThreadHandle handle) {
  HANDLE thread = const_cast<void *>(static_cast<const void *>(handle));
  WaitForSingleObject(thread, INFINITE);
  CloseHandle(thread);
}

/// Makes the threads that ONNX Runtime starts for a session made with [options] start at the lowest priority.
inline void Apply(Ort::SessionOptions &options) {
  const OrtApi &api = Ort::GetApi();
  Ort::ThrowOnError(api.SessionOptionsSetCustomCreateThreadFn(options, &Create));
  Ort::ThrowOnError(api.SessionOptionsSetCustomJoinThreadFn(options, &Join));
}

} // namespace low_priority_threads

/// What a handler answered, kept to be given to the real MethodResult on the thread of the screen.
struct Outcome {
  enum class Kind { None, Success, Error, NotImplemented } kind = Kind::None;
  std::optional<flutter::EncodableValue> value;
  std::string code, message;

  void ReplayTo(flutter::MethodResult<flutter::EncodableValue> *target) const {
    switch (kind) {
    case Kind::Success:
      if (value) target->Success(*value);
      else target->Success();
      break;
    case Kind::Error:
      if (value) target->Error(code, message, *value);
      else target->Error(code, message);
      break;
    default:
      target->NotImplemented();
    }
  }
};

class CollectedResult : public flutter::MethodResult<flutter::EncodableValue> {
public:
  explicit CollectedResult(std::shared_ptr<Outcome> outcome) : outcome_(std::move(outcome)) {}

protected:
  void SuccessInternal(const flutter::EncodableValue *result) override {
    outcome_->kind = Outcome::Kind::Success;
    if (result) outcome_->value = *result;
  }
  void ErrorInternal(const std::string &code, const std::string &message, const flutter::EncodableValue *details) override {
    outcome_->kind = Outcome::Kind::Error;
    outcome_->code = code;
    outcome_->message = message;
    if (details) outcome_->value = *details;
  }
  void NotImplementedInternal() override { outcome_->kind = Outcome::Kind::NotImplemented; }

private:
  std::shared_ptr<Outcome> outcome_;
};

/// Runs functions on the thread of the screen, from any thread: they are queued and a message to the window of the app is posted;
/// the window procedure of the app hands the message to the delegate registered with the plugin registrar.
class ScreenThread {
public:
  static constexpr UINT kMessage = WM_APP + 0x4f52;

  ScreenThread(flutter::PluginRegistrarWindows *registrar) : registrar_(registrar) {
    view_ = registrar->GetView();
    if (view_ == nullptr || view_->GetNativeWindow() == nullptr) return;
    delegate_ = registrar->RegisterTopLevelWindowProcDelegate([this](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
      if (message != kMessage) return std::nullopt;
      Drain();
      return 0;
    });
  }

  ~ScreenThread() {
    if (delegate_ >= 0) registrar_->UnregisterTopLevelWindowProcDelegate(delegate_);
  }

  /// Whether there is a window to post to (without: the calls are made on the calling thread, as they were before).
  bool Available() const { return delegate_ >= 0; }

  void Post(std::function<void()> work) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      queue_.push_back(std::move(work));
    }
    // (the window is looked for each time: while the plugin is registered the view may not be in the window of the app yet, and a
    // message posted to the view alone never reaches the delegate, which is for the top window)
    HWND child = view_->GetNativeWindow();
    HWND top = child == nullptr ? nullptr : GetAncestor(child, GA_ROOT);
    if (top != nullptr) PostMessage(top, kMessage, 0, 0);
  }

private:
  void Drain() {
    for (;;) {
      std::function<void()> work;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (queue_.empty()) return;
        work = std::move(queue_.front());
        queue_.pop_front();
      }
      work();
    }
  }

  flutter::PluginRegistrarWindows *registrar_;
  flutter::FlutterView *view_ = nullptr;
  int delegate_ = -1;
  std::mutex mutex_;
  std::deque<std::function<void()>> queue_;
};

} // namespace flutter_onnxruntime
