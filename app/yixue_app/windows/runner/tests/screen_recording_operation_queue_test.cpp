#include "../recording_publication_policy.h"
#include "../recording_filename_policy.h"
#include "../screen_recording_operation_queue.h"

#include <atomic>
#include <chrono>
#include <future>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace std::chrono_literals;
using yixue::runner::ScreenRecordingOperationQueue;
using yixue::runner::ScreenRecordingReplyGate;

int TestStartStopAndShutdownJoinInOrder() {
  auto start_operation_started_promise = std::make_shared<std::promise<void>>();
  auto release_start_operation_promise = std::make_shared<std::promise<void>>();
  auto shutdown_finished_promise = std::make_shared<std::promise<void>>();
  const auto start_started = start_operation_started_promise->get_future();
  const auto release_start =
      release_start_operation_promise->get_future().share();
  const auto shutdown = shutdown_finished_promise->get_future();
  auto order = std::make_shared<std::vector<int>>();
  auto finalizer_calls = std::make_shared<std::atomic<int>>(0);

  auto queue = ScreenRecordingOperationQueue::Create(
      [] {}, [order, finalizer_calls, shutdown_finished_promise] {
        order->push_back(3);
        ++(*finalizer_calls);
        shutdown_finished_promise->set_value();
      });
  if (!queue) return 10;
  struct CloseQueueOnExit final {
    std::shared_ptr<ScreenRecordingOperationQueue>& queue;
    ~CloseQueueOnExit() {
      if (queue) queue->Close();
    }
  } close_queue_on_exit{queue};

  ScreenRecordingOperationQueue::Operation start_recording =
      [start_operation_started_promise, release_start, order] {
    start_operation_started_promise->set_value();
    release_start.wait();
    order->push_back(1);
  };
  if (!queue->Post(start_recording)) return 11;
  if (start_started.wait_for(3s) != std::future_status::ready) {
    release_start_operation_promise->set_value();
    return 12;
  }

  // Simulate a Start operation blocked in native media startup. Submitting
  // Stop must still complete promptly on the Flutter/platform caller.
  ScreenRecordingOperationQueue::Operation stop_recording = [order] {
    order->push_back(2);
    throw std::runtime_error("expected test exception");
  };
  std::promise<bool> stop_posted_promise;
  auto stop_posted = stop_posted_promise.get_future();
  std::thread platform_caller([&] {
    stop_posted_promise.set_value(queue->Post(stop_recording));
  });
  if (stop_posted.wait_for(500ms) != std::future_status::ready) {
    release_start_operation_promise->set_value();
    platform_caller.join();
    return 13;
  }
  if (!stop_posted.get()) {
    release_start_operation_promise->set_value();
    platform_caller.join();
    return 14;
  }
  platform_caller.join();

  // Closing intake is still non-blocking while native Start is active. The
  // caller then releases Start and waits for Stop/finalization before it would
  // release the Flutter controller.
  std::promise<void> close_finished_promise;
  auto close_finished = close_finished_promise.get_future();
  std::thread shutdown_caller([&] {
    queue->Close();
    close_finished_promise.set_value();
  });
  if (close_finished.wait_for(500ms) != std::future_status::ready) {
    release_start_operation_promise->set_value();
    shutdown_caller.join();
    return 15;
  }
  shutdown_caller.join();

  // A newly submitted operation after Close must be rejected.
  if (queue->Post(stop_recording)) {
    release_start_operation_promise->set_value();
    return 16;
  }
  release_start_operation_promise->set_value();
  if (queue->CloseAndJoinFor(3s) !=
      ScreenRecordingOperationQueue::ShutdownResult::kCompleted) {
    return 17;
  }
  queue.reset();
  if (shutdown.wait_for(0ms) != std::future_status::ready) return 20;
  if (*order != std::vector<int>{1, 2, 3}) return 18;
  if (finalizer_calls->load() != 1) return 19;
  return 0;
}

