#include "../supervised_process_lifecycle.h"
#include "../recording_publication_policy.h"

#include <string>

namespace {

struct SingleInstanceMutexThreadContext {
  const wchar_t* mutex_name;
  HANDLE acquired_event;
  HANDLE window_ready_event;
  HANDLE ready_observed_event;
  HANDLE release_event;
};

DWORD WINAPI HoldSingleInstanceMutexUntilReleased(LPVOID raw_context) {
  auto* context = static_cast<SingleInstanceMutexThreadContext*>(raw_context);
  ::SetLastError(ERROR_SUCCESS);
  HANDLE mutex = ::CreateMutexW(nullptr, TRUE, context->mutex_name);
  if (mutex == nullptr || ::GetLastError() == ERROR_ALREADY_EXISTS) {
    if (mutex != nullptr) ::CloseHandle(mutex);
    ::SetEvent(context->acquired_event);
    return 1;
  }
  ::SetEvent(context->acquired_event);
  if (::WaitForSingleObject(context->window_ready_event, 5000) !=
      WAIT_OBJECT_0) {
    ::ReleaseMutex(mutex);
    ::CloseHandle(mutex);
    return 3;
  }
  ::SetEvent(context->ready_observed_event);
  const DWORD wait_result = ::WaitForSingleObject(context->release_event, 5000);
  const bool released = ::ReleaseMutex(mutex) != FALSE;
  ::CloseHandle(mutex);
  return wait_result == WAIT_OBJECT_0 && released ? 0 : 2;
}

struct AbandonMutexThreadContext {
  HANDLE mutex;
  HANDLE acquired_event;
};

DWORD WINAPI AcquireMutexAndExitWithoutRelease(LPVOID raw_context) {
  auto* context = static_cast<AbandonMutexThreadContext*>(raw_context);
  const DWORD wait_result = ::WaitForSingleObject(context->mutex, 0);
  ::SetEvent(context->acquired_event);
  return wait_result == WAIT_OBJECT_0 || wait_result == WAIT_ABANDONED ? 0 : 1;
}

}  // namespace

