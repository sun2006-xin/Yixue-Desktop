#ifndef RUNNER_WASAPI_WORKER_COMPLETION_H_
#define RUNNER_WASAPI_WORKER_COMPLETION_H_

#include <chrono>
#include <condition_variable>
#include <mutex>

namespace yixue::runner {

// A worker can signal completion only after its thread-local COM objects have
// been released. Callers may then join without waiting on an unbounded native
// audio operation.
class WasapiWorkerCompletion {
 public:
  void Reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    finished_ = false;
  }

  void MarkFinished() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      finished_ = true;
    }
    condition_.notify_all();
  }

  template <typename Rep, typename Period>
  bool WaitFor(std::chrono::duration<Rep, Period> timeout) {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, timeout, [this] { return finished_; });
  }

  template <typename Thread, typename Rep, typename Period>
  bool TryJoin(Thread& worker, std::chrono::duration<Rep, Period> timeout) {
    if (!worker.joinable()) return true;
    if (!WaitFor(timeout)) return false;
    worker.join();
    return true;
  }

  void Wait() {
    std::unique_lock<std::mutex> lock(mutex_);
    condition_.wait(lock, [this] { return finished_; });
  }

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
  bool finished_ = true;
};

}  // namespace yixue::runner

#endif  // RUNNER_WASAPI_WORKER_COMPLETION_H_