int TestShutdownSuppressesQueuedFlutterReply() {
  auto start_operation_started = std::make_shared<std::promise<void>>();
  auto release_start_operation = std::make_shared<std::promise<void>>();
  auto shutdown_finished = std::make_shared<std::promise<void>>();
  const auto start_started = start_operation_started->get_future();
  const auto release_start = release_start_operation->get_future().share();
  const auto shutdown = shutdown_finished->get_future();
  auto native_stop_calls = std::make_shared<std::atomic<int>>(0);
  auto flutter_reply_calls = std::make_shared<std::atomic<int>>(0);
  auto reply_gate = std::make_shared<ScreenRecordingReplyGate>();

  auto queue = ScreenRecordingOperationQueue::Create(
      [] {}, [shutdown_finished] { shutdown_finished->set_value(); });
  if (!queue) return 50;
  struct CloseQueueOnExit final {
    std::shared_ptr<ScreenRecordingOperationQueue>& queue;
    ~CloseQueueOnExit() {
      if (queue) queue->Close();
    }
  } close_queue_on_exit{queue};

  if (!queue->Post([start_operation_started, release_start] {
        start_operation_started->set_value();
        release_start.wait();
      })) {
    return 51;
  }
  if (start_started.wait_for(3s) != std::future_status::ready) {
    release_start_operation->set_value();
    return 52;
  }

  // A queued stop still needs to finish native cleanup after plugin shutdown,
  // but must not reply through a Flutter messenger being torn down.
  if (!queue->Post([reply_gate, native_stop_calls, flutter_reply_calls] {
        ++(*native_stop_calls);
        reply_gate->InvokeIfOpen([flutter_reply_calls] {
          ++(*flutter_reply_calls);
        });
      })) {
    release_start_operation->set_value();
    return 53;
  }

  reply_gate->CloseAndWait();
  release_start_operation->set_value();
  if (queue->CloseAndJoinFor(3s) !=
      ScreenRecordingOperationQueue::ShutdownResult::kCompleted) {
    return 54;
  }
  if (shutdown.wait_for(0ms) != std::future_status::ready) return 57;
  if (native_stop_calls->load() != 1) return 55;
  if (flutter_reply_calls->load() != 0) return 56;
  return 0;
}

