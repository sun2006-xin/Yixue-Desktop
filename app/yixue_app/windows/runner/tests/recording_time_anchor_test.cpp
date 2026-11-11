#include "../recording_time_anchor.h"
#include "../recording_capture_safety.h"
#include "../texture_unregistration_safety.h"

#include <atomic>
#include <chrono>
#include <memory>
#include <thread>
#include <vector>

namespace {

struct FakeCapture {
  bool PushAudioFrame(int frame) {
    frames.push_back(frame);
    return true;
  }

  std::vector<int> frames;
};

int TestCaptureCallbackKeepsItsOriginalOwner() {
  auto current_owner = std::make_shared<FakeCapture>();
  std::weak_ptr<FakeCapture> retired_owner = current_owner;
  {
    auto callback = BindSharedOwner(
        current_owner,
        [](const std::shared_ptr<FakeCapture>& owner, int frame) {
          return owner->PushAudioFrame(frame);
        });

    current_owner = std::make_shared<FakeCapture>();
    if (!callback(7)) return 10;
    if (!current_owner->frames.empty()) return 11;
    if (retired_owner.expired()) return 12;
  }
  if (!retired_owner.expired()) return 13;
  return 0;
}

int TestTextureUnregistrationWaitCanTimeOutAndCallbackReleasesOwner() {
  auto completion = std::make_shared<TextureUnregistrationCompletion>();
  if (completion->WaitFor(std::chrono::milliseconds(0))) return 70;

  auto owner = std::make_shared<FakeCapture>();
  std::weak_ptr<FakeCapture> retired_owner = owner;
  auto context = std::make_unique<TextureUnregisterCallbackContext>();
  context->keep_alive = owner;
  context->completion = completion;
  void* callback_data = context.release();
  owner.reset();
  if (retired_owner.expired()) return 71;

  TextureUnregisterCallbackContext::CompleteAndRelease(callback_data);
  if (!retired_owner.expired()) return 72;
  if (!completion->WaitFor(std::chrono::milliseconds(1))) return 73;
  return 0;
}

int TestRecordingFailureSignalIsOncePerRecording() {
  RecordingFailureSignal signal;
  if (signal.IsSignalled()) return 20;
  std::atomic<int> successful_signals{0};
  std::vector<std::thread> callers;
  for (int index = 0; index < 16; ++index) {
    callers.emplace_back([&signal, &successful_signals] {
      if (signal.TrySignal()) ++successful_signals;
    });
  }
  for (auto& caller : callers) caller.join();
  if (successful_signals.load() != 1) return 21;
  if (!signal.IsSignalled()) return 22;
  if (signal.TrySignal()) return 23;
  signal.Reset();
  if (signal.IsSignalled()) return 24;
  if (!signal.TrySignal()) return 25;
  return 0;
}

int TestNavigationWaitsForRecordingAudioOwner() {
  if (CanReleaseCaptureForNavigation(false, true)) return 30;
  if (CanReleaseCaptureForNavigation(true, false)) return 31;
  if (CanReleaseCaptureForNavigation(true, true)) return 32;
  if (!CanReleaseCaptureForNavigation(false, false)) return 33;
  return 0;
}

int TestOldRecordingFailureCannotStopCurrentRecording() {
  const std::string active_session = "session-new";
  const std::string active_attempt = "attempt-new";
  if (IsStaleRecordingFailure(true, active_session, active_attempt,
                               active_session, active_attempt)) {
    return 40;
  }
  if (!IsStaleRecordingFailure(true, "session-old", active_attempt,
                                active_session, active_attempt)) {
    return 41;
  }
  if (!IsStaleRecordingFailure(true, active_session, "attempt-old",
                                active_session, active_attempt)) {
    return 42;
  }
  if (!IsStaleRecordingFailure(true, "", "", active_session,
                                active_attempt)) {
    return 43;
  }
  if (IsStaleRecordingFailure(false, "session-old", "attempt-old",
                              active_session, active_attempt)) {
    return 44;
  }
  return 0;
}

int TestOldCaptureEventCannotStopCurrentCapture() {
  if (IsStaleCaptureInstanceEvent(17, 17)) return 50;
  if (!IsStaleCaptureInstanceEvent(16, 17)) return 51;
  if (!IsStaleCaptureInstanceEvent(0, 17)) return 52;
  if (!IsStaleCaptureInstanceEvent(17, 0)) return 53;
  if (!ShouldCleanupCaptureFailure(false, true, "", "", "", "", 17,
                                   17)) {
    return 54;
  }
  if (!ShouldCleanupCaptureFailure(true, false, "session-new", "attempt-new",
                                   "session-new", "attempt-new", 17, 17)) {
    return 55;
  }
  if (ShouldCleanupCaptureFailure(true, false, "session-old", "attempt-new",
                                  "session-new", "attempt-new", 17, 17)) {
    return 56;
  }
  if (ShouldCleanupCaptureFailure(true, false, "session-new", "attempt-new",
                                  "session-new", "attempt-new", 16, 17)) {
    return 57;
  }
  if (ShouldCleanupCaptureFailure(false, true, "", "", "", "", 16,
                                  17)) {
    return 58;
  }
  if (ShouldCleanupCaptureFailure(false, true, "", "", "", "", 0, 17)) {
    return 59;
  }
  if (ShouldCleanupCaptureFailure(true, false, "session-new", "attempt-new",
                                  "session-new", "attempt-new", 0, 17)) {
    return 60;
  }
  if (ShouldCleanupCaptureFailure(true, false, "session-new", "attempt-old",
                                  "session-new", "attempt-new", 17, 17)) {
    return 61;
  }
  // When both flags are present, the recording identity is authoritative; a
  // mixed stale failure must not tear down a newer recording.
  if (ShouldCleanupCaptureFailure(true, true, "session-old", "attempt-old",
                                  "session-new", "attempt-new", 17, 17)) {
    return 62;
  }
  return 0;
}

}  // namespace

