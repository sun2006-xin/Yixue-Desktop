#include "../recording_operation_worker.h"

#include <atomic>
#include <chrono>
#include <future>
#include <iostream>
#include <memory>
#include <thread>

namespace {

using namespace std::chrono_literals;
using yixue::runner::RecordingOperationWorker;
using yixue::runner::RecordingWorkerWaitResult;

int TestUiRetryDoesNotWaitForActiveRecordingWorker() {
  RecordingOperationWorker worker;
  auto started_promise = std::make_shared<std::promise<void>>();
  auto release_promise = std::make_shared<std::promise<void>>();
  auto finished_promise = std::make_shared<std::promise<void>>();
  const auto started = started_promise->get_future();
  const auto release = release_promise->get_future().share();
  const auto finished = finished_promise->get_future();

  try {
    worker.Start([started_promise, release, finished_promise] {
        started_promise->set_value();
        release.wait();
        finished_promise->set_value();
      });
  } catch (...) {
    return 10;
  }
  if (started.wait_for(2s) != std::future_status::ready) {
    release_promise->set_value();
    static_cast<void>(worker.WaitForShutdownFor(2s));
    return 11;
  }

  const auto before = std::chrono::steady_clock::now();
  const auto result = worker.TryJoinIfComplete();
  const auto elapsed = std::chrono::steady_clock::now() - before;
  release_promise->set_value();
  if (result != RecordingWorkerWaitResult::kBusy) {
    static_cast<void>(worker.WaitForShutdownFor(2s));
    return 12;
  }
  if (elapsed > 100ms) {
    static_cast<void>(worker.WaitForShutdownFor(2s));
    return 13;
  }
  if (worker.WaitForShutdownFor(2s) != RecordingWorkerWaitResult::kJoined) {
    return 14;
  }
  if (finished.wait_for(0ms) != std::future_status::ready) return 15;
  return worker.joinable() ? 16 : 0;
}

int TestShutdownTimeoutDetachesOnlyAfterDeadline() {
  RecordingOperationWorker worker;
  auto started_promise = std::make_shared<std::promise<void>>();
  auto release_promise = std::make_shared<std::promise<void>>();
  auto finished_promise = std::make_shared<std::promise<void>>();
  const auto started = started_promise->get_future();
  const auto release = release_promise->get_future().share();
  const auto finished = finished_promise->get_future();

  try {
    worker.Start([started_promise, release, finished_promise] {
        started_promise->set_value();
        release.wait();
        finished_promise->set_value();
      });
  } catch (...) {
    return 20;
  }
  if (started.wait_for(2s) != std::future_status::ready) {
    release_promise->set_value();
    static_cast<void>(worker.WaitForShutdownFor(2s));
    return 21;
  }

  const auto before = std::chrono::steady_clock::now();
  const auto result = worker.WaitForShutdownFor(40ms);
  const auto elapsed = std::chrono::steady_clock::now() - before;
  if (result != RecordingWorkerWaitResult::kTimedOutDetached) {
    release_promise->set_value();
    static_cast<void>(worker.WaitForShutdownFor(2s));
    return 22;
  }
  if (elapsed < 20ms || elapsed > 1s || worker.joinable()) {
    release_promise->set_value();
    return 23;
  }

  // Detached work owns only its captured state, so its completion remains
  // observable without requiring the FlutterWindow or its thread wrapper.
  release_promise->set_value();
  if (finished.wait_for(2s) != std::future_status::ready) return 24;
  return 0;
}

int TestCompletedWorkerCanBeJoinedWithoutWaiting() {
  RecordingOperationWorker worker;
  std::atomic<int> completed{0};
  try {
    worker.Start([&] { ++completed; });
  } catch (...) {
    return 30;
  }
  if (worker.WaitForShutdownFor(2s) != RecordingWorkerWaitResult::kJoined) {
    return 31;
  }
  if (worker.joinable()) return 32;
  return completed.load() == 1 ? 0 : 33;
}

int TestShutdownTimeoutCanRetainWorkerForSupervisorRecovery() {
  RecordingOperationWorker worker;
  auto started_promise = std::make_shared<std::promise<void>>();
  auto release_promise = std::make_shared<std::promise<void>>();
  auto finished_promise = std::make_shared<std::promise<void>>();
  const auto started = started_promise->get_future();
  const auto release = release_promise->get_future().share();
  const auto finished = finished_promise->get_future();

  try {
    worker.Start([started_promise, release, finished_promise] {
        started_promise->set_value();
        release.wait();
        finished_promise->set_value();
      });
  } catch (...) {
    return 40;
  }
  if (started.wait_for(2s) != std::future_status::ready) {
    release_promise->set_value();
    static_cast<void>(worker.WaitForShutdownFor(2s));
    return 41;
  }

  if (worker.WaitForShutdownFor(40ms, false) !=
          RecordingWorkerWaitResult::kTimedOutRetained ||
      !worker.joinable()) {
    release_promise->set_value();
    static_cast<void>(worker.WaitForShutdownFor(2s));
    return 42;
  }

  release_promise->set_value();
  if (worker.WaitForShutdownFor(2s, false) !=
      RecordingWorkerWaitResult::kJoined) {
    return 43;
  }
  if (finished.wait_for(0ms) != std::future_status::ready) return 44;
  return worker.joinable() ? 45 : 0;
}

}  // namespace

int main() {
  if (const int result = TestUiRetryDoesNotWaitForActiveRecordingWorker()) {
    return result;
  }
  if (const int result = TestShutdownTimeoutDetachesOnlyAfterDeadline()) {
    return result;
  }
  if (const int result = TestCompletedWorkerCanBeJoinedWithoutWaiting()) {
    return result;
  }
  if (const int result = TestShutdownTimeoutCanRetainWorkerForSupervisorRecovery()) {
    return result;
  }
  std::cout << "PASS: UI retry observes an active worker without blocking\n"
               "PASS: shutdown wait is bounded and detaches only after timeout\n"
               "PASS: completed worker joins cleanly\n"
               "PASS: supervised cleanup can retain and later join worker\n";
  return 0;
}
