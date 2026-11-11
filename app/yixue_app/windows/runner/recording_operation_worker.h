#ifndef RUNNER_RECORDING_OPERATION_WORKER_H_
#define RUNNER_RECORDING_OPERATION_WORKER_H_

#include <windows.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <thread>
#include <utility>

namespace yixue::runner {

enum class RecordingWorkerWaitResult {
  kNoWorker,
  kJoined,
  kBusy,
  kTimedOutDetached,
  kWaitFailedDetached,
  kTimedOutRetained,
  kWaitFailedRetained,
  kJoinFailedDetached,
};

// Owns only the std::thread handle. Detached work must capture its complete
// native-operation state by value/shared ownership and must never dereference
// the FlutterWindow that started it.
class RecordingOperationWorker final {
 public:
  RecordingOperationWorker() = default;
  ~RecordingOperationWorker() = default;

  RecordingOperationWorker(const RecordingOperationWorker&) = delete;
  RecordingOperationWorker& operator=(const RecordingOperationWorker&) = delete;

  template <typename Work>
  void Start(Work&& work) {
    if (joinable()) {
      throw std::logic_error("recording operation worker is still joinable");
    }
    worker_ = std::make_unique<std::thread>(std::forward<Work>(work));
  }

  bool joinable() const noexcept { return worker_ && worker_->joinable(); }

  // Platform-channel callers must never wait for an active media operation.
  // Reap a worker only after the OS reports that it has already exited.
  RecordingWorkerWaitResult TryJoinIfComplete() noexcept {
    if (!joinable()) return RecordingWorkerWaitResult::kNoWorker;
    const DWORD wait_result =
        ::WaitForSingleObject(worker_->native_handle(), 0);
    if (wait_result == WAIT_TIMEOUT || wait_result == WAIT_FAILED) {
      return RecordingWorkerWaitResult::kBusy;
    }
    if (wait_result != WAIT_OBJECT_0) return RecordingWorkerWaitResult::kBusy;
    return JoinSignaledWorker();
  }

  // Used only after the event poster has been closed and queued completions
  // have been discarded. On timeout, detach so application shutdown remains
  // bounded; the caller must retain the engine/native owners until process
  // exit because the worker may still be inside Windows media APIs.
  RecordingWorkerWaitResult WaitForShutdownFor(
      std::chrono::milliseconds timeout,
      bool detach_on_timeout = true) noexcept {
    if (!joinable()) return RecordingWorkerWaitResult::kNoWorker;
    const auto requested_ms = timeout.count();
    const auto bounded_ms = std::min<int64_t>(
        std::max<int64_t>(0, requested_ms),
        static_cast<int64_t>(INFINITE - 1));
    const DWORD wait_result = ::WaitForSingleObject(
        worker_->native_handle(), static_cast<DWORD>(bounded_ms));
    if (wait_result == WAIT_OBJECT_0) return JoinSignaledWorker();
    if (!detach_on_timeout) {
      return wait_result == WAIT_TIMEOUT
                 ? RecordingWorkerWaitResult::kTimedOutRetained
                 : RecordingWorkerWaitResult::kWaitFailedRetained;
    }
    if (wait_result == WAIT_TIMEOUT) {
      DetachIfJoinable();
      return RecordingWorkerWaitResult::kTimedOutDetached;
    }
    DetachIfJoinable();
    return RecordingWorkerWaitResult::kWaitFailedDetached;
  }

 private:
  RecordingWorkerWaitResult JoinSignaledWorker() noexcept {
    try {
      worker_->join();
      worker_.reset();
      return RecordingWorkerWaitResult::kJoined;
    } catch (...) {
      // The OS handle is signaled, so no worker code can still dereference
      // operation state. Detach to keep std::thread destruction non-throwing.
      DetachIfJoinable();
      return RecordingWorkerWaitResult::kJoinFailedDetached;
    }
  }

  void DetachIfJoinable() noexcept {
    if (!joinable()) return;
    try {
      worker_->detach();
      worker_.reset();
    } catch (...) {
      // Never let std::thread's destructor terminate the process. A leaked
      // wrapper is safe here because shutdown has already closed the window's
      // poster; the native thread remains independent of this owner.
      static_cast<void>(worker_.release());
    }
  }

  std::unique_ptr<std::thread> worker_;
};

}  // namespace yixue::runner

#endif  // RUNNER_RECORDING_OPERATION_WORKER_H_