int main() {
  constexpr int64_t origin = 9'000'000;
  if (IsQpcAtOrAfterRecordingOrigin(origin - 1, origin)) return 1;
  if (!IsQpcAtOrAfterRecordingOrigin(origin, origin)) return 2;
  if (!IsQpcAtOrAfterRecordingOrigin(origin + 1, origin)) return 3;
  if (IsQpcAtOrAfterRecordingOrigin(0, origin)) return 4;
  if (IsQpcAtOrAfterRecordingOrigin(origin, 0)) return 5;

  const std::string session = "subtitle-session";
  const std::string source = "system-output";
  const std::string attempt = "capture-attempt-2";
  if (!IsMatchingAudioCaptureIdentity(session, source, attempt, session, source,
                                      attempt)) {
    return 6;
  }
  if (IsMatchingAudioCaptureIdentity("old-session", source, attempt, session,
                                     source, attempt)) {
    return 7;
  }
  if (IsMatchingAudioCaptureIdentity(session, "old-source", attempt, session,
                                     source, attempt)) {
    return 8;
  }
  if (IsMatchingAudioCaptureIdentity(session, source, "capture-attempt-1",
                                     session, source, attempt)) {
    return 9;
  }
  if (const int result = TestCaptureCallbackKeepsItsOriginalOwner();
      result != 0) {
    return result;
  }
  if (const int result =
          TestTextureUnregistrationWaitCanTimeOutAndCallbackReleasesOwner();
      result != 0) {
    return result;
  }
  if (const int result = TestRecordingFailureSignalIsOncePerRecording();
      result != 0) {
    return result;
  }
  if (const int result = TestNavigationWaitsForRecordingAudioOwner();
      result != 0) {
    return result;
  }
  if (const int result = TestOldRecordingFailureCannotStopCurrentRecording();
      result != 0) {
    return result;
  }
  if (const int result = TestOldCaptureEventCannotStopCurrentCapture();
      result != 0) {
    return result;
  }
  return 0;
}
