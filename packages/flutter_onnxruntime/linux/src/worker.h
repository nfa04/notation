// A thread that does the jobs it is given one after the other, so that the plugin's long calls (opening a model, running it) do not
// hold up the thread of the screen. A worker made with `low_priority` runs at the lowest priority of the process (nice 19): the
// threads ONNX Runtime starts while a session is made on it inherit that, so a session made on it only takes the time that the rest
// of the app leaves over. (Priority cannot be raised again without privileges, so a worker keeps the one it was made with: sessions
// of low priority use one worker, the others another.)
#pragma once

#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>

class Worker {
public:
  explicit Worker(bool low_priority) : low_priority_(low_priority), thread_([this] { loop(); }) {}

  ~Worker() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopping_ = true;
    }
    wake_.notify_one();
    thread_.join(); // (the jobs still queued are done first)
  }

  void post(std::function<void()> job) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      jobs_.push_back(std::move(job));
    }
    wake_.notify_one();
  }

private:
  void loop() {
    if (low_priority_) {
      // (a thread's own nice value: setpriority takes the id of the thread, not of the process, on Linux)
      setpriority(PRIO_PROCESS, static_cast<id_t>(syscall(SYS_gettid)), 19);
    }
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