int TestTimedOutShutdownKeepsActiveEngineAndPartialOutputAlive() {
  struct EngineLifetime final {
    explicit EngineLifetime(std::shared_ptr<std::promise<void>> on_destroyed)
        : on_destroyed(std::move(on_destroyed)) {}
    ~EngineLifetime() {
      try {
        on_destroyed->set_value();
      } catch (...) {
      }
    }
    std::shared_ptr<std::promise<void>> on_destroyed;
  };

  const std::wstring file_token = std::to_wstring(
      std::chrono::steady_clock::now().time_since_epoch().count());
  const auto partial = std::filesystem::temp_directory_path() /
                       (L"screen-recording-timeout-" + file_token +
                        L".partial.mp4");
  struct TemporaryFile final {
    std::filesystem::path path;
    ~TemporaryFile() {
      std::error_code ignored;
      std::filesystem::remove(path, ignored);
    }
  } temporary_file{partial};
  {
    std::ofstream output(partial, std::ios::binary | std::ios::trunc);
    if (!output) return 80;
    output << "incomplete recording marker";
    if (!output) return 81;
  }

  auto start_started_promise = std::make_shared<std::promise<void>>();
  auto release_start_promise = std::make_shared<std::promise<void>>();
  auto finalizer_started_promise = std::make_shared<std::promise<void>>();
  auto release_finalizer_promise = std::make_shared<std::promise<void>>();
  auto finalizer_finished_promise = std::make_shared<std::promise<void>>();
  auto engine_destroyed_promise = std::make_shared<std::promise<void>>();
  const auto start_started = start_started_promise->get_future();
  const auto release_start = release_start_promise->get_future().share();
  const auto finalizer_started = finalizer_started_promise->get_future();
  const auto release_finalizer =
      release_finalizer_promise->get_future().share();
  const auto finalizer_finished = finalizer_finished_promise->get_future();
  const auto engine_destroyed = engine_destroyed_promise->get_future();
  auto engine = std::make_shared<EngineLifetime>(engine_destroyed_promise);
  const std::weak_ptr<EngineLifetime> weak_engine = engine;
  auto queued_stop_calls = std::make_shared<std::atomic<int>>(0);
  auto finalizer_saw_live_engine = std::make_shared<std::atomic<bool>>(false);

  auto queue = ScreenRecordingOperationQueue::Create(
      [] {},
      [engine, weak_engine, finalizer_started_promise,
       release_finalizer, finalizer_finished_promise,
       finalizer_saw_live_engine] {
        finalizer_started_promise->set_value();
        release_finalizer.wait();
        finalizer_saw_live_engine->store(!weak_engine.expired());
        finalizer_finished_promise->set_value();
      });
  if (!queue) return 82;
  struct ReleasePromisesOnExit final {
    std::shared_ptr<std::promise<void>> release_start;
    std::shared_ptr<std::promise<void>> release_finalizer;
    ~ReleasePromisesOnExit() {
      try {
        release_start->set_value();
      } catch (...) {
      }
      try {
        release_finalizer->set_value();
      } catch (...) {
      }
    }
  } release_on_exit{release_start_promise, release_finalizer_promise};
  engine.reset();

  if (!queue->Post([engine = weak_engine.lock(), start_started_promise,
                    release_start] {
        if (!engine) return;
        start_started_promise->set_value();
        release_start.wait();
      })) {
    return 83;
  }
  if (start_started.wait_for(3s) != std::future_status::ready) {
    release_start_promise->set_value();
    release_finalizer_promise->set_value();
    static_cast<void>(queue->CloseAndJoinFor(3s));
    return 84;
  }
  if (!queue->Post([queued_stop_calls] { ++(*queued_stop_calls); })) {
    release_start_promise->set_value();
    release_finalizer_promise->set_value();
    static_cast<void>(queue->CloseAndJoinFor(3s));
    return 85;
  }

  const auto shutdown_started = std::chrono::steady_clock::now();
  const auto shutdown_result = queue->CloseAndJoinFor(25ms);
  const auto shutdown_elapsed = std::chrono::steady_clock::now() -
                                shutdown_started;
  if (shutdown_result !=
      ScreenRecordingOperationQueue::ShutdownResult::kTimedOut) {
    release_start_promise->set_value();
    release_finalizer_promise->set_value();
    static_cast<void>(queue->CloseAndJoinFor(3s));
    return 86;
  }
  if (shutdown_elapsed > 2s) {
    release_start_promise->set_value();
    release_finalizer_promise->set_value();
    queue.reset();
    finalizer_finished.wait_for(3s);
    engine_destroyed.wait_for(3s);
    return 87;
  }
  if (queue->Post([] {})) {
    release_start_promise->set_value();
    release_finalizer_promise->set_value();
    queue.reset();
    finalizer_finished.wait_for(3s);
    engine_destroyed.wait_for(3s);
    return 88;
  }
  if (queue->CloseAndJoinFor(0ms) !=
      ScreenRecordingOperationQueue::ShutdownResult::kTimedOut) {
    release_start_promise->set_value();
    release_finalizer_promise->set_value();
    queue.reset();
    finalizer_finished.wait_for(3s);
    engine_destroyed.wait_for(3s);
    return 89;
  }
  queue.reset();

  // A timed-out close does not destroy an engine still owned by active native
  // work/finalization and does not remove the recoverable partial file.
  if (engine_destroyed.wait_for(0ms) != std::future_status::timeout ||
      !std::filesystem::exists(partial)) {
    release_start_promise->set_value();
    release_finalizer_promise->set_value();
    return 90;
  }
  release_start_promise->set_value();
  if (finalizer_started.wait_for(3s) != std::future_status::ready) {
    release_finalizer_promise->set_value();
    return 91;
  }
  const bool partial_survived_timeout = std::filesystem::exists(partial);
  const bool engine_survived_timeout =
      engine_destroyed.wait_for(0ms) == std::future_status::timeout;
  release_finalizer_promise->set_value();
  if (finalizer_finished.wait_for(3s) != std::future_status::ready) return 92;
  if (engine_destroyed.wait_for(3s) != std::future_status::ready) return 93;
  if (!partial_survived_timeout || !engine_survived_timeout) return 94;
  if (!finalizer_saw_live_engine->load()) return 95;
  if (queued_stop_calls->load() != 0) return 96;
  return 0;
}

