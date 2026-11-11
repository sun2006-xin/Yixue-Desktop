#ifndef RUNNER_SCREEN_RECORDING_OPERATION_QUEUE_H_
#define RUNNER_SCREEN_RECORDING_OPERATION_QUEUE_H_

#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <deque>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>

namespace yixue::runner {

// Prevents queued recording work from replying through a Flutter messenger
// after the owning engine starts shutting down. Closing waits only for reply
// callbacks already in flight; native recording work remains on its queue.
class ScreenRecordingReplyGate final {
 public:
  ScreenRecordingReplyGate() = default;

  ScreenRecordingReplyGate(const ScreenRecordingReplyGate&) = delete;
  ScreenRecordingReplyGate& operator=(const ScreenRecordingReplyGate&) = delete;

  template <typename Callback>
  bool InvokeIfOpen(Callback&& callback) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!open_) return false;
      ++active_replies_;
    }

    InvocationLease lease(this);
    std::forward<Callback>(callback)();
    return true;
  }

  void Close() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      open_ = false;
    }
    condition_.notify_all();
  }

  [[nodiscard]] bool WaitForDrainFor(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(
        lock, timeout, [this] { return active_replies_ == 0; });
  }

  void CloseAndWait() {
    Close();
    std::unique_lock<std::mutex> lock(mutex_);
    condition_.wait(lock, [this] { return active_replies_ == 0; });
  }

 private:
  class InvocationLease final {
   public:
    explicit InvocationLease(ScreenRecordingReplyGate* gate) : gate_(gate) {}
    ~InvocationLease() { gate_->FinishInvocation(); }

    InvocationLease(const InvocationLease&) = delete;
    InvocationLease& operator=(const InvocationLease&) = delete;

   private:
    ScreenRecordingReplyGate* gate_;
  };

  void FinishInvocation() noexcept {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (active_replies_ > 0) --active_replies_;
    }
    condition_.notify_all();
  }

  std::mutex mutex_;
  std::condition_variable condition_;
  size_t active_replies_ = 0;
  bool open_ = true;
};

// Runs native recording lifecycle work away from Flutter's platform thread.
// A normal shutdown drains accepted operations and joins the worker before the
// Flutter controller is released. A timed-out shutdown drops pending requests,
// detaches only as a last resort, and leaves the shared native state alive so
// the active operation can finish and run the recorder finalizer safely.
class ScreenRecordingOperationQueue final {
 public:
  using Operation = std::function<void()>;

  enum class ShutdownResult {
    kCompleted,
    kTimedOut,
  };

  static std::shared_ptr<ScreenRecordingOperationQueue> Create(
      Operation initialize,
      Operation finalize) noexcept {
    try {
      auto queue = std::shared_ptr<ScreenRecordingOperationQueue>(
          new ScreenRecordingOperationQueue(std::move(initialize),
                                            std::move(finalize)));
      if (!queue->StartWorker()) return nullptr;
      return queue;
    } catch (...) {
      return nullptr;
    }
  }

  ~ScreenRecordingOperationQueue() {
    (void)CloseAndJoinFor(kDestructorWaitTimeout);
  }

  ScreenRecordingOperationQueue(const ScreenRecordingOperationQueue&) = delete;
  ScreenRecordingOperationQueue& operator=(
      const ScreenRecordingOperationQueue&) = delete;

  // The source operation remains owned by the caller if enqueueing fails.
  bool Post(const Operation& operation) noexcept {
    if (!operation) return false;
    try {
      {
        std::lock_guard<std::mutex> lock(state_->mutex);
        if (!state_->accepting) return false;
        state_->operations.push_back(operation);
      }
      state_->condition.notify_one();
      return true;
    } catch (...) {
      return false;
    }
  }

