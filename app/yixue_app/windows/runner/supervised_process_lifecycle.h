#ifndef RUNNER_SUPERVISED_PROCESS_LIFECYCLE_H_
#define RUNNER_SUPERVISED_PROCESS_LIFECYCLE_H_

#include <windows.h>

#include <cstddef>
#include <limits>
#include <string>
#include <string_view>

namespace yixue::runner {

// A close can spend time stopping WASAPI, Windows Graphics Capture, and the
// Media Foundation writer. After a minute, ask the user before ending a process
// that may still be writing a media file.
inline constexpr DWORD kChildShutdownGracePeriodMs = 60'000;
inline constexpr DWORD kChildStartupTimeoutMs = 120'000;
inline constexpr DWORD kChildTerminationWaitMs = 5'000;
inline constexpr DWORD kForcedChildExitCode = 0xE0010001;
inline constexpr UINT kRestoreMainWindowMessage = WM_APP + 44;
inline constexpr wchar_t kRecoveryCandidateEventNamePrefix[] =
    L"Local\\YixueApp.RecoveryCandidate.";
inline constexpr wchar_t kSupervisorClosingEventName[] =
    L"Local\\YixueApp.SupervisorClosing.v1";

constexpr bool ShouldNotifyFlutterOfSystemSessionEnd(
    UINT message, WPARAM session_end_wparam, bool subtitle_process) noexcept {
  // WM_QUERYENDSESSION must be answered immediately. Begin the asynchronous
  // save/close flow only after Windows confirms the session is ending.
  return !subtitle_process && message == WM_ENDSESSION &&
         session_end_wparam != FALSE;
}

constexpr bool ShouldRegisterShutdownBlockReason(
    UINT message, bool window_visible, bool subtitle_process) noexcept {
  // Hidden tray windows normally receive only a short shutdown grace period.
  // A reason registered during WM_QUERYENDSESSION lets the app use the normal
  // visible-window shutdown window while still agreeing to the session end.
  return !subtitle_process && message == WM_QUERYENDSESSION && !window_visible;
}

constexpr bool ShouldUseLocalUiCleanupWatchdog(bool supervised_ui) noexcept {
  // The supervisor owns the timeout and asks the user before terminating its
  // child. A child-local timer must not preempt that explicit decision.
  return !supervised_ui;
}

constexpr bool ShouldDeferHungUiCleanupToSupervisor(
    bool supervised_ui) noexcept {
  // A supervised child must remain alive until its parent asks the user before
  // terminating a native media worker that may still be finalizing a file.
  return supervised_ui;
}

constexpr bool ShouldBypassSupervisorForIntegrationTest(
    bool debug_build, bool integration_test_requested, bool subtitle_process,
    bool supervised_ui) noexcept {
  // Flutter's Windows integration runner must attach to the process that owns
  // the VM service. Keep this opt-in bypass unavailable in Release builds and
  // never apply it to subtitle children or an already-supervised UI process.
  return debug_build && integration_test_requested && !subtitle_process &&
         !supervised_ui;
}

constexpr bool ShouldRepeatNaturalShutdownPrompt(DWORD wait_result) noexcept {
  // A wait timeout or failure is not proof that the child exited. When the
  // user chose to keep waiting, ask again after another bounded interval.
  return wait_result != WAIT_OBJECT_0;
}

enum class PrimaryProcessExitState {
  kRunning,
  kExited,
  kUnknown,
};

constexpr PrimaryProcessExitState ResolvePrimaryProcessExitState(
    DWORD wait_result) noexcept {
  if (wait_result == WAIT_OBJECT_0) return PrimaryProcessExitState::kExited;
  if (wait_result == WAIT_TIMEOUT) return PrimaryProcessExitState::kRunning;
  return PrimaryProcessExitState::kUnknown;
}

constexpr bool ShouldBackoffBeforeRepeatedShutdownPrompt(
    DWORD wait_result) noexcept {
  // WAIT_TIMEOUT already consumed the full grace period. Unexpected wait
  // results can fail immediately, so delay before asking the user again.
  return wait_result != WAIT_OBJECT_0 && wait_result != WAIT_TIMEOUT;
}

enum class StartupAppWaitOutcome {
  kAppReady,
  kChildExited,
  kCloseRequested,
  kTimedOut,
  kFailed,
};

enum class StartupTimeoutAction {
  kContinueWaiting,
  kCancelStartup,
};

inline constexpr UINT kStartupTimeoutDefaultButton = MB_DEFBUTTON1;

constexpr StartupTimeoutAction ResolveStartupTimeoutChoice(
    int dialog_result) noexcept {
  return dialog_result == IDYES ? StartupTimeoutAction::kContinueWaiting
                                : StartupTimeoutAction::kCancelStartup;
}

constexpr bool ShouldPostStartupCloseRequest(
    bool child_is_running, bool window_found, DWORD window_process_id,
    DWORD child_process_id) noexcept {
  return child_is_running && window_found && child_process_id != 0 &&
         window_process_id == child_process_id;
}

enum class SingleInstanceMutexAcquireResult {
  kAcquired,
  kAbandoned,
  kBusy,
  kFailed,
};

inline SingleInstanceMutexAcquireResult TryAcquireSingleInstanceMutex(
    HANDLE mutex, DWORD* error) noexcept {
  if (error != nullptr) *error = ERROR_SUCCESS;
  if (mutex == nullptr) {
    if (error != nullptr) *error = ERROR_INVALID_HANDLE;
    return SingleInstanceMutexAcquireResult::kFailed;
  }
  const DWORD wait_result = ::WaitForSingleObject(mutex, 0);
  if (wait_result == WAIT_OBJECT_0) {
    return SingleInstanceMutexAcquireResult::kAcquired;
  }
  if (wait_result == WAIT_ABANDONED) {
    return SingleInstanceMutexAcquireResult::kAbandoned;
  }
  if (wait_result == WAIT_TIMEOUT) {
    return SingleInstanceMutexAcquireResult::kBusy;
  }
  if (error != nullptr) {
    *error = wait_result == WAIT_FAILED ? ::GetLastError() : ERROR_GEN_FAILURE;
  }
  return SingleInstanceMutexAcquireResult::kFailed;
}

constexpr bool OwnsSingleInstanceMutex(
    SingleInstanceMutexAcquireResult result) noexcept {
  return result == SingleInstanceMutexAcquireResult::kAcquired ||
         result == SingleInstanceMutexAcquireResult::kAbandoned;
}

constexpr bool ShouldAttemptHiddenInstanceRecovery(
    SingleInstanceMutexAcquireResult result, bool window_found) noexcept {
  // A busy mutex belongs to a live supervisor. Recovery may ask that
  // supervisor's verified but hung window to close gracefully; without a
  // window there is no evidence that the owner is stale, so never scan for or
  // terminate same-path processes. An acquired/abandoned mutex is safe to
  // recover after checking for concurrent startup candidates.
  if (result == SingleInstanceMutexAcquireResult::kBusy) {
    return window_found;
  }
  return result == SingleInstanceMutexAcquireResult::kAcquired ||
         result == SingleInstanceMutexAcquireResult::kAbandoned;
}

constexpr StartupAppWaitOutcome ResolveStartupAppWaitOutcome(
    DWORD wait_result) noexcept {
  if (wait_result == WAIT_OBJECT_0) {
    return StartupAppWaitOutcome::kChildExited;
  }
  if (wait_result == WAIT_OBJECT_0 + 1) {
    return StartupAppWaitOutcome::kCloseRequested;
  }
  if (wait_result == WAIT_OBJECT_0 + 2) {
    return StartupAppWaitOutcome::kAppReady;
  }
  if (wait_result == WAIT_TIMEOUT) {
    return StartupAppWaitOutcome::kTimedOut;
  }
  return StartupAppWaitOutcome::kFailed;
}

constexpr StartupAppWaitOutcome ResolveStartupProcessWaitOutcome(
    DWORD wait_result) noexcept {
  if (wait_result == WAIT_OBJECT_0) {
    return StartupAppWaitOutcome::kChildExited;
  }
  if (wait_result == WAIT_TIMEOUT) {
    return StartupAppWaitOutcome::kTimedOut;
  }
  return StartupAppWaitOutcome::kFailed;
}

constexpr bool ShouldDelayStartupForcePromptAfterWaitFailure(
    bool startup_cancel_requested, DWORD close_wait_result) noexcept {
  return startup_cancel_requested && close_wait_result == WAIT_FAILED;
}

constexpr bool ShouldWaitForAppLifetime(
    StartupAppWaitOutcome outcome) noexcept {
  return outcome == StartupAppWaitOutcome::kAppReady;
}

enum class ChildShutdownDisposition {
  kAlreadyExited,
  kWaitForNaturalExit,
  kForceTerminateOwnedProcessTree,
};

enum class OwnedProcessTreeShutdownDisposition {
  kAlreadyStopped,
  kWaitForNaturalExit,
  kForceTerminateAfterConfirmation,
};

constexpr OwnedProcessTreeShutdownDisposition
DecideOwnedProcessTreeShutdownDisposition(
    bool process_tree_confirmed_stopped,
    bool force_termination_confirmed) noexcept {
  if (process_tree_confirmed_stopped) {
    return OwnedProcessTreeShutdownDisposition::kAlreadyStopped;
  }
  return force_termination_confirmed
             ? OwnedProcessTreeShutdownDisposition::
                   kForceTerminateAfterConfirmation
             : OwnedProcessTreeShutdownDisposition::kWaitForNaturalExit;
}

enum class MessageLoopDisposition {
  kDispatchMessage,
  kExitNormally,
  kReportFailure,
};

enum class InstanceRecoveryOutcome {
  kAllOldProcessesStopped,
  kNoOldProcessFound,
  kProcessEnumerationIncomplete,
  kSomeProcessesNotAccessible,
  kSomeProcessesStillRunning,
};

enum class RecoveryCandidateMarkerState {
  kPresent,
  kAbsent,
  kUnknown,
};

enum class SupervisorClosingState {
  kSignaled,
  kNotSignaled,
  kMissing,
  kUnknown,
};

enum class ExistingInstanceAction {
  kSurfaceResponsiveWindow,
  kBlockRecoveryWhileStarting,
  kRecoverWithoutWindow,
  kRecoverWithWindow,
};

// A hung HWND is still useful recovery evidence. Keep it so recovery can
// verify its owning process and try WM_CLOSE before considering force exit.
constexpr ExistingInstanceAction DecideExistingInstanceAction(
    bool window_found, bool window_hung, bool recovery_allowed,
    bool launcher_owns_mutex) noexcept {
  if (window_found && !window_hung && !launcher_owns_mutex) {
    return ExistingInstanceAction::kSurfaceResponsiveWindow;
  }
  if (!recovery_allowed && (!window_found || window_hung)) {
    return ExistingInstanceAction::kBlockRecoveryWhileStarting;
  }
  if (window_found) return ExistingInstanceAction::kRecoverWithWindow;
  return ExistingInstanceAction::kRecoverWithoutWindow;
}

constexpr RecoveryCandidateMarkerState ResolveRecoveryCandidateOpenFailure(
    DWORD error) noexcept {
  return error == ERROR_FILE_NOT_FOUND
             ? RecoveryCandidateMarkerState::kAbsent
             : RecoveryCandidateMarkerState::kUnknown;
}

constexpr SupervisorClosingState ResolveSupervisorClosingProbe(
    bool event_opened, DWORD open_error, DWORD wait_result) noexcept {
  if (!event_opened) {
    return open_error == ERROR_FILE_NOT_FOUND
               ? SupervisorClosingState::kMissing
               : SupervisorClosingState::kUnknown;
  }
  if (wait_result == WAIT_OBJECT_0) return SupervisorClosingState::kSignaled;
  if (wait_result == WAIT_TIMEOUT) return SupervisorClosingState::kNotSignaled;
  return SupervisorClosingState::kUnknown;
}

constexpr bool IsProcessEnumerationComplete(bool first_succeeded,
                                            DWORD final_error) noexcept {
  return first_succeeded && final_error == ERROR_NO_MORE_FILES;
}

constexpr bool CanForceTerminateAfterCloseRequest(
    SupervisorClosingState closing_state) noexcept {
  return closing_state == SupervisorClosingState::kNotSignaled;
}

enum class TerminateFailureWaitOutcome {
  kProcessExited,
  kStillRunning,
  kWaitFailed,
};

// A process-tree shutdown is confirmed only when the primary process has
// exited and a still-open job handle reports no active members. Waiting for
// the primary process alone cannot prove that descendants have exited.
constexpr bool IsOwnedProcessTreeConfirmedStopped(
    bool primary_process_signaled, bool job_accounting_available,
    DWORD active_processes) noexcept {
  return primary_process_signaled && job_accounting_available &&
         active_processes == 0;
}

// The launcher owns the single-instance mutex for as long as any supervised
// process may still access the user's data directory.
constexpr bool CanReleaseSingleInstanceMutex(
    bool process_tree_confirmed_stopped) noexcept {
  return process_tree_confirmed_stopped;
}

// TerminateProcess can fail with access denied when a parent supervisor has
// already closed its job handle and Windows is still asynchronously stopping
// the child. Give that existing shutdown a bounded chance to finish before
// reporting a live-process lock conflict.
template <typename WaitForProcess>
inline TerminateFailureWaitOutcome WaitAfterTerminateFailure(
    WaitForProcess&& wait_for_process) {
  const DWORD immediate = wait_for_process(0);
  if (immediate == WAIT_OBJECT_0) {
    return TerminateFailureWaitOutcome::kProcessExited;
  }
  if (immediate == WAIT_FAILED) {
    return TerminateFailureWaitOutcome::kWaitFailed;
  }

  const DWORD bounded = wait_for_process(kChildTerminationWaitMs);
  if (bounded == WAIT_OBJECT_0) {
    return TerminateFailureWaitOutcome::kProcessExited;
  }
  return bounded == WAIT_FAILED ? TerminateFailureWaitOutcome::kWaitFailed
                                : TerminateFailureWaitOutcome::kStillRunning;
}

constexpr bool ShouldAbortRecoveryForStartupCandidate(
    std::size_t startup_candidate_count) noexcept {
  return startup_candidate_count != 0;
}

constexpr bool ShouldContinueAfterInstanceRecovery(
    InstanceRecoveryOutcome outcome) noexcept {
  return outcome == InstanceRecoveryOutcome::kAllOldProcessesStopped;
}

constexpr bool ShouldContinueAfterNoOldInstance(
    bool single_instance_mutex_owned) noexcept {
  return single_instance_mutex_owned;
}

inline bool IsSamePathOrdinalIgnoreCase(std::wstring_view left,
                                        std::wstring_view right) noexcept {
  if (left.size() != right.size()) return false;
  for (std::size_t index = 0; index < left.size(); ++index) {
    wchar_t left_character = left[index] == L'/' ? L'\\' : left[index];
    wchar_t right_character = right[index] == L'/' ? L'\\' : right[index];
    if (::CompareStringOrdinal(&left_character, 1, &right_character, 1,
                               TRUE) != CSTR_EQUAL) {
      return false;
    }
  }
  return true;
}

inline constexpr bool IsPathSeparator(wchar_t character) noexcept {
  return character == L'\\' || character == L'/';
}

inline bool TryGetPreviewFamilyRoot(std::wstring_view path,
                                    std::wstring_view* root) noexcept {
  constexpr std::wstring_view kPreviewMarker = L"\\releases\\preview";
  if (root == nullptr) return false;
  for (std::size_t index = 0; index + kPreviewMarker.size() <= path.size();
       ++index) {
    if (!IsSamePathOrdinalIgnoreCase(
            path.substr(index, kPreviewMarker.size()), kPreviewMarker)) {
      continue;
    }
    const std::size_t root_end = index + kPreviewMarker.size();
    if (root_end < path.size() && !IsPathSeparator(path[root_end])) continue;
    *root = path.substr(0, root_end);
    return true;
  }
  return false;
}

// Preview builds share the same user-data directory across versioned release
// folders. Recover older builds from this preview root, while keeping separate
// checkouts and unrelated installations isolated.
inline bool IsSameYixueProcessFamilyPath(std::wstring_view candidate_path,
                                        std::wstring_view current_path) noexcept {
  if (IsSamePathOrdinalIgnoreCase(candidate_path, current_path)) return true;
  std::wstring_view candidate_root;
  std::wstring_view current_root;
  if (!TryGetPreviewFamilyRoot(candidate_path, &candidate_root) ||
      !TryGetPreviewFamilyRoot(current_path, &current_root)) {
    return false;
  }
  if (IsSamePathOrdinalIgnoreCase(candidate_root, current_root)) return true;

  // A different drive can have a different local database even when the
  // product-relative path is identical. Fail closed rather than terminating
  // a process whose data-directory identity cannot be proven.
  return false;
}

inline std::wstring RecoveryCandidateEventName(DWORD process_id) {
  return std::wstring(kRecoveryCandidateEventNamePrefix) +
         std::to_wstring(process_id);
}

inline RecoveryCandidateMarkerState ProbeRecoveryCandidateProcess(
    DWORD process_id) noexcept {
  try {
    const std::wstring event_name = RecoveryCandidateEventName(process_id);
    HANDLE event = ::OpenEventW(SYNCHRONIZE, FALSE, event_name.c_str());
    if (event == nullptr) {
      return ResolveRecoveryCandidateOpenFailure(::GetLastError());
    }
    ::CloseHandle(event);
    return RecoveryCandidateMarkerState::kPresent;
  } catch (...) {
    return RecoveryCandidateMarkerState::kUnknown;
  }
}

class InstanceRecoveryGate {
 public:
  explicit InstanceRecoveryGate(const wchar_t* name) noexcept {
    ::SetLastError(ERROR_SUCCESS);
    handle_ = ::CreateMutexW(nullptr, TRUE, name);
    if (handle_ == nullptr) {
      error_ = ::GetLastError();
      return;
    }
    if (::GetLastError() == ERROR_ALREADY_EXISTS) {
      error_ = ERROR_ALREADY_EXISTS;
      ::CloseHandle(handle_);
      handle_ = nullptr;
      return;
    }
    acquired_ = true;
  }