int TestReplyGateWaitsForInFlightReplyAndThenCloses() {
  std::promise<void> reply_started_promise;
  std::promise<void> release_reply_promise;
  const auto reply_started = reply_started_promise.get_future();
  const auto release_reply = release_reply_promise.get_future().share();
  std::atomic<int> reply_calls{0};
  auto reply_gate = std::make_shared<ScreenRecordingReplyGate>();

  std::thread reply_thread([&] {
    reply_gate->InvokeIfOpen([&] {
      reply_started_promise.set_value();
      release_reply.wait();
      ++reply_calls;
    });
  });
  if (reply_started.wait_for(3s) != std::future_status::ready) {
    release_reply_promise.set_value();
    reply_thread.join();
    return 60;
  }

  const auto close_started = std::chrono::steady_clock::now();
  reply_gate->Close();
  const bool drained_while_reply_active = reply_gate->WaitForDrainFor(100ms);
  const auto close_elapsed = std::chrono::steady_clock::now() - close_started;
  if (drained_while_reply_active || close_elapsed > 1s) {
    release_reply_promise.set_value();
    reply_thread.join();
    return 61;
  }

  release_reply_promise.set_value();
  reply_thread.join();

  if (!reply_gate->WaitForDrainFor(1s)) return 62;
  if (reply_calls.load() != 1) return 63;
  bool late_reply_called = false;
  if (reply_gate->InvokeIfOpen([&] { late_reply_called = true; })) return 64;
  if (late_reply_called) return 65;
  return 0;
}

int TestLateSelectSourceReplyIsSuppressed() {
  struct SelectionReplyCounts final {
    std::atomic<int> success{0};
    std::atomic<int> error{0};
  };

  auto reply_gate = std::make_shared<ScreenRecordingReplyGate>();
  auto reply_counts = std::make_shared<SelectionReplyCounts>();
  auto selection_callback = [reply_gate, reply_counts](
                                std::optional<int> value,
                                const std::string& error_code,
                                const std::string& error_message) {
    (void)error_code;
    (void)error_message;
    reply_gate->InvokeIfOpen([&] {
      if (value.has_value()) {
        ++reply_counts->success;
      } else {
        ++reply_counts->error;
      }
    });
  };

  reply_gate->CloseAndWait();
  selection_callback(7, "", "");
  selection_callback(std::nullopt, "capturePickerFailed", "late error");

  if (reply_counts->success.load() != 0) return 70;
  if (reply_counts->error.load() != 0) return 71;
  return 0;
}