int main() {
  using yixue::runner::ShouldRegisterShutdownBlockReason;
  if (!ShouldRegisterShutdownBlockReason(WM_QUERYENDSESSION, false, false) ||
      ShouldRegisterShutdownBlockReason(WM_QUERYENDSESSION, true, false) ||
      ShouldRegisterShutdownBlockReason(WM_ENDSESSION, false, false) ||
      ShouldRegisterShutdownBlockReason(WM_QUERYENDSESSION, false, true)) {
    return 58;
  }

  using yixue::runner::ShouldNotifyFlutterOfSystemSessionEnd;
  if (!ShouldNotifyFlutterOfSystemSessionEnd(WM_ENDSESSION, TRUE, false) ||
      ShouldNotifyFlutterOfSystemSessionEnd(WM_ENDSESSION, FALSE, false) ||
      ShouldNotifyFlutterOfSystemSessionEnd(WM_QUERYENDSESSION, TRUE, false) ||
      ShouldNotifyFlutterOfSystemSessionEnd(WM_ENDSESSION, TRUE, true)) {
    return 57;
  }

  using yixue::runner::ShouldBypassSupervisorForIntegrationTest;
  if (!ShouldBypassSupervisorForIntegrationTest(true, true, false, false) ||
      ShouldBypassSupervisorForIntegrationTest(false, true, false, false) ||
      ShouldBypassSupervisorForIntegrationTest(true, false, false, false) ||
      ShouldBypassSupervisorForIntegrationTest(true, true, true, false) ||
      ShouldBypassSupervisorForIntegrationTest(true, true, false, true)) {
    return 56;
  }

  using yixue::runner::PrimaryProcessExitState;
  using yixue::runner::ResolvePrimaryProcessExitState;
  if (ResolvePrimaryProcessExitState(WAIT_OBJECT_0) !=
          PrimaryProcessExitState::kExited ||
      ResolvePrimaryProcessExitState(WAIT_TIMEOUT) !=
          PrimaryProcessExitState::kRunning ||
      ResolvePrimaryProcessExitState(WAIT_FAILED) !=
          PrimaryProcessExitState::kUnknown) {
    return 57;
  }

  using yixue::runner::OwnedProcessTreeShutdownDisposition;
  using yixue::runner::DecideOwnedProcessTreeShutdownDisposition;
  if (DecideOwnedProcessTreeShutdownDisposition(false, false) !=
          OwnedProcessTreeShutdownDisposition::kWaitForNaturalExit ||
      DecideOwnedProcessTreeShutdownDisposition(false, true) !=
          OwnedProcessTreeShutdownDisposition::kForceTerminateAfterConfirmation ||
      DecideOwnedProcessTreeShutdownDisposition(true, true) !=
          OwnedProcessTreeShutdownDisposition::kAlreadyStopped ||
      DecideOwnedProcessTreeShutdownDisposition(true, false) !=
          OwnedProcessTreeShutdownDisposition::kAlreadyStopped) {
    return 55;
  }

  using yixue::runner::SingleInstanceMutexAcquireResult;
  using yixue::runner::TryAcquireSingleInstanceMutex;
  using yixue::runner::OwnsSingleInstanceMutex;
  if (!OwnsSingleInstanceMutex(SingleInstanceMutexAcquireResult::kAcquired) ||
      !OwnsSingleInstanceMutex(SingleInstanceMutexAcquireResult::kAbandoned) ||
      OwnsSingleInstanceMutex(SingleInstanceMutexAcquireResult::kBusy) ||
      OwnsSingleInstanceMutex(SingleInstanceMutexAcquireResult::kFailed)) {
    return 46;
  }
  if (!yixue::runner::ShouldAttemptHiddenInstanceRecovery(
          SingleInstanceMutexAcquireResult::kAcquired, false) ||
      !yixue::runner::ShouldAttemptHiddenInstanceRecovery(
          SingleInstanceMutexAcquireResult::kAbandoned, false) ||
      !yixue::runner::ShouldAttemptHiddenInstanceRecovery(
          SingleInstanceMutexAcquireResult::kBusy, true) ||
      yixue::runner::ShouldAttemptHiddenInstanceRecovery(
          SingleInstanceMutexAcquireResult::kBusy, false) ||
      yixue::runner::ShouldAttemptHiddenInstanceRecovery(
          SingleInstanceMutexAcquireResult::kFailed, true)) {
    return 47;
  }
  using yixue::runner::DecideExistingInstanceAction;
  using yixue::runner::ExistingInstanceAction;
  if (DecideExistingInstanceAction(true, false, true, false) !=
          ExistingInstanceAction::kSurfaceResponsiveWindow ||
      DecideExistingInstanceAction(false, false, true, false) !=
          ExistingInstanceAction::kRecoverWithoutWindow ||
      DecideExistingInstanceAction(true, true, true, false) !=
          ExistingInstanceAction::kRecoverWithWindow ||
      DecideExistingInstanceAction(true, true, false, false) !=
          ExistingInstanceAction::kBlockRecoveryWhileStarting ||
      DecideExistingInstanceAction(false, false, false, false) !=
          ExistingInstanceAction::kBlockRecoveryWhileStarting ||
      DecideExistingInstanceAction(true, false, true, true) !=
          ExistingInstanceAction::kRecoverWithWindow ||
      DecideExistingInstanceAction(false, false, true, true) !=
          ExistingInstanceAction::kRecoverWithoutWindow) {
    return 54;
  }

  const std::wstring abandoned_mutex_name =
      L"Local\\YixueApp.AbandonedMutex.Test." +
      std::to_wstring(::GetCurrentProcessId());
  HANDLE abandoned_mutex =
      ::CreateMutexW(nullptr, FALSE, abandoned_mutex_name.c_str());
  HANDLE abandoned_acquired_event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (abandoned_mutex == nullptr || abandoned_acquired_event == nullptr) {
    if (abandoned_mutex != nullptr) ::CloseHandle(abandoned_mutex);
    if (abandoned_acquired_event != nullptr)
      ::CloseHandle(abandoned_acquired_event);
    return 48;
  }
  AbandonMutexThreadContext abandoned_context = {abandoned_mutex,
                                                  abandoned_acquired_event};
  HANDLE abandoning_thread = ::CreateThread(
      nullptr, 0, AcquireMutexAndExitWithoutRelease, &abandoned_context, 0,
      nullptr);
  if (abandoning_thread == nullptr ||
      ::WaitForSingleObject(abandoned_acquired_event, 5000) != WAIT_OBJECT_0 ||
      ::WaitForSingleObject(abandoning_thread, 5000) != WAIT_OBJECT_0) {
    if (abandoning_thread != nullptr) {
      ::WaitForSingleObject(abandoning_thread, 5000);
      ::CloseHandle(abandoning_thread);
    }
    ::CloseHandle(abandoned_acquired_event);
    ::CloseHandle(abandoned_mutex);
    return 49;
  }
  DWORD abandoned_error = ERROR_SUCCESS;
  const auto abandoned_result =
      TryAcquireSingleInstanceMutex(abandoned_mutex, &abandoned_error);
  if (abandoned_result != SingleInstanceMutexAcquireResult::kAbandoned ||
      abandoned_error != ERROR_SUCCESS || !::ReleaseMutex(abandoned_mutex)) {
    ::CloseHandle(abandoning_thread);
    ::CloseHandle(abandoned_acquired_event);
    ::CloseHandle(abandoned_mutex);
    return 50;
  }
  ::CloseHandle(abandoning_thread);
  ::CloseHandle(abandoned_acquired_event);
  ::CloseHandle(abandoned_mutex);

  using yixue::runner::RecoveryCandidateMarkerState;
  using yixue::runner::ResolveRecoveryCandidateOpenFailure;
  if (ResolveRecoveryCandidateOpenFailure(ERROR_FILE_NOT_FOUND) !=
          RecoveryCandidateMarkerState::kAbsent ||
      ResolveRecoveryCandidateOpenFailure(ERROR_ACCESS_DENIED) !=
          RecoveryCandidateMarkerState::kUnknown) {
    return 51;
  }
  using yixue::runner::SupervisorClosingState;
  using yixue::runner::ResolveSupervisorClosingProbe;
  if (ResolveSupervisorClosingProbe(false, ERROR_FILE_NOT_FOUND, WAIT_FAILED) !=
          SupervisorClosingState::kMissing ||
      ResolveSupervisorClosingProbe(false, ERROR_ACCESS_DENIED, WAIT_FAILED) !=
          SupervisorClosingState::kUnknown ||
      ResolveSupervisorClosingProbe(true, ERROR_SUCCESS, WAIT_OBJECT_0) !=
          SupervisorClosingState::kSignaled ||
      ResolveSupervisorClosingProbe(true, ERROR_SUCCESS, WAIT_TIMEOUT) !=
          SupervisorClosingState::kNotSignaled ||
      ResolveSupervisorClosingProbe(true, ERROR_SUCCESS, WAIT_FAILED) !=
          SupervisorClosingState::kUnknown) {
    return 52;
  }
  if (!yixue::runner::CanForceTerminateAfterCloseRequest(
          SupervisorClosingState::kNotSignaled) ||
      yixue::runner::CanForceTerminateAfterCloseRequest(
          SupervisorClosingState::kSignaled) ||
      yixue::runner::CanForceTerminateAfterCloseRequest(
          SupervisorClosingState::kMissing) ||
      yixue::runner::CanForceTerminateAfterCloseRequest(
          SupervisorClosingState::kUnknown)) {
    return 53;
  }
  if (!yixue::runner::IsProcessEnumerationComplete(TRUE,
                                                    ERROR_NO_MORE_FILES) ||
      yixue::runner::IsProcessEnumerationComplete(FALSE, ERROR_NO_MORE_FILES) ||
      yixue::runner::IsProcessEnumerationComplete(TRUE, ERROR_ACCESS_DENIED)) {
    return 54;
  }
  using yixue::runner::TerminateFailureWaitOutcome;
  using yixue::runner::WaitAfterTerminateFailure;
  DWORD wait_timeouts[2] = {};
  DWORD wait_count = 0;
  const auto delayed_child_exit = WaitAfterTerminateFailure(
      [&wait_timeouts, &wait_count](DWORD timeout_ms) {
        if (wait_count < 2) wait_timeouts[wait_count] = timeout_ms;
        ++wait_count;
        return wait_count == 1 ? WAIT_TIMEOUT : WAIT_OBJECT_0;
      });
  if (delayed_child_exit != TerminateFailureWaitOutcome::kProcessExited ||
      wait_count != 2 || wait_timeouts[0] != 0 ||
      wait_timeouts[1] != yixue::runner::kChildTerminationWaitMs) {
    return 41;
  }
  wait_count = 0;
  const auto process_remains_live = WaitAfterTerminateFailure(
      [&wait_count](DWORD) {
        ++wait_count;
        return WAIT_TIMEOUT;
      });
  if (process_remains_live != TerminateFailureWaitOutcome::kStillRunning ||
      wait_count != 2) {
    return 42;
  }
  wait_count = 0;
  const auto process_wait_failed = WaitAfterTerminateFailure(
      [&wait_count](DWORD) {
        ++wait_count;
        return WAIT_FAILED;
      });
  if (process_wait_failed != TerminateFailureWaitOutcome::kWaitFailed ||
      wait_count != 1) {
    return 43;
  }

  using yixue::runner::ResolveStartupAppWaitOutcome;
  using yixue::runner::StartupAppWaitOutcome;
  if (ResolveStartupAppWaitOutcome(WAIT_OBJECT_0) !=
      StartupAppWaitOutcome::kChildExited) {
    return 24;
  }
  if (ResolveStartupAppWaitOutcome(WAIT_OBJECT_0 + 1) !=
      StartupAppWaitOutcome::kCloseRequested) {
    return 25;
  }
  if (ResolveStartupAppWaitOutcome(WAIT_OBJECT_0 + 2) !=
      StartupAppWaitOutcome::kAppReady) {
    return 26;
  }
  if (ResolveStartupAppWaitOutcome(WAIT_FAILED) !=
      StartupAppWaitOutcome::kFailed) {
    return 28;
  }
  if (ResolveStartupAppWaitOutcome(WAIT_TIMEOUT) !=
      StartupAppWaitOutcome::kTimedOut) {
    return 44;
  }
  using yixue::runner::ResolveStartupProcessWaitOutcome;
  if (ResolveStartupProcessWaitOutcome(WAIT_OBJECT_0) !=
          StartupAppWaitOutcome::kChildExited ||
      ResolveStartupProcessWaitOutcome(WAIT_TIMEOUT) !=
          StartupAppWaitOutcome::kTimedOut ||
      ResolveStartupProcessWaitOutcome(WAIT_FAILED) !=
          StartupAppWaitOutcome::kFailed) {
    return 62;
  }
  using yixue::runner::ResolveStartupTimeoutChoice;
  using yixue::runner::StartupTimeoutAction;
  static_assert(yixue::runner::kStartupTimeoutDefaultButton == MB_DEFBUTTON1);
  if (ResolveStartupTimeoutChoice(IDYES) !=
          StartupTimeoutAction::kContinueWaiting ||
      ResolveStartupTimeoutChoice(IDNO) !=
          StartupTimeoutAction::kCancelStartup ||
      ResolveStartupTimeoutChoice(IDCANCEL) !=
          StartupTimeoutAction::kCancelStartup) {
    return 60;
  }
  using yixue::runner::ShouldPostStartupCloseRequest;
  using yixue::runner::ShouldDelayStartupForcePromptAfterWaitFailure;
  if (!ShouldDelayStartupForcePromptAfterWaitFailure(true, WAIT_FAILED) ||
      ShouldDelayStartupForcePromptAfterWaitFailure(false, WAIT_FAILED) ||
      ShouldDelayStartupForcePromptAfterWaitFailure(true, WAIT_TIMEOUT) ||
      ShouldDelayStartupForcePromptAfterWaitFailure(true, WAIT_OBJECT_0)) {
    return 63;
  }
  if (!ShouldPostStartupCloseRequest(true, true, 42, 42) ||
      ShouldPostStartupCloseRequest(false, true, 42, 42) ||
      ShouldPostStartupCloseRequest(true, false, 42, 42) ||
      ShouldPostStartupCloseRequest(true, true, 99, 42) ||
      ShouldPostStartupCloseRequest(true, true, 0, 42) ||
      ShouldPostStartupCloseRequest(true, true, 42, 0)) {
    return 61;
  }
  if (!yixue::runner::ShouldWaitForAppLifetime(
          StartupAppWaitOutcome::kAppReady) ||
      yixue::runner::ShouldWaitForAppLifetime(
          StartupAppWaitOutcome::kTimedOut) ||
      yixue::runner::ShouldWaitForAppLifetime(
          StartupAppWaitOutcome::kChildExited) ||
      yixue::runner::ShouldWaitForAppLifetime(
          StartupAppWaitOutcome::kCloseRequested) ||
      yixue::runner::ShouldWaitForAppLifetime(
          StartupAppWaitOutcome::kFailed)) {
    return 45;
  }
  static_assert(yixue::runner::kChildStartupTimeoutMs >= 60'000 &&
                yixue::runner::kChildStartupTimeoutMs <= 180'000);

  using yixue::runner::ChildShutdownDisposition;
  using yixue::runner::DecideChildShutdownDisposition;

  if (DecideChildShutdownDisposition(true) !=
      ChildShutdownDisposition::kAlreadyExited) {
    return 1;
  }
  if (DecideChildShutdownDisposition(false) !=
      ChildShutdownDisposition::kWaitForNaturalExit) {
    return 2;
  }
  if (DecideChildShutdownDisposition(false, true) !=
      ChildShutdownDisposition::kForceTerminateOwnedProcessTree) {
    return 3;
  }
  if (DecideChildShutdownDisposition(true, true) !=
      ChildShutdownDisposition::kAlreadyExited) {
    return 4;
  }
  using yixue::runner::IsOwnedProcessTreeConfirmedStopped;
  if (!IsOwnedProcessTreeConfirmedStopped(true, true, 0) ||
      IsOwnedProcessTreeConfirmedStopped(false, true, 0) ||
      IsOwnedProcessTreeConfirmedStopped(true, true, 1) ||
      IsOwnedProcessTreeConfirmedStopped(true, false, 0)) {
    return 55;
  }
  using yixue::runner::CanReleaseSingleInstanceMutex;
  if (CanReleaseSingleInstanceMutex(false) ||
      !CanReleaseSingleInstanceMutex(true)) {
    return 57;
  }
  static_assert(yixue::runner::kChildShutdownGracePeriodMs >= 60'000 &&
                yixue::runner::kChildShutdownGracePeriodMs <= 90'000);
  static_assert(yixue::runner::kChildTerminationWaitMs > 0);
  static_assert(yixue::runner::ShouldUseLocalUiCleanupWatchdog(false));
  static_assert(!yixue::runner::ShouldUseLocalUiCleanupWatchdog(true));
  static_assert(yixue::runner::ShouldDeferHungUiCleanupToSupervisor(true));
  static_assert(!yixue::runner::ShouldDeferHungUiCleanupToSupervisor(false));
  using yixue::runner::ShouldRepeatNaturalShutdownPrompt;
  if (!ShouldRepeatNaturalShutdownPrompt(WAIT_TIMEOUT) ||
      !ShouldRepeatNaturalShutdownPrompt(WAIT_FAILED) ||
      !ShouldRepeatNaturalShutdownPrompt(WAIT_ABANDONED) ||
      ShouldRepeatNaturalShutdownPrompt(WAIT_OBJECT_0)) {
    return 58;
  }
  using yixue::runner::ShouldBackoffBeforeRepeatedShutdownPrompt;
  if (ShouldBackoffBeforeRepeatedShutdownPrompt(WAIT_TIMEOUT) ||
      ShouldBackoffBeforeRepeatedShutdownPrompt(WAIT_OBJECT_0) ||
      !ShouldBackoffBeforeRepeatedShutdownPrompt(WAIT_FAILED) ||
      !ShouldBackoffBeforeRepeatedShutdownPrompt(WAIT_ABANDONED)) {
    return 59;
  }
  using yixue::runner::DecideMessageLoopDisposition;
  using yixue::runner::MessageLoopDisposition;
  if (DecideMessageLoopDisposition(1) !=
      MessageLoopDisposition::kDispatchMessage) {
    return 5;
  }
  if (DecideMessageLoopDisposition(0) !=
      MessageLoopDisposition::kExitNormally) {
    return 6;
  }
  if (DecideMessageLoopDisposition(-1) !=
      MessageLoopDisposition::kReportFailure) {
    return 7;
  }
  using yixue::runner::InstanceRecoveryOutcome;
  using yixue::runner::ShouldContinueAfterInstanceRecovery;
  using yixue::runner::ShouldAbortRecoveryForStartupCandidate;
  if (ShouldAbortRecoveryForStartupCandidate(0)) return 29;
  if (!ShouldAbortRecoveryForStartupCandidate(1) ||
      !ShouldAbortRecoveryForStartupCandidate(2)) {
    return 30;
  }
  if (!ShouldContinueAfterInstanceRecovery(
          InstanceRecoveryOutcome::kAllOldProcessesStopped)) {
    return 8;
  }
  if (ShouldContinueAfterInstanceRecovery(
          InstanceRecoveryOutcome::kNoOldProcessFound) ||
      ShouldContinueAfterInstanceRecovery(
          InstanceRecoveryOutcome::kProcessEnumerationIncomplete) ||
      ShouldContinueAfterInstanceRecovery(
          InstanceRecoveryOutcome::kSomeProcessesNotAccessible) ||
      ShouldContinueAfterInstanceRecovery(
          InstanceRecoveryOutcome::kSomeProcessesStillRunning)) {
    return 9;
  }
  if (yixue::runner::ShouldContinueAfterNoOldInstance(false) ||
      !yixue::runner::ShouldContinueAfterNoOldInstance(true)) {
    return 41;
  }
  using yixue::runner::IsSameYixueProcessFamilyPath;
  if (!IsSameYixueProcessFamilyPath(
          L"D:\\译学助手\\releases\\preview\\v0.1.0-7-preview.local-dirty.20261018-215904-35204ccf\\yixue_app.exe",
          L"D:\\译学助手\\releases\\preview\\v0.1.0-7-preview.local-dirty.20261019-013804-35204ccf\\yixue_app.exe")) {
    return 12;
  }
  if (IsSameYixueProcessFamilyPath(
          L"D:\\译学助手\\releases\\preview\\v0.1.0-7-preview.local-dirty.20261018-215904-35204ccf\\yixue_app.exe",
          L"E:\\译学助手\\releases\\preview\\v0.1.0-7-preview.local-dirty.20261019-013804-35204ccf\\yixue_app.exe")) {
    return 13;
  }
  if (IsSameYixueProcessFamilyPath(
          L"D:\\OtherApp\\releases\\preview\\v1\\yixue_app.exe",
          L"D:\\译学助手\\releases\\preview\\v1\\yixue_app.exe")) {
    return 14;
  }
  if (!IsSameYixueProcessFamilyPath(
          L"D:\\译学助手\\releases\\preview\\v1\\yixue_app.exe",
          L"d:/译学助手/releases/preview/V2/yixue_app.exe")) {
    return 15;
  }
  if (IsSameYixueProcessFamilyPath(
          L"D:\\译学助手\\releases\\previewXYZ\\v1\\yixue_app.exe",
          L"D:\\译学助手\\releases\\preview\\v2\\yixue_app.exe")) {
    return 16;
  }

  const std::wstring recovery_mutex_name =
      L"Local\\YixueApp.RecoveryGate.Test." +
      std::to_wstring(::GetCurrentProcessId());
  {
    yixue::runner::InstanceRecoveryGate first(recovery_mutex_name.c_str());
    if (!first.acquired()) return 17;
    yixue::runner::InstanceRecoveryGate concurrent(
        recovery_mutex_name.c_str());
    if (concurrent.acquired() || concurrent.error() != ERROR_ALREADY_EXISTS) {
      return 18;
    }
  }
  {
    yixue::runner::InstanceRecoveryGate retry(recovery_mutex_name.c_str());
    if (!retry.acquired()) return 19;
  }

  const auto candidate_event_name =
      yixue::runner::RecoveryCandidateEventName(::GetCurrentProcessId());
  HANDLE candidate_event = ::CreateEventW(nullptr, TRUE, TRUE,
                                          candidate_event_name.c_str());
  if (candidate_event == nullptr) return 20;
  if (yixue::runner::ProbeRecoveryCandidateProcess(::GetCurrentProcessId()) !=
      RecoveryCandidateMarkerState::kPresent) {
    ::CloseHandle(candidate_event);
    return 21;
  }
  ::CloseHandle(candidate_event);
  if (yixue::runner::ProbeRecoveryCandidateProcess(::GetCurrentProcessId()) !=
      RecoveryCandidateMarkerState::kAbsent) {
    return 22;
  }

  // A launcher must treat an owned instance mutex as a startup lease and must
  // never scan/recover processes while another launcher owns that lease.
  const std::wstring instance_mutex_name =
      L"Local\\YixueApp.SingleInstance.Test." +
      std::to_wstring(::GetCurrentProcessId());
  HANDLE acquired_event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE window_ready_event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE ready_observed_event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE release_event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (acquired_event == nullptr || window_ready_event == nullptr ||
      ready_observed_event == nullptr || release_event == nullptr) {
    if (acquired_event != nullptr) ::CloseHandle(acquired_event);
    if (window_ready_event != nullptr) ::CloseHandle(window_ready_event);
    if (ready_observed_event != nullptr) ::CloseHandle(ready_observed_event);
    if (release_event != nullptr) ::CloseHandle(release_event);
    return 31;
  }
  SingleInstanceMutexThreadContext thread_context = {
      instance_mutex_name.c_str(), acquired_event, window_ready_event,
      ready_observed_event, release_event};
  HANDLE owner_thread = ::CreateThread(
      nullptr, 0, HoldSingleInstanceMutexUntilReleased, &thread_context, 0,
      nullptr);
  if (owner_thread == nullptr) {
    ::CloseHandle(release_event);
    ::CloseHandle(ready_observed_event);
    ::CloseHandle(window_ready_event);
    ::CloseHandle(acquired_event);
    return 32;
  }
  if (::WaitForSingleObject(acquired_event, 5000) != WAIT_OBJECT_0) {
    ::SetEvent(release_event);
    ::WaitForSingleObject(owner_thread, 5000);
    ::CloseHandle(owner_thread);
    ::CloseHandle(release_event);
    ::CloseHandle(ready_observed_event);
    ::CloseHandle(window_ready_event);
    ::CloseHandle(acquired_event);
    return 33;
  }
  ::SetLastError(ERROR_SUCCESS);
  HANDLE contender_mutex = ::CreateMutexW(nullptr, FALSE,
                                          instance_mutex_name.c_str());
  if (contender_mutex == nullptr || ::GetLastError() != ERROR_ALREADY_EXISTS) {
    if (contender_mutex != nullptr) ::CloseHandle(contender_mutex);
    ::SetEvent(release_event);
    ::WaitForSingleObject(owner_thread, 5000);
    ::CloseHandle(owner_thread);
    ::CloseHandle(release_event);
    ::CloseHandle(ready_observed_event);
    ::CloseHandle(window_ready_event);
    ::CloseHandle(acquired_event);
    return 34;
  }
  // The startup lease remains owned until the Dart app-ready signal, then
  // prove a contender
  // still cannot acquire the mutex and enter hidden-instance recovery.
  ::SetEvent(window_ready_event);
  if (::WaitForSingleObject(ready_observed_event, 5000) != WAIT_OBJECT_0) {
    ::SetEvent(release_event);
    ::WaitForSingleObject(owner_thread, 5000);
    ::CloseHandle(contender_mutex);
    ::CloseHandle(owner_thread);
    ::CloseHandle(release_event);
    ::CloseHandle(ready_observed_event);
    ::CloseHandle(window_ready_event);
    ::CloseHandle(acquired_event);
    return 40;
  }
  DWORD mutex_error = ERROR_SUCCESS;
  const auto busy_result =
      yixue::runner::TryAcquireSingleInstanceMutex(contender_mutex,
                                                   &mutex_error);
  if (busy_result != yixue::runner::SingleInstanceMutexAcquireResult::kBusy ||
      mutex_error != ERROR_SUCCESS ||
      yixue::runner::ShouldAttemptHiddenInstanceRecovery(busy_result, false) ||
      !yixue::runner::ShouldAttemptHiddenInstanceRecovery(busy_result, true)) {
    ::SetEvent(release_event);
    ::WaitForSingleObject(owner_thread, 5000);
    ::CloseHandle(contender_mutex);
    ::CloseHandle(owner_thread);
    ::CloseHandle(release_event);
    ::CloseHandle(ready_observed_event);
    ::CloseHandle(window_ready_event);
    ::CloseHandle(acquired_event);
    return 35;
  }
  ::SetEvent(release_event);
  if (::WaitForSingleObject(owner_thread, 5000) != WAIT_OBJECT_0) {
    ::CloseHandle(contender_mutex);
    ::CloseHandle(owner_thread);
    ::CloseHandle(release_event);
    ::CloseHandle(ready_observed_event);
    ::CloseHandle(window_ready_event);
    ::CloseHandle(acquired_event);
    return 36;
  }
  DWORD owner_thread_exit_code = 1;
  if (!::GetExitCodeThread(owner_thread, &owner_thread_exit_code) ||
      owner_thread_exit_code != 0) {
    ::CloseHandle(contender_mutex);
    ::CloseHandle(owner_thread);
    ::CloseHandle(release_event);
    ::CloseHandle(ready_observed_event);
    ::CloseHandle(window_ready_event);
    ::CloseHandle(acquired_event);
    return 37;
  }
  const auto retry_result =
      yixue::runner::TryAcquireSingleInstanceMutex(contender_mutex,
                                                   &mutex_error);
  if (retry_result !=
          yixue::runner::SingleInstanceMutexAcquireResult::kAcquired ||
      mutex_error != ERROR_SUCCESS ||
      !yixue::runner::ShouldAttemptHiddenInstanceRecovery(retry_result,
                                                         false)) {
    ::CloseHandle(contender_mutex);
    ::CloseHandle(owner_thread);
    ::CloseHandle(release_event);
    ::CloseHandle(ready_observed_event);
    ::CloseHandle(window_ready_event);
    ::CloseHandle(acquired_event);
    return 38;
  }
  if (!::ReleaseMutex(contender_mutex)) {
    ::CloseHandle(contender_mutex);
    ::CloseHandle(owner_thread);
    ::CloseHandle(release_event);
    ::CloseHandle(ready_observed_event);
    ::CloseHandle(window_ready_event);
    ::CloseHandle(acquired_event);
    return 39;
  }
  ::CloseHandle(contender_mutex);
  ::CloseHandle(owner_thread);
  ::CloseHandle(release_event);
  ::CloseHandle(ready_observed_event);
  ::CloseHandle(window_ready_event);
  ::CloseHandle(acquired_event);

  if (yixue::runner::CanPublishScreenRecording(0)) return 10;
  if (!yixue::runner::CanPublishScreenRecording(1)) return 11;
  return 0;
}