  ~InstanceRecoveryGate() {
    if (handle_ == nullptr) return;
    if (acquired_) ::ReleaseMutex(handle_);
    ::CloseHandle(handle_);
  }

  InstanceRecoveryGate(const InstanceRecoveryGate&) = delete;
  InstanceRecoveryGate& operator=(const InstanceRecoveryGate&) = delete;

  bool acquired() const noexcept { return acquired_; }
  DWORD error() const noexcept { return error_; }

 private:
  HANDLE handle_ = nullptr;
  DWORD error_ = ERROR_SUCCESS;
  bool acquired_ = false;
};

constexpr MessageLoopDisposition DecideMessageLoopDisposition(
    int get_message_result) noexcept {
  if (get_message_result > 0) {
    return MessageLoopDisposition::kDispatchMessage;
  }
  return get_message_result == 0 ? MessageLoopDisposition::kExitNormally
                                 : MessageLoopDisposition::kReportFailure;
}

constexpr ChildShutdownDisposition DecideChildShutdownDisposition(
    bool child_exited_before_deadline,
    bool force_termination_confirmed = false) noexcept {
  return child_exited_before_deadline
             ? ChildShutdownDisposition::kAlreadyExited
             : force_termination_confirmed
                   ? ChildShutdownDisposition::kForceTerminateOwnedProcessTree
                   : ChildShutdownDisposition::kWaitForNaturalExit;
}

// Implemented by the runner entry point. FlutterWindow signals this before
// any potentially blocking native-media teardown begins.
void SignalParentSupervisorCloseRequest() noexcept;

// Starts the runner-owned cleanup watchdog after Dart has committed to exit,
// before native process/window teardown can become stuck. WM_DESTROY and the
// message-loop exit remain idempotent fallback signals.
void SignalUiCleanupWatchdogStart() noexcept;

// Implemented by the runner entry point. Dart calls this only after the main
// startup gate has rendered a usable application or recoverable error screen.
bool SignalParentSupervisorAppReady() noexcept;

}  // namespace yixue::runner

#endif  // RUNNER_SUPERVISED_PROCESS_LIFECYCLE_H_