int TestFailedStartupKeepsPartialMp4Recoverable() {
  const std::wstring file_token = std::to_wstring(
      std::chrono::steady_clock::now().time_since_epoch().count());
  const auto partial = std::filesystem::temp_directory_path() /
                       (L"screen-recording-start-failure-" + file_token +
                        L".PaRtIaL.Mp4");
  const auto completed = std::filesystem::path(partial.wstring().substr(
      0, partial.wstring().size() - std::wstring(L".PaRtIaL.Mp4").size()) +
      L".mp4");
  struct TemporaryFiles final {
    std::filesystem::path partial;
    std::filesystem::path completed;
    ~TemporaryFiles() {
      std::error_code ignored;
      std::filesystem::remove(partial, ignored);
      std::filesystem::remove(completed, ignored);
    }
  } temporary_files{partial, completed};

  {
    std::ofstream output(partial, std::ios::binary | std::ios::trunc);
    if (!output) return 20;
    output << "test recovery marker";
    if (!output) return 21;
  }
  if (!yixue::runner::ShouldRetainPartialScreenRecording(partial)) return 22;
  if (yixue::runner::ShouldRetainPartialScreenRecording(completed)) return 23;
  std::error_code cleanup_error;
  if (yixue::runner::RemoveFailedScreenRecordingFile(partial, &cleanup_error)) {
    return 24;
  }
  if (cleanup_error || !std::filesystem::exists(partial)) return 25;
  {
    std::ofstream output(completed, std::ios::binary | std::ios::trunc);
    if (!output) return 26;
    output << "test temporary file";
    if (!output) return 27;
  }
  if (!yixue::runner::RemoveFailedScreenRecordingFile(completed,
                                                       &cleanup_error) ||
      cleanup_error || std::filesystem::exists(completed)) {
    return 28;
  }
  if (!std::filesystem::remove(partial, cleanup_error) || cleanup_error) {
    return 29;
  }
  return 0;
}

int TestApartmentInitializationFailureDoesNotCreateQueue() {
  std::atomic<int> finalizer_calls{0};
  auto queue = ScreenRecordingOperationQueue::Create(
      [] { throw std::runtime_error("expected initialization failure"); },
      [&] { ++finalizer_calls; });
  if (queue) return 30;
  return finalizer_calls.load() == 0 ? 0 : 31;
}

int TestSessionIdFilenameTokenSupportsAudioOnlySession() {
  using yixue::runner::SessionIdFilenameToken;

  const std::string uuid = "01234567-89AB-CDEF-0123-456789abcdef";
  if (SessionIdFilenameToken(uuid) != L"01234567-89ab-cdef-0123-456789abcdef") {
    return 40;
  }
  if (SessionIdFilenameToken("audio-only-" + uuid) !=
      L"audio-only-01234567-89ab-cdef-0123-456789abcdef") {
    return 41;
  }
  if (!SessionIdFilenameToken("audio-only-../session").empty()) return 42;
  if (!SessionIdFilenameToken("audio-only-01234567-89ab-cdef-0123-456789abcde").empty()) {
    return 43;
  }
  if (!SessionIdFilenameToken("audio-only-01234567-89ab-cdef-0123-456789abcde/").empty()) {
    return 44;
  }
  if (!SessionIdFilenameToken("unsafe-01234567-89ab-cdef-0123-456789abcdef").empty()) {
    return 45;
  }
  return 0;
}

}  // namespace

int main() {
  if (const int result =
          TestStartStopAndShutdownJoinInOrder()) {
    return result;
  }
  if (const int result = TestShutdownSuppressesQueuedFlutterReply()) {
    return result;
  }
  if (const int result = TestReplyGateWaitsForInFlightReplyAndThenCloses()) {
    return result;
  }
  if (const int result =
          TestTimedOutShutdownKeepsActiveEngineAndPartialOutputAlive()) {
    return result;
  }
  if (const int result = TestLateSelectSourceReplyIsSuppressed()) return result;
  if (const int result = TestFailedStartupKeepsPartialMp4Recoverable()) {
    return result;
  }
  if (const int result = TestApartmentInitializationFailureDoesNotCreateQueue()) {
    return result;
  }
  if (const int result = TestSessionIdFilenameTokenSupportsAudioOnlySession()) {
    return result;
  }
  std::cout << "PASS: bounded shutdown joins before controller teardown when work drains\n"
               "PASS: shutdown suppresses queued Flutter replies while native stop drains\n"
               "PASS: shutdown timeout preserves the active engine/finalizer and partial output\n"
               "PASS: reply gate waits for in-flight replies and rejects late replies\n"
               "PASS: late screen-source selection success/error replies are suppressed\n"
               "PASS: failed-start partial MP4 is retained, then test cleanup removes it\n"
               "PASS: apartment startup failure rejects the queue without finalizing\n"
               "PASS: recording filename accepts only safe UUID session tokens\n";
  return 0;
}