  // Closes intake without waiting. Use CloseAndJoinFor before destroying the
  // Flutter controller to establish a bounded native shutdown boundary.
  void Close() noexcept {
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      state_->accepting = false;
    }
    state_->condition.notify_one();
  }

  [[nodiscard]] ShutdownResult CloseAndJoinFor(
      std::chrono::milliseconds timeout) noexcept {
    Close();
    std::lock_guard<std::mutex> join_lock(join_mutex_);

    if (!worker_.joinable()) {
      return shutdown_timed_out_ ? ShutdownResult::kTimedOut
                                 : ShutdownResult::kCompleted;
    }

    bool completed = false;
    try {
      std::unique_lock<std::mutex> lock(state_->mutex);
      completed = state_->condition.wait_for(
          lock, timeout, [this] { return state_->worker_finished; });
      if (!completed) {
        // Keep the active operation and finalizer alive. Discard only work
        // that has not started, since those operations may still own Flutter
        // reply objects whose messenger is being torn down.
        state_->abandon_pending_operations = true;
        state_->operations.clear();
      }
    } catch (...) {
      completed = false;
      try {
        std::lock_guard<std::mutex> lock(state_->mutex);
        state_->abandon_pending_operations = true;
        state_->operations.clear();
      } catch (...) {
      }
    }

    if (completed) {
      try {
        worker_.join();
        return ShutdownResult::kCompleted;
      } catch (...) {
        // The thread was observed complete under its state lock. A join
        // failure is unexpected; fall through to the bounded fallback below.
      }
    }

    shutdown_timed_out_ = true;
    state_->condition.notify_one();
    try {
      if (worker_.joinable()) worker_.detach();
    } catch (...) {
      // Detach is only reached after a timeout and the thread is known to be
      // joinable under join_mutex_. Keep the method non-throwing at teardown.
    }
    return ShutdownResult::kTimedOut;
  }

 private:
  struct State final {
    State(Operation initialize, Operation finalize)
        : initialize(std::move(initialize)), finalize(std::move(finalize)) {}

    std::mutex mutex;
    std::condition_variable condition;
    std::deque<Operation> operations;
    Operation initialize;
    Operation finalize;
    bool accepting = true;
    bool abandon_pending_operations = false;
    bool worker_finished = false;
  };

  static constexpr std::chrono::milliseconds kDestructorWaitTimeout{5000};

  ScreenRecordingOperationQueue(Operation initialize, Operation finalize)
      : state_(std::make_shared<State>(std::move(initialize),
                                       std::move(finalize))) {}

  bool StartWorker() noexcept {
    std::promise<bool> startup_promise;
    std::future<bool> startup = startup_promise.get_future();
    try {
      const auto state = state_;
      worker_ = std::thread(
          [state, promise = std::move(startup_promise)]() mutable {
            Run(state, std::move(promise));
          });
    } catch (...) {
      return false;
    }

    bool initialized = false;
    try {
      initialized = startup.get();
    } catch (...) {
      initialized = false;
    }
    if (!initialized && worker_.joinable()) {
      try {
        worker_.join();
      } catch (...) {
        return false;
      }
    }
    return initialized;
  }

  static void Run(const std::shared_ptr<State>& state,
                  std::promise<bool> startup_promise) noexcept {
    const auto mark_worker_finished = [&state] {
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->worker_finished = true;
      }
      state->condition.notify_all();
    };

    try {
      if (state->initialize) state->initialize();
      startup_promise.set_value(true);
    } catch (...) {
      try {
        startup_promise.set_value(false);
      } catch (...) {
      }
      mark_worker_finished();
      return;
    }

    for (;;) {
      Operation operation;
      {
        std::unique_lock<std::mutex> lock(state->mutex);
        state->condition.wait(lock, [&state] {
          return !state->accepting || !state->operations.empty() ||
                 state->abandon_pending_operations;
        });
        if (state->abandon_pending_operations ||
            (state->operations.empty() && !state->accepting)) {
          break;
        }
        operation = std::move(state->operations.front());
        state->operations.pop_front();
      }
      try {
        operation();
      } catch (...) {
        // Every Flutter-facing task has its own error boundary. Keep one bad
        // task from preventing the remaining stop/shutdown work from running.
      }
    }

    // The finalizer owns the native engine. It must run even after a timed-out
    // caller detaches this worker, so that a returning active operation can
    // still stop the recorder and retain/publish its output safely.
    try {
      if (state->finalize) state->finalize();
    } catch (...) {
      // Shutdown is best effort; the partial recording remains on disk.
    }
    mark_worker_finished();
  }

  std::shared_ptr<State> state_;
  std::mutex join_mutex_;
  std::thread worker_;
  bool shutdown_timed_out_ = false;
};

}  // namespace yixue::runner

#endif  // RUNNER_SCREEN_RECORDING_OPERATION_QUEUE_H_
