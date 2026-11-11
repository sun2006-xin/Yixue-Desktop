#include "wasapi_worker_completion.h"
#include "wasapi_capture_lifecycle.h"
#include "wasapi_event_callback_gate.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>

using namespace std::chrono_literals;
using yixue::runner::StopOrRetireWasapiCapture;

namespace {

struct FakeCapture {
  explicit FakeCapture(bool* was_destroyed) : was_destroyed(was_destroyed) {}
  ~FakeCapture() { *was_destroyed = true; }

  WasapiCaptureStopResult Stop(const std::string&,
                               std::chrono::milliseconds) {
    return stop_result;
  }

  bool* was_destroyed;
  WasapiCaptureStopResult stop_result = WasapiCaptureStopResult::kPending;
};

int TestPendingCaptureIsTransferredWithoutDestruction() {
  bool was_destroyed = false;
  std::unique_ptr<FakeCapture> active =
      std::make_unique<FakeCapture>(&was_destroyed);
  std::unique_ptr<FakeCapture> retired;
  const auto result = yixue::runner::StopOrRetireWasapiCapture(
      active, "stopped", 20ms,
      [&retired](std::unique_ptr<FakeCapture> capture) {
        retired = std::move(capture);
      });
  if (result != WasapiCaptureStopResult::kPending) return 1;
  if (active != nullptr || retired == nullptr || was_destroyed) return 2;
  retired.reset();
  return was_destroyed ? 0 : 3;
}

int TestStoppedCaptureIsReleased() {
  bool was_destroyed = false;
  std::unique_ptr<FakeCapture> active =
      std::make_unique<FakeCapture>(&was_destroyed);
  active->stop_result = WasapiCaptureStopResult::kStopped;
  bool retire_called = false;
  const auto result = yixue::runner::StopOrRetireWasapiCapture(
      active, "stopped", 20ms,
      [&retire_called](std::unique_ptr<FakeCapture>) {
        retire_called = true;
      });
  if (result != WasapiCaptureStopResult::kStopped) return 1;
  if (active != nullptr || !was_destroyed || retire_called) return 2;
  return 0;
}

int TestDisablingCallbackDoesNotWaitForInflightDispatch() {
  std::mutex mutex;
  std::condition_variable condition;
  bool entered = false;
  bool release = false;
  std::atomic<int> callback_count{0};
  WasapiEventCallbackGate<int> gate([&](int, bool) {
    callback_count.fetch_add(1);
    std::unique_lock<std::mutex> lock(mutex);
    entered = true;
    condition.notify_all();
    condition.wait(lock, [&] { return release; });
    return true;
  });

  std::thread dispatch([&] { gate.Dispatch(1, false); });
  {
    std::unique_lock<std::mutex> lock(mutex);
    if (!condition.wait_for(lock, 1s, [&] { return entered; })) {
      release = true;
      lock.unlock();
      condition.notify_all();
      dispatch.join();
      return 1;
    }
  }

  const auto started = std::chrono::steady_clock::now();
  gate.Disable();
  const auto disable_elapsed = std::chrono::steady_clock::now() - started;
  if (disable_elapsed > 100ms) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      release = true;
    }
    condition.notify_all();
    dispatch.join();
    return 2;
  }

  if (gate.Dispatch(2, false)) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      release = true;
    }
    condition.notify_all();
    dispatch.join();
    return 3;
  }
  {
    std::lock_guard<std::mutex> lock(mutex);
    release = true;
  }
  condition.notify_all();
  dispatch.join();
  return callback_count.load() == 1 ? 0 : 4;
}

}  // namespace

int main() {
  const int pending_result = TestPendingCaptureIsTransferredWithoutDestruction();
  if (pending_result != 0) return 10 + pending_result;
  const int stopped_result = TestStoppedCaptureIsReleased();
  if (stopped_result != 0) return 20 + stopped_result;
  const int callback_result = TestDisablingCallbackDoesNotWaitForInflightDispatch();
  if (callback_result != 0) return 30 + callback_result;

  yixue::runner::WasapiWorkerCompletion completion;
  completion.Reset();

  std::atomic<bool> release_worker{false};
  std::thread worker([&] {
    while (!release_worker.load()) {
      std::this_thread::sleep_for(1ms);
    }
    completion.MarkFinished();
  });

  const auto started = std::chrono::steady_clock::now();
  if (completion.TryJoin(worker, 20ms)) return 1;
  const auto wait_elapsed = std::chrono::steady_clock::now() - started;
  if (wait_elapsed > 250ms) return 2;
  if (!worker.joinable()) return 3;

  release_worker.store(true);
  if (!completion.TryJoin(worker, 1s)) return 4;
  if (worker.joinable()) return 5;
  return 0;
}
