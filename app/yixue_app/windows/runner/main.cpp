#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "supervised_process_lifecycle.h"
#include "supervisor_diagnostics.h"
#include "ui_cleanup_watchdog_state.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <memory>
#include <new>
#include <optional>
#include <process.h>
#include <string>
#include <thread>
#include <tlhelp32.h>
#include <vector>

namespace {

constexpr wchar_t kSingleInstanceMutexName[] =
    L"Local\\YixueApp.SingleInstance.v1";
constexpr wchar_t kInstanceRecoveryMutexName[] =
    L"Local\\YixueApp.InstanceRecovery.v1";
constexpr wchar_t kMainWindowClassName[] =
    L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kMainWindowTitle[] = L"\u8BD1\u5B66";
constexpr wchar_t kSubtitleWindowTitle[] = L"\u8BD1\u5B66\u5B57\u5E55";
constexpr char kSubtitleChildArgument[] = "--yixue-subtitle-child";
constexpr char kSupervisedUiArgument[] = "--yixue-supervised-ui";
constexpr wchar_t kSupervisedUiArgumentWide[] = L"--yixue-supervised-ui";
constexpr DWORD kUiCleanupWatchdogTimeoutMs = 45'000;
constexpr char kSupervisorEventArgumentPrefix[] =
    "--yixue-supervisor-event=";
constexpr char kSupervisorAppReadyEventArgumentPrefix[] =
    "--yixue-supervisor-app-ready-event=";
constexpr wchar_t kSupervisorEventNamePrefix[] =
    L"Local\\YixueApp.SupervisorClose.";
HANDLE g_single_instance_mutex = nullptr;
bool g_single_instance_mutex_owned = false;
HANDLE g_supervisor_close_event = nullptr;
HANDLE g_supervisor_app_ready_event = nullptr;
HANDLE g_supervisor_closing_event = nullptr;
HANDLE g_recovery_candidate_event = nullptr;
HANDLE g_ui_cleanup_start_event = nullptr;
std::atomic<bool>* g_ui_cleanup_watchdog_wait_failed = nullptr;
bool RecoverHiddenYixueProcesses(bool mutex_owned,
                                 HWND orphan_window = nullptr);
void ShowRecoveryBlocked(const std::wstring& details);
[[noreturn]] void TerminateHungUiCleanup() noexcept;

class UiCleanupWatchdog final {
 public:
  explicit UiCleanupWatchdog(bool enabled = true) noexcept {
    if (!enabled) return;
    try {
      state_ = std::make_shared<yixue::runner::UiCleanupWatchdogState>();
      start_event_ = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
      if (start_event_ == nullptr) {
        startup_failed_ = true;
        state_.reset();
        return;
      }
      g_ui_cleanup_start_event = start_event_;
      wait_failed_ = std::make_shared<std::atomic<bool>>(false);
      g_ui_cleanup_watchdog_wait_failed = wait_failed_.get();
      const auto state = state_;
      const auto wait_failed = wait_failed_;
      const HANDLE start_event = start_event_;
      std::thread watchdog([state, wait_failed, start_event] {
        if (::WaitForSingleObject(start_event, INFINITE) != WAIT_OBJECT_0) {
          wait_failed->store(true, std::memory_order_release);
          yixue::runner::diagnostics::Log(
              "main_cleanup_watchdog_wait_failed", ::GetLastError());
          return;
        }
        if (!state->TryStart()) return;
        constexpr DWORD kPollIntervalMs = 100;
        DWORD elapsed_ms = 0;
        while (elapsed_ms < kUiCleanupWatchdogTimeoutMs) {
          if (state->status() !=
              yixue::runner::UiCleanupWatchdogStatus::kPending) {
            return;
          }
          const DWORD interval = std::min(
              kPollIntervalMs, kUiCleanupWatchdogTimeoutMs - elapsed_ms);
          ::Sleep(interval);
          elapsed_ms += interval;
        }

        if (state->TryMarkExpired()) {
          // At this point the app has already entered its close path. Avoid a
          // second hung process holding the local database lock indefinitely;
          // active recordings retain their .partial media for recovery.
          if (!::TerminateProcess(::GetCurrentProcess(), ERROR_TIMEOUT)) {
            ::ExitProcess(ERROR_TIMEOUT);
          }
          ::ExitProcess(ERROR_TIMEOUT);
        }
      });
      watchdog_ = std::move(watchdog);
      active_ = true;
    } catch (...) {
      if (g_ui_cleanup_start_event == start_event_) {
        g_ui_cleanup_start_event = nullptr;
      }
      g_ui_cleanup_watchdog_wait_failed = nullptr;
      if (start_event_ != nullptr) {
        ::CloseHandle(start_event_);
        start_event_ = nullptr;
      }
      state_.reset();
      startup_failed_ = true;
    }
  }

  ~UiCleanupWatchdog() noexcept { ReleaseThreadAndEvent(); }

  bool startup_failed() const noexcept { return startup_failed_; }

  bool Complete() noexcept {
    if (!active_ || !state_) return true;
    state_->TryStart();
    const bool completed = state_->TryMarkCompleted() ||
                           state_->status() ==
                               yixue::runner::UiCleanupWatchdogStatus::kCompleted;
    ReleaseThreadAndEvent();
    return completed;
  }

 private:
  void ReleaseThreadAndEvent() noexcept {
    if (state_) {
      state_->TryStart();
      state_->TryMarkCompleted();
    }
    if (start_event_ != nullptr && !::SetEvent(start_event_)) {
      yixue::runner::diagnostics::Log(
          "main_cleanup_watchdog_release_signal_failed", ::GetLastError());
      TerminateHungUiCleanup();
    }
    if (watchdog_.joinable()) {
      try {
        watchdog_.join();
      } catch (...) {
        if (!::TerminateProcess(::GetCurrentProcess(), ERROR_GEN_FAILURE)) {
          ::ExitProcess(ERROR_GEN_FAILURE);
        }
        ::ExitProcess(ERROR_GEN_FAILURE);
      }
    }
    if (wait_failed_ != nullptr &&
        wait_failed_->load(std::memory_order_acquire)) {
      TerminateHungUiCleanup();
    }
    if (g_ui_cleanup_start_event == start_event_) {
      g_ui_cleanup_start_event = nullptr;
    }
    g_ui_cleanup_watchdog_wait_failed = nullptr;
    if (start_event_ != nullptr) {
      ::CloseHandle(start_event_);
      start_event_ = nullptr;
    }
    active_ = false;
  }

  std::shared_ptr<yixue::runner::UiCleanupWatchdogState> state_;
  std::shared_ptr<std::atomic<bool>> wait_failed_;
  HANDLE start_event_ = nullptr;
  std::thread watchdog_;
  bool active_ = false;
  bool startup_failed_ = false;
};

[[noreturn]] void TerminateHungUiCleanup() noexcept {
  if (!::TerminateProcess(::GetCurrentProcess(), ERROR_TIMEOUT)) {
    ::ExitProcess(ERROR_TIMEOUT);
  }
  ::ExitProcess(ERROR_TIMEOUT);
}

void CloseSingleInstanceMutex() {
  if (g_single_instance_mutex == nullptr) return;
  if (g_single_instance_mutex_owned) {
    if (!::ReleaseMutex(g_single_instance_mutex)) {
      yixue::runner::diagnostics::Log(
          "single_instance_mutex_release_failed", ::GetLastError());
    }
    g_single_instance_mutex_owned = false;
  }
  ::CloseHandle(g_single_instance_mutex);
  g_single_instance_mutex = nullptr;
}

void CloseRecoveryCandidateMarker() {
  if (g_recovery_candidate_event == nullptr) return;
  ::CloseHandle(g_recovery_candidate_event);
  g_recovery_candidate_event = nullptr;
}

bool CreateRecoveryCandidateMarker() {
  if (g_recovery_candidate_event != nullptr) return true;
  std::wstring candidate_event_name;
  try {
    candidate_event_name =
        yixue::runner::RecoveryCandidateEventName(::GetCurrentProcessId());
  } catch (...) {
    yixue::runner::diagnostics::Log(
        "hidden_instance_recovery_candidate_name_failed",
        ERROR_NOT_ENOUGH_MEMORY);
    return false;
  }
  ::SetLastError(ERROR_SUCCESS);
  g_recovery_candidate_event = ::CreateEventW(
      nullptr, TRUE, TRUE, candidate_event_name.c_str());
  const DWORD create_result = ::GetLastError();
  if (g_recovery_candidate_event != nullptr &&
      create_result != ERROR_ALREADY_EXISTS) {
    return true;
  }
  const DWORD error = g_recovery_candidate_event == nullptr
                          ? create_result
                          : ERROR_ALREADY_EXISTS;
  CloseRecoveryCandidateMarker();
  yixue::runner::diagnostics::Log(
      "hidden_instance_recovery_candidate_marker_failed", error);
  return false;
}

void CloseSupervisorAppReadyEvent() {
  if (g_supervisor_app_ready_event == nullptr) return;
  ::CloseHandle(g_supervisor_app_ready_event);
  g_supervisor_app_ready_event = nullptr;
}

void CloseSupervisorClosingEvent() {
  if (g_supervisor_closing_event == nullptr) return;
  ::CloseHandle(g_supervisor_closing_event);
  g_supervisor_closing_event = nullptr;
}

bool CreateSupervisorClosingEvent(DWORD* error) {
  if (error != nullptr) *error = ERROR_SUCCESS;
  ::SetLastError(ERROR_SUCCESS);
  g_supervisor_closing_event = ::CreateEventW(
      nullptr, TRUE, FALSE, yixue::runner::kSupervisorClosingEventName);
  const DWORD create_result = ::GetLastError();
  if (g_supervisor_closing_event == nullptr ||
      create_result == ERROR_ALREADY_EXISTS) {
    const DWORD create_error = g_supervisor_closing_event == nullptr
                                   ? create_result
                                   : ERROR_ALREADY_EXISTS;
    if (error != nullptr) *error = create_error;
    CloseSupervisorClosingEvent();
    yixue::runner::diagnostics::Log(
        "supervised_ui_create_closing_event_failed", create_error);
    return false;
  }
  yixue::runner::diagnostics::Log(
      "supervised_ui_create_closing_event_succeeded");
  return true;
}

yixue::runner::SupervisorClosingState ProbeSupervisorClosingState() {
  HANDLE event = ::OpenEventW(SYNCHRONIZE, FALSE,
                              yixue::runner::kSupervisorClosingEventName);
  if (event == nullptr) {
    return yixue::runner::ResolveSupervisorClosingProbe(
        false, ::GetLastError(), WAIT_FAILED);
  }
  const DWORD wait_result = ::WaitForSingleObject(event, 0);
  ::CloseHandle(event);
  return yixue::runner::ResolveSupervisorClosingProbe(
      true, ERROR_SUCCESS, wait_result);
}

bool ShowRunningInstance(
    yixue::runner::SingleInstanceMutexAcquireResult mutex_result) {
  HWND window = nullptr;
  // The first process creates its window shortly after acquiring the mutex.
  for (int attempt = 0; attempt < 240 && window == nullptr; ++attempt) {
    window = ::FindWindowW(kMainWindowClassName, kMainWindowTitle);
    if (window == nullptr) ::Sleep(50);
  }
  const bool window_is_hung =
      window != nullptr && ::IsHungAppWindow(window) != FALSE;
  const bool allow_hidden_recovery =
      yixue::runner::ShouldAttemptHiddenInstanceRecovery(mutex_result,
                                                        window != nullptr);
  const auto action = yixue::runner::DecideExistingInstanceAction(
      window != nullptr, window_is_hung, allow_hidden_recovery,
      g_single_instance_mutex_owned);
  if (action ==
      yixue::runner::ExistingInstanceAction::kBlockRecoveryWhileStarting) {
    const bool busy_without_window =
        window == nullptr &&
        mutex_result ==
            yixue::runner::SingleInstanceMutexAcquireResult::kBusy;
    yixue::runner::diagnostics::Log(
        busy_without_window
            ? "single_instance_busy_without_window_recovery_blocked"
            : "single_instance_startup_still_in_progress");
    ShowRecoveryBlocked(
        busy_without_window
            ? L"译学的单实例锁仍由另一个进程持有，但 Windows 暂时找不到主窗口。为避免结束仍在运行的译学或破坏媒体文件，本次不会扫描或关闭进程。请确认旧窗口已退出后再点“重新检查占用”；若任务管理器中仍有译学进程，请先确认它已结束。"
            : L"译学正在启动或恢复。为避免中断正常启动，本次没有扫描或关闭任何进程。请稍候重试。");
    return false;
  }
  if (action ==
      yixue::runner::ExistingInstanceAction::kRecoverWithoutWindow ||
      action == yixue::runner::ExistingInstanceAction::kRecoverWithWindow) {
    // A previous process can keep the single-instance mutex after its Flutter
    // window has disappeared or stopped responding. Retain a discovered HWND
    // so recovery can verify its process owner and try a graceful close first.
    if (g_recovery_candidate_event == nullptr) {
      yixue::runner::diagnostics::Log(
          "hidden_instance_recovery_blocked_candidate_marker_failed");
      ShowRecoveryBlocked(
          L"Windows \u65e0\u6cd5\u5b89\u5168\u6807\u8bb0\u8fd9\u6b21\u6062\u590d\u8bf7\u6c42\uff0c\u4e3a\u907f\u514d\u7ed3\u675f\u6b63\u5728\u542f\u52a8\u7684\u8bd1\u5b66\uff0c\u672a\u626b\u63cf\u6216\u5173\u95ed\u4efb\u4f55\u8fdb\u7a0b\u3002");
      return false;
    }
    return RecoverHiddenYixueProcesses(
        g_single_instance_mutex_owned,
        action == yixue::runner::ExistingInstanceAction::kRecoverWithWindow
            ? window
            : nullptr);
  }

  ::ShowWindow(window, ::IsIconic(window) ? SW_RESTORE : SW_SHOW);
  if (!::PostMessageW(window, yixue::runner::kRestoreMainWindowMessage, 0,
                      0)) {
    yixue::runner::diagnostics::Log(
        "single_instance_restore_request_post_failed", ::GetLastError());
  }
  if (::GetForegroundWindow() != window && !::SetForegroundWindow(window)) {
    ::FlashWindow(window, TRUE);
    ::MessageBoxW(
        nullptr,
        L"\u8BD1\u5B66\u5DF2\u5728\u8FD0\u884C\u3002Windows \u6682\u65F6\u963B\u6B62\u4E86\u81EA\u52A8\u5207\u6362\u7A97\u53E3\uFF0C\u8BF7\u4ECE\u4EFB\u52A1\u680F\u9009\u62E9\u8BD1\u5B66\u7A97\u53E3\u3002",
        L"\u8BD1\u5B66\u5DF2\u5728\u8FD0\u884C", MB_OK | MB_ICONINFORMATION);
  }
  return false;
}

struct BackgroundYixueProcess {
  DWORD process_id;
  HANDLE handle;
  std::wstring image_path;
};

void CloseBackgroundProcessHandles(
    std::vector<BackgroundYixueProcess>* processes) {
  for (auto& process : *processes) {
    if (process.handle != nullptr) {
      ::CloseHandle(process.handle);
      process.handle = nullptr;
    }
  }
}

std::wstring FormatProcessIds(
    const std::vector<BackgroundYixueProcess>& processes) {
  std::wstring result;
  for (const auto& process : processes) {
    result += L"\n  PID " + std::to_wstring(process.process_id) + L"  " +
              process.image_path;
  }
  return result;
}

void ShowRecoveryBlocked(const std::wstring& details) {
  const std::wstring message =
      details +
      L"\n\n\u4E3A\u4FDD\u62A4\u672C\u5730\u8D44\u6599\u5E93\uFF0C\u5DF2\u53D6\u6D88\u672C\u6B21\u542F\u52A8\u3002\n\u8BF7\u5173\u95ED\u786E\u8BA4\u5361\u4F4F\u7684\u65E7\u8BD1\u5B66\u8FDB\u7A0B\u540E\u518D\u542F\u52A8\uFF1B\u5982\u65E0\u6CD5\u786E\u8BA4\u5176\u5DF2\u9000\u51FA\uFF0C\u8BF7\u91CD\u542F Windows \u540E\u518D\u8BD5\u3002";
  ::MessageBoxW(nullptr, message.c_str(), L"\u6062\u590D\u8BD1\u5B66",
                MB_OK | MB_ICONWARNING);
}

enum class BackgroundProcessWaitOutcome {
  kAllExited,
  kTimedOut,
  kFailed,
};

BackgroundProcessWaitOutcome WaitForBackgroundProcessesToExit(
    const std::vector<BackgroundYixueProcess>& processes, DWORD timeout_ms) {
  const ULONGLONG started_at = ::GetTickCount64();
  for (const auto& process : processes) {
    const ULONGLONG elapsed = ::GetTickCount64() - started_at;
    const DWORD remaining = elapsed >= timeout_ms
                                ? 0
                                : timeout_ms - static_cast<DWORD>(elapsed);
    const DWORD wait_result = ::WaitForSingleObject(process.handle, remaining);
    if (wait_result == WAIT_OBJECT_0) continue;
    if (wait_result == WAIT_TIMEOUT)
      return BackgroundProcessWaitOutcome::kTimedOut;
    yixue::runner::diagnostics::Log(
        "hidden_instance_process_exit_wait_failed", ::GetLastError());
    return BackgroundProcessWaitOutcome::kFailed;
  }
  return BackgroundProcessWaitOutcome::kAllExited;
}

bool IsWindowOwnedByTrackedProcess(
    HWND window, const std::vector<BackgroundYixueProcess>& processes,
    DWORD* process_id) {
  if (process_id != nullptr) *process_id = 0;
  if (window == nullptr || !::IsWindow(window)) return false;
  DWORD owner_process_id = 0;
  if (::GetWindowThreadProcessId(window, &owner_process_id) == 0 ||
      owner_process_id == 0) {
    return false;
  }
  for (const auto& process : processes) {
    if (process.process_id != owner_process_id) continue;
    if (::WaitForSingleObject(process.handle, 0) != WAIT_TIMEOUT) return false;
    if (process_id != nullptr) *process_id = owner_process_id;
    return true;
  }
  return false;
}

bool RecoverHiddenYixueProcesses(bool mutex_owned, HWND orphan_window) {
  yixue::runner::diagnostics::Log("hidden_instance_recovery_start");
  yixue::runner::InstanceRecoveryGate recovery_gate(
      kInstanceRecoveryMutexName);
  if (!recovery_gate.acquired()) {
    const DWORD error = recovery_gate.error();
    yixue::runner::diagnostics::Log(
        error == ERROR_ALREADY_EXISTS
            ? "hidden_instance_recovery_blocked_gate_busy"
            : "hidden_instance_recovery_blocked_gate_failed",
        error);
    ShowRecoveryBlocked(
        error == ERROR_ALREADY_EXISTS
            ? L"\u53e6\u4e00\u4e2a\u8bd1\u5b66\u542f\u52a8\u5668\u6b63\u5728\u6062\u590d\u65e7\u8fdb\u7a0b\u3002\u8bf7\u7b49\u5f85\u5f53\u524d\u64cd\u4f5c\u7ed3\u675f\u540e\u518d\u91cd\u8bd5\uff1b\u672c\u6b21\u6ca1\u6709\u626b\u63cf\u6216\u5173\u95ed\u4efb\u4f55\u8fdb\u7a0b\u3002"
            : L"\u65e0\u6cd5\u786e\u4fdd\u8bd1\u5b66\u6062\u590d\u64cd\u4f5c\u7684\u4e92\u65a5\u4fdd\u62a4\uff08Windows \u9519\u8bef " +
                  std::to_wstring(error) +
                  L"\uff09\u3002\u4e3a\u4fdd\u62a4\u5df2\u6253\u5f00\u7684\u8fdb\u7a0b\uff0c\u672a\u626b\u63cf\u6216\u5173\u95ed\u4efb\u4f55\u8fdb\u7a0b\u3002");
    return false;
  }
  std::vector<wchar_t> executable_path(32768, L'\0');
  const DWORD path_length = ::GetModuleFileNameW(
      nullptr, executable_path.data(),
      static_cast<DWORD>(executable_path.size()));
  if (path_length == 0 || path_length >= executable_path.size()) {
    const DWORD error = ::GetLastError();
    yixue::runner::diagnostics::Log(
        "hidden_instance_executable_path_failed", error);
    ShowRecoveryBlocked(
        L"\u65E0\u6CD5\u83B7\u53D6\u8BD1\u5B66\u7A0B\u5E8F\u8DEF\u5F84\uFF0C\u56E0\u6B64\u65E0\u6CD5\u786E\u8BA4\u65E7\u5B9E\u4F8B\u3002");
    return false;
  }
  const std::wstring full_path(executable_path.data(), path_length);
  const size_t name_start = full_path.find_last_of(L"\\/");
  const std::wstring executable_name =
      name_start == std::wstring::npos ? full_path
                                       : full_path.substr(name_start + 1);

  DWORD current_session_id = 0;
  if (!::ProcessIdToSessionId(::GetCurrentProcessId(), &current_session_id)) {
    const DWORD error = ::GetLastError();
    yixue::runner::diagnostics::Log("hidden_instance_session_query_failed",
                                    error);
    ShowRecoveryBlocked(
        L"\u65E0\u6CD5\u8BFB\u53D6 Windows \u7528\u6237\u4F1A\u8BDD\uFF0C\u56E0\u6B64\u65E0\u6CD5\u5B89\u5168\u68C0\u67E5\u65E7\u5B9E\u4F8B\u3002");
    return false;
  }

  HANDLE snapshot = ::CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    const DWORD error = ::GetLastError();
    yixue::runner::diagnostics::Log("hidden_instance_snapshot_failed", error);
    ShowRecoveryBlocked(
        L"Windows \u65E0\u6CD5\u679A\u4E3E\u5F53\u524D\u8FDB\u7A0B\uFF0C\u56E0\u6B64\u65E0\u6CD5\u5B89\u5168\u68C0\u67E5\u65E7\u5B9E\u4F8B\u3002");
    return false;
  }

  std::vector<BackgroundYixueProcess> processes;
  std::vector<DWORD> inaccessible_process_ids;
  std::vector<DWORD> startup_candidate_process_ids;
  std::vector<DWORD> uncertain_candidate_process_ids;
  PROCESSENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  const BOOL first_process_found = ::Process32FirstW(snapshot, &entry);
  DWORD enumeration_end_error = first_process_found ? ERROR_SUCCESS
                                                     : ::GetLastError();
  if (first_process_found) {
    do {
      // Keep all per-entry continues inside this single iteration so
      // Process32NextW is still called for every snapshot entry.
      do {
        if (entry.th32ProcessID == ::GetCurrentProcessId() ||
            ::CompareStringOrdinal(entry.szExeFile, -1,
                                   executable_name.c_str(), -1, TRUE) !=
                CSTR_EQUAL) {
          continue;
        }
        const auto candidate_state =
            yixue::runner::ProbeRecoveryCandidateProcess(entry.th32ProcessID);
        if (candidate_state ==
            yixue::runner::RecoveryCandidateMarkerState::kPresent) {
          startup_candidate_process_ids.push_back(entry.th32ProcessID);
          yixue::runner::diagnostics::Log(
              "hidden_instance_recovery_skipped_startup_candidate",
              entry.th32ProcessID);
          continue;
        }
        if (candidate_state ==
            yixue::runner::RecoveryCandidateMarkerState::kUnknown) {
          uncertain_candidate_process_ids.push_back(entry.th32ProcessID);
          yixue::runner::diagnostics::Log(
              "hidden_instance_recovery_candidate_marker_unknown",
              entry.th32ProcessID);
          continue;
        }
        DWORD process_session_id = 0;
        if (!::ProcessIdToSessionId(entry.th32ProcessID,
                                    &process_session_id)) {
          const DWORD error = ::GetLastError();
          if (error != ERROR_INVALID_PARAMETER) {
            inaccessible_process_ids.push_back(entry.th32ProcessID);
            yixue::runner::diagnostics::Log(
                "hidden_instance_session_query_process_failed", error);
          }
          continue;
        }
        if (process_session_id != current_session_id) {
          continue;
        }

        HANDLE process = ::OpenProcess(
            PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
            FALSE, entry.th32ProcessID);
        if (process == nullptr) {
          if (::GetLastError() != ERROR_INVALID_PARAMETER) {
            inaccessible_process_ids.push_back(entry.th32ProcessID);
            yixue::runner::diagnostics::Log(
                "hidden_instance_process_not_accessible",
                entry.th32ProcessID);
          }
          continue;
        }

        // Revalidate after opening the process handle. The process may have
        // exited and its PID may have been reused since the snapshot was made.
        std::vector<wchar_t> process_path(32768, L'\0');
        DWORD process_path_length = static_cast<DWORD>(process_path.size());
        DWORD verified_session_id = 0;
        if (!::QueryFullProcessImageNameW(process, 0, process_path.data(),
                                          &process_path_length) ||
            process_path_length >= process_path.size()) {
          const DWORD process_wait = ::WaitForSingleObject(process, 0);
          if (process_wait != WAIT_OBJECT_0) {
            inaccessible_process_ids.push_back(entry.th32ProcessID);
          }
          ::CloseHandle(process);
          continue;
        }
        const std::wstring opened_path(process_path.data(), process_path_length);
        if (!yixue::runner::IsSameYixueProcessFamilyPath(opened_path,
                                                         full_path)) {
          ::CloseHandle(process);
          continue;
        }
        if (!::ProcessIdToSessionId(entry.th32ProcessID,
                                    &verified_session_id)) {
          const DWORD error = ::GetLastError();
          if (::WaitForSingleObject(process, 0) != WAIT_OBJECT_0) {
            inaccessible_process_ids.push_back(entry.th32ProcessID);
            yixue::runner::diagnostics::Log(
                "hidden_instance_verified_session_query_failed", error);
          }
          ::CloseHandle(process);
          continue;
        }
        if (verified_session_id != current_session_id) {
          ::CloseHandle(process);
          continue;
        }
        const DWORD process_wait = ::WaitForSingleObject(process, 0);
        if (process_wait == WAIT_TIMEOUT) {
          yixue::runner::diagnostics::Log("hidden_instance_process_found",
                                          entry.th32ProcessID);
          processes.push_back({entry.th32ProcessID, process, opened_path});
        } else {
          if (process_wait != WAIT_OBJECT_0) {
            inaccessible_process_ids.push_back(entry.th32ProcessID);
            yixue::runner::diagnostics::Log(
                "hidden_instance_process_state_unknown", ::GetLastError());
          }
          ::CloseHandle(process);
        }
      } while (false);
      const BOOL next_process_found = ::Process32NextW(snapshot, &entry);
      if (!next_process_found) {
        enumeration_end_error = ::GetLastError();
        break;
      }
    } while (true);
  }
  ::CloseHandle(snapshot);

  if (!yixue::runner::IsProcessEnumerationComplete(
          first_process_found != FALSE, enumeration_end_error)) {
    CloseBackgroundProcessHandles(&processes);
    yixue::runner::diagnostics::Log(
        "hidden_instance_recovery_blocked_incomplete_process_enumeration",
        enumeration_end_error);
    ShowRecoveryBlocked(
        L"Windows 未能完整枚举当前进程。为避免遗漏正在启动或关闭的译学进程，本次没有关闭任何进程，请稍后重试。");
    return false;
  }

  if (yixue::runner::ShouldAbortRecoveryForStartupCandidate(
          startup_candidate_process_ids.size())) {
    CloseBackgroundProcessHandles(&processes);
    yixue::runner::diagnostics::Log(
        "hidden_instance_recovery_blocked_startup_in_progress",
        static_cast<DWORD>(startup_candidate_process_ids.size()));
    ShowRecoveryBlocked(
        L"译学正在启动或另一个启动器正在恢复。请稍等片刻后重试；本次未扫描或关闭这些受保护的进程。");
    return false;
  }

  if (!uncertain_candidate_process_ids.empty()) {
    CloseBackgroundProcessHandles(&processes);
    yixue::runner::diagnostics::Log(
        "hidden_instance_recovery_blocked_candidate_marker_unknown",
        static_cast<DWORD>(uncertain_candidate_process_ids.size()));
    ShowRecoveryBlocked(
        L"Windows 无法确认以下进程是否正处于启动交接阶段。为避免中断新实例，本次没有关闭任何进程，请稍后重试。");
    return false;
  }

  if (!inaccessible_process_ids.empty()) {
    CloseBackgroundProcessHandles(&processes);
    std::wstring details =
        L"Windows \u4E0D\u5141\u8BB8\u8BD1\u5B66\u5B89\u5168\u68C0\u67E5\u6216\u5173\u95ED\u4EE5\u4E0B\u540E\u53F0\u8FDB\u7A0B\uFF1B\u672A\u7ED3\u675F\u4EFB\u4F55\u8FDB\u7A0B\u3002\nPID\uFF1A";
    for (const DWORD process_id : inaccessible_process_ids) {
      details += L" " + std::to_wstring(process_id);
    }
    yixue::runner::diagnostics::Log(
        "hidden_instance_recovery_blocked_inaccessible",
        static_cast<DWORD>(inaccessible_process_ids.size()));
    ShowRecoveryBlocked(details);
    return yixue::runner::ShouldContinueAfterInstanceRecovery(
        yixue::runner::InstanceRecoveryOutcome::
            kSomeProcessesNotAccessible);
  }

  if (processes.empty()) {
    if (mutex_owned) {
      // WAIT_ABANDONED means this launcher now owns the mutex. If the old
      // supervisor has already exited and left no matching process behind,
      // there is nothing to terminate and it is safe to start under this
      // lease.
      yixue::runner::diagnostics::Log(
          "hidden_instance_recovery_no_old_process_mutex_owned");
      return yixue::runner::ShouldContinueAfterNoOldInstance(mutex_owned);
    }
    yixue::runner::diagnostics::Log(
        "hidden_instance_recovery_blocked_no_process");
    ShowRecoveryBlocked(
        L"\u672A\u627E\u5230\u53EF\u663E\u793A\u7684\u65E7\u7A97\u53E3\u6216\u53EF\u5B89\u5168\u5173\u95ED\u7684\u65E7\u8FDB\u7A0B\u3002");
    return yixue::runner::ShouldContinueAfterInstanceRecovery(
        yixue::runner::InstanceRecoveryOutcome::kNoOldProcessFound);
  }

  const auto closing_state = ProbeSupervisorClosingState();
  if (closing_state == yixue::runner::SupervisorClosingState::kSignaled) {
    yixue::runner::diagnostics::Log(
        "hidden_instance_recovery_waiting_for_normal_close");
    const auto close_wait = WaitForBackgroundProcessesToExit(
        processes, yixue::runner::kChildShutdownGracePeriodMs);
    if (close_wait == BackgroundProcessWaitOutcome::kAllExited) {
      CloseBackgroundProcessHandles(&processes);
      yixue::runner::diagnostics::Log(
          "hidden_instance_recovery_normal_close_completed");
      return true;
    }
    CloseBackgroundProcessHandles(&processes);
    ShowRecoveryBlocked(
        close_wait == BackgroundProcessWaitOutcome::kTimedOut
            ? L"译学已进入正常关闭和媒体收尾阶段。为保护录音、录屏及资料库，本次不会强制结束它；请等待关闭完成后重试。"
            : L"Windows 无法确认旧进程是否已退出。为保护录音、录屏及资料库，本次不会结束任何进程。");
    return false;
  }
  if (closing_state !=
      yixue::runner::SupervisorClosingState::kNotSignaled) {
    CloseBackgroundProcessHandles(&processes);
    yixue::runner::diagnostics::Log(
        "hidden_instance_recovery_blocked_closing_state_unknown");
    ShowRecoveryBlocked(
        L"Windows 无法确认旧译学进程是否正在正常关闭。为保护尚未保存的媒体文件，本次没有结束任何进程。");
    return false;
  }

  DWORD orphan_window_process_id = 0;
  if (orphan_window != nullptr &&
      !IsWindowOwnedByTrackedProcess(orphan_window, processes,
                                     &orphan_window_process_id)) {
    CloseBackgroundProcessHandles(&processes);
    yixue::runner::diagnostics::Log(
        "hidden_instance_recovery_blocked_window_owner_unverified");
    ShowRecoveryBlocked(
        L"检测到译学窗口，但无法把窗口与已验证的译学进程对应。为保护当前窗口，本次没有发送关闭消息或结束进程。");
    return false;
  }

  if (orphan_window != nullptr) {
    const std::wstring graceful_message =
        (mutex_owned
             ? L"译学主窗口仍在，但原来的监督进程已不再持有单实例锁。是否先向已验证的译学窗口发送正常关闭请求？\n\n译学会有最多 60 秒完成录音、录屏和资料保存；等待后仍未退出时，才会单独询问是否强制结束。"
             : L"检测到译学主窗口没有响应。是否先向已验证的译学窗口发送正常关闭请求？\n\n译学会有最多 60 秒完成录音、录屏和资料保存；等待后仍未退出时，才会单独询问是否强制结束。") +
        FormatProcessIds(processes);
    const int graceful_choice = ::MessageBoxW(
        nullptr, graceful_message.c_str(), L"恢复译学",
        MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2);
    if (graceful_choice != IDYES) {
      ::ShowWindow(orphan_window,
                   ::IsIconic(orphan_window) ? SW_RESTORE : SW_SHOW);
      ::SetForegroundWindow(orphan_window);
      CloseBackgroundProcessHandles(&processes);
      yixue::runner::diagnostics::Log(
          "hidden_instance_graceful_close_cancelled_by_user",
          orphan_window_process_id);
      return false;
    }
    DWORD current_window_process_id = 0;
    if (!IsWindowOwnedByTrackedProcess(orphan_window, processes,
                                       &current_window_process_id) ||
        current_window_process_id != orphan_window_process_id ||
        ProbeSupervisorClosingState() !=
            yixue::runner::SupervisorClosingState::kNotSignaled ||
        !::PostMessageW(orphan_window, WM_CLOSE, 0, 0)) {
      const DWORD error = ::GetLastError();
      CloseBackgroundProcessHandles(&processes);
      yixue::runner::diagnostics::Log(
          "hidden_instance_verified_wm_close_failed", error);
      ShowRecoveryBlocked(
          L"无法再次确认旧窗口身份或发送正常关闭请求。为保护该窗口，本次没有强制结束任何进程。");
      return false;
    }
    yixue::runner::diagnostics::Log(
        "hidden_instance_verified_wm_close_posted",
        orphan_window_process_id);
    const auto close_wait = WaitForBackgroundProcessesToExit(
        processes, yixue::runner::kChildShutdownGracePeriodMs);
    if (close_wait == BackgroundProcessWaitOutcome::kAllExited) {
      CloseBackgroundProcessHandles(&processes);
      yixue::runner::diagnostics::Log(
          "hidden_instance_graceful_close_completed");
      return true;
    }
    if (close_wait == BackgroundProcessWaitOutcome::kFailed) {
      CloseBackgroundProcessHandles(&processes);
      ShowRecoveryBlocked(
          L"Windows 无法确认旧进程是否仍在运行。为保护媒体文件，本次不会强制结束任何进程。");
      return false;
    }
    const auto post_close_state = ProbeSupervisorClosingState();
    if (!yixue::runner::CanForceTerminateAfterCloseRequest(
            post_close_state)) {
      CloseBackgroundProcessHandles(&processes);
      yixue::runner::diagnostics::Log(
          "hidden_instance_force_recovery_blocked_close_started");
      ShowRecoveryBlocked(
          post_close_state ==
                  yixue::runner::SupervisorClosingState::kSignaled
              ? L"译学已经开始正常收尾，但录音或录屏尚未完成。为避免损坏文件，本次不会强制结束；请继续等待后重试。"
              : L"Windows 无法确认译学的关闭状态。为保护媒体文件，本次不会强制结束任何进程。");
      return false;
    }
  }

  const std::wstring process_ids = FormatProcessIds(processes);
  const std::wstring message =
      std::wstring(orphan_window == nullptr
                       ? L"\u65E0\u6CD5\u5B9A\u4F4D\u8BD1\u5B66\u4E3B\u7A97\u53E3\uFF0C\u4F46\u68C0\u6D4B\u5230\u8BD1\u5B66\u8FDB\u7A0B\u4ECD\u5728\u8FD0\u884C\u3002"
                       : L"\u5DF2\u5411\u8BD1\u5B66\u53D1\u9001\u6B63\u5E38\u5173\u95ED\u8BF7\u6C42\uFF0C\u4F46\u7A0B\u5E8F\u4ECD\u5728\u8FD0\u884C\u3002") +
      L"\nPID\uFF1A" + process_ids +
      L"\n\n\u662F\u5426\u5F3A\u5236\u7ED3\u675F\u8FD9\u4E9B\u8FDB\u7A0B\u5E76\u7EE7\u7EED\u6253\u5F00\uFF1F\n\u5C1A\u672A\u4FDD\u5B58\u7684\u5F55\u97F3\u6216\u5F55\u5C4F\u53EF\u80FD\u635F\u574F\u3002";
  const int choice = ::MessageBoxW(
      nullptr, message.c_str(), L"\u6062\u590D\u8BD1\u5B66",
      MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2);
  if (choice != IDYES) {
    yixue::runner::diagnostics::Log(
        "hidden_instance_recovery_cancelled_by_user");
    if (orphan_window != nullptr && ::IsWindow(orphan_window)) {
      ::ShowWindow(orphan_window,
                   ::IsIconic(orphan_window) ? SW_RESTORE : SW_SHOW);
      ::SetForegroundWindow(orphan_window);
    }
    CloseBackgroundProcessHandles(&processes);
    return false;
  }

  std::vector<DWORD> failed_process_ids;
  for (const auto& process : processes) {
    const DWORD process_state = ::WaitForSingleObject(process.handle, 0);
    if (process_state == WAIT_OBJECT_0) continue;
    if (process_state != WAIT_TIMEOUT) {
      yixue::runner::diagnostics::Log(
          "hidden_instance_terminate_skipped_process_state_unknown",
          process.process_id);
      failed_process_ids.push_back(process.process_id);
      continue;
    }
    // The close marker is permanent for the lifetime of the old UI process.
    // Recheck immediately before each destructive operation so a process that
    // entered normal teardown while a confirmation dialog was open is never
    // force-terminated by this recovery path.
    const auto current_closing_state = ProbeSupervisorClosingState();
    const auto current_candidate_state =
        yixue::runner::ProbeRecoveryCandidateProcess(process.process_id);
    if (!yixue::runner::CanForceTerminateAfterCloseRequest(
            current_closing_state) ||
        current_candidate_state !=
            yixue::runner::RecoveryCandidateMarkerState::kAbsent) {
      yixue::runner::diagnostics::Log(
          "hidden_instance_terminate_skipped_state_changed",
          process.process_id);
      failed_process_ids.push_back(process.process_id);
      continue;
    }
    yixue::runner::diagnostics::Log(
        "hidden_instance_terminate_requested", process.process_id);
    if (!::TerminateProcess(process.handle, ERROR_CANCELLED)) {
      const DWORD terminate_error = ::GetLastError();
      const auto wait_outcome = yixue::runner::WaitAfterTerminateFailure(
          [&process](DWORD timeout_ms) {
            return ::WaitForSingleObject(process.handle, timeout_ms);
          });
      if (wait_outcome !=
          yixue::runner::TerminateFailureWaitOutcome::kProcessExited) {
        yixue::runner::diagnostics::Log("hidden_instance_terminate_error",
                                        terminate_error);
        yixue::runner::diagnostics::Log("hidden_instance_terminate_failed",
                                        process.process_id);
        if (wait_outcome ==
            yixue::runner::TerminateFailureWaitOutcome::kWaitFailed) {
          yixue::runner::diagnostics::Log("hidden_instance_stop_wait_failed",
                                          process.process_id);
        } else {
          yixue::runner::diagnostics::Log(
              "hidden_instance_stop_wait_timed_out", process.process_id);
        }
        failed_process_ids.push_back(process.process_id);
        continue;
      }
    } else if (::WaitForSingleObject(
                   process.handle,
                   yixue::runner::kChildTerminationWaitMs) != WAIT_OBJECT_0) {
      yixue::runner::diagnostics::Log(
          "hidden_instance_stop_wait_timed_out", process.process_id);
      failed_process_ids.push_back(process.process_id);
      continue;
    }
    yixue::runner::diagnostics::Log("hidden_instance_process_stopped",
                                    process.process_id);
  }
  CloseBackgroundProcessHandles(&processes);

  if (!failed_process_ids.empty()) {
    std::wstring failure_message =
        L"\u65E0\u6CD5\u5173\u95ED\u4EE5\u4E0B\u8BD1\u5B66\u8FDB\u7A0B\uFF1A";
    for (const DWORD process_id : failed_process_ids) {
      failure_message += L" " + std::to_wstring(process_id);
    }
    failure_message +=
        L"\n\n\u672A\u7ED3\u675F\u7684\u8FDB\u7A0B\u53EF\u80FD\u4ECD\u5360\u7528\u97F3\u9891\u8BBE\u5907\u6216\u8D44\u6599\u5E93\u3002";
    yixue::runner::diagnostics::Log(
        "hidden_instance_recovery_blocked_stop_failed",
        static_cast<DWORD>(failed_process_ids.size()));
    ShowRecoveryBlocked(failure_message);
    return yixue::runner::ShouldContinueAfterInstanceRecovery(
        yixue::runner::InstanceRecoveryOutcome::
            kSomeProcessesStillRunning);
  }

  yixue::runner::diagnostics::Log("hidden_instance_recovery_complete",
                                  static_cast<DWORD>(processes.size()));
  return yixue::runner::ShouldContinueAfterInstanceRecovery(
      yixue::runner::InstanceRecoveryOutcome::kAllOldProcessesStopped);
}

bool AcquireSingleInstance() {
  // Publish a candidate before claiming the mutex so a recovery scan from an
  // older launcher can still protect this process during the handoff.
  if (!CreateRecoveryCandidateMarker()) {
    ShowRecoveryBlocked(
        L"Windows 无法保护这次启动不被其他启动器误判。为保护已存在的进程，未启动译学。");
    return false;
  }
  ::SetLastError(ERROR_SUCCESS);
  g_single_instance_mutex = ::CreateMutexW(
      nullptr, TRUE, kSingleInstanceMutexName);
  if (g_single_instance_mutex == nullptr) {
    const DWORD error = ::GetLastError();
    CloseRecoveryCandidateMarker();
    wchar_t message[160];
    ::swprintf_s(
        message, _countof(message),
        L"\u65E0\u6CD5\u68C0\u67E5\u8BD1\u5B66\u662F\u5426\u5DF2\u8FD0\u884C\uFF08Windows \u9519\u8BEF %lu\uFF09\u3002\n\n\u4E3A\u4FDD\u62A4\u672C\u5730\u6570\u636E\uFF0C\u7A0B\u5E8F\u5C06\u9000\u51FA\u3002",
        error);
    ::MessageBoxW(nullptr, message,
                  L"\u8BD1\u5B66\u65E0\u6CD5\u542F\u52A8", MB_OK | MB_ICONERROR);
    return false;
  }
  const bool mutex_already_existed = ::GetLastError() == ERROR_ALREADY_EXISTS;
  if (!mutex_already_existed) {
    // CreateMutexW(TRUE) atomically gives the first launcher ownership before
    // it creates the supervisor or UI child.
    g_single_instance_mutex_owned = true;
    yixue::runner::diagnostics::Log(
        "single_instance_mutex_created_and_owned");
    return true;
  }

  DWORD acquire_error = ERROR_SUCCESS;
  const auto acquire_result = yixue::runner::TryAcquireSingleInstanceMutex(
      g_single_instance_mutex, &acquire_error);
  if (acquire_result ==
      yixue::runner::SingleInstanceMutexAcquireResult::kFailed) {
    yixue::runner::diagnostics::Log(
        "single_instance_mutex_acquire_failed", acquire_error);
    ShowRecoveryBlocked(
        L"Windows 无法安全确认译学是否正在启动。为保护已打开的进程，本次未扫描或关闭任何进程。");
    CloseRecoveryCandidateMarker();
    CloseSingleInstanceMutex();
    return false;
  }

  g_single_instance_mutex_owned =
      yixue::runner::OwnsSingleInstanceMutex(acquire_result);
  yixue::runner::diagnostics::Log(
      g_single_instance_mutex_owned
          ? "single_instance_mutex_existing_unowned_acquired"
          : "single_instance_mutex_owned_by_startup_thread");

  const bool should_continue_startup = ShowRunningInstance(acquire_result);
  if (should_continue_startup) {
    if (!g_single_instance_mutex_owned) {
      // The user approved recovery while the previous supervisor still owned
      // the mutex. Its termination abandons that mutex; take ownership before
      // creating a new supervisor so a racing launcher cannot start a second
      // UI process.
      DWORD reacquire_error = ERROR_SUCCESS;
      auto reacquire_result =
          yixue::runner::SingleInstanceMutexAcquireResult::kBusy;
      const ULONGLONG reacquire_deadline =
          ::GetTickCount64() + yixue::runner::kChildTerminationWaitMs;
      do {
        reacquire_result = yixue::runner::TryAcquireSingleInstanceMutex(
            g_single_instance_mutex, &reacquire_error);
        if (yixue::runner::OwnsSingleInstanceMutex(reacquire_result) ||
            reacquire_result ==
                yixue::runner::SingleInstanceMutexAcquireResult::kFailed) {
          break;
        }
        ::Sleep(50);
      } while (::GetTickCount64() < reacquire_deadline);
      if (!yixue::runner::OwnsSingleInstanceMutex(reacquire_result)) {
        yixue::runner::diagnostics::Log(
            "single_instance_mutex_reacquire_after_recovery_failed",
            reacquire_error == ERROR_SUCCESS ? ERROR_TIMEOUT
                                             : reacquire_error);
        ShowRecoveryBlocked(
            L"旧译学进程已结束，但 Windows 仍未把单实例控制权交给本次启动。为避免打开多个实例，本次启动已取消；请稍候后重试。");
        CloseRecoveryCandidateMarker();
        CloseSingleInstanceMutex();
        return false;
      }
      g_single_instance_mutex_owned = true;
      yixue::runner::diagnostics::Log(
          "single_instance_mutex_reacquired_after_hidden_recovery");
    }
    // Keep the mutex lease through supervisor creation and UI window readiness.
    return true;
  }
  CloseRecoveryCandidateMarker();
  CloseSingleInstanceMutex();
  return false;
}

bool ConvertUtf8ToWide(const std::string& value, std::wstring* result) {
  if (result == nullptr) return false;
  result->clear();
  if (value.empty()) return true;
  const int size = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) return false;
  result->resize(static_cast<size_t>(size));
  return ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                               static_cast<int>(value.size()), result->data(),
                               size) == size;
}

std::wstring QuoteWindowsArgument(const std::wstring& argument) {
  std::wstring quoted;
  quoted.push_back(L'"');
  size_t backslashes = 0;
  for (const wchar_t character : argument) {
    if (character == L'\\') {
      ++backslashes;
      continue;
    }
    if (character == L'"') {
      quoted.append(backslashes * 2 + 1, L'\\');
      quoted.push_back(L'"');
      backslashes = 0;
      continue;
    }
    quoted.append(backslashes, L'\\');
    backslashes = 0;
    quoted.push_back(character);
  }
  quoted.append(backslashes * 2, L'\\');
  quoted.push_back(L'"');
  return quoted;
}

void ShowSupervisorError(const wchar_t* operation, DWORD error) {
  wchar_t message[320] = {};
  ::swprintf_s(
      message, _countof(message),
      L"\u8BD1\u5B66\u65E0\u6CD5\u5B89\u5168\u542F\u52A8\u53D7\u76D1\u7763\u5B9E\u4F8B\u3002\n\n%s\nWindows \u9519\u8BEF\u4EE3\u7801\uFF1A%lu",
      operation, error);
  ::MessageBoxW(nullptr, message, L"\u8BD1\u5B66\u542F\u52A8\u5931\u8D25",
                MB_OK | MB_ICONERROR);
}

struct SupervisorNoticePayload final {
  std::wstring message;
  std::wstring title;
};

unsigned int __stdcall ShowSupervisorNoticeThread(void* context) {
  std::unique_ptr<SupervisorNoticePayload> notice(
      static_cast<SupervisorNoticePayload*>(context));
  if (!notice) return 1;
  ::MessageBoxW(nullptr, notice->message.c_str(), notice->title.c_str(),
                MB_OK | MB_ICONWARNING | MB_TOPMOST | MB_SETFOREGROUND);
  return 0;
}

void ShowSupervisorNoticeWithoutBlockingRetries(const wchar_t* message,
                                               const wchar_t* title) noexcept {
  SupervisorNoticePayload* payload = nullptr;
  try {
    payload = new (std::nothrow) SupervisorNoticePayload{message, title};
  } catch (...) {
    payload = nullptr;
  }
  if (payload == nullptr) {
    yixue::runner::diagnostics::Log(
        "supervisor_retry_notice_allocation_failed", ERROR_NOT_ENOUGH_MEMORY);
    return;
  }
  const uintptr_t thread = ::_beginthreadex(
      nullptr, 0, &ShowSupervisorNoticeThread, payload, 0, nullptr);
  if (thread == 0) {
    delete payload;
    yixue::runner::diagnostics::Log(
        "supervisor_retry_notice_thread_failed", ERROR_NOT_ENOUGH_MEMORY);
    return;
  }
  if (!::CloseHandle(reinterpret_cast<HANDLE>(thread))) {
    yixue::runner::diagnostics::Log(
        "supervisor_retry_notice_handle_close_failed", ::GetLastError());
  }
}

bool IsProcessSignaled(HANDLE process, DWORD* error) {
  const DWORD wait_result = ::WaitForSingleObject(process, 0);
  if (wait_result == WAIT_OBJECT_0) return true;
  if (wait_result == WAIT_TIMEOUT) return false;
  if (error != nullptr) {
    *error = wait_result == WAIT_FAILED ? ::GetLastError()
                                        : ERROR_GEN_FAILURE;
  }
  return false;
}

void TerminateUnassignedChild(HANDLE process, DWORD exit_code,
                              DWORD* error) {
  if (process == nullptr || process == INVALID_HANDLE_VALUE) {
    if (error != nullptr) *error = ERROR_INVALID_HANDLE;
    yixue::runner::diagnostics::Log(
        "supervisor_unassigned_child_confirmation_unavailable",
        ERROR_INVALID_HANDLE);
    for (;;) ::Sleep(1000);
  }

  ULONGLONG next_log_at = ::GetTickCount64();
  ULONGLONG waiting_since = next_log_at;
  bool waiting_warning_shown = false;
  for (;;) {
    DWORD wait_error = ERROR_SUCCESS;
    if (IsProcessSignaled(process, &wait_error)) return;

    const DWORD terminate_error = ::TerminateProcess(process, exit_code)
                                      ? ERROR_SUCCESS
                                      : ::GetLastError();
    if (terminate_error != ERROR_SUCCESS) {
      DWORD after_terminate_error = ERROR_SUCCESS;
      if (IsProcessSignaled(process, &after_terminate_error)) return;
      if (after_terminate_error != ERROR_SUCCESS) {
        wait_error = after_terminate_error;
      }
    }

    const DWORD wait_result = ::WaitForSingleObject(
        process, yixue::runner::kChildTerminationWaitMs);
    if (wait_result == WAIT_OBJECT_0) return;
    if (wait_result == WAIT_FAILED) wait_error = ::GetLastError();
    if (error != nullptr) {
      *error = wait_error != ERROR_SUCCESS
                   ? wait_error
                   : terminate_error != ERROR_SUCCESS ? terminate_error
                                                       : ERROR_TIMEOUT;
    }
    const ULONGLONG now = ::GetTickCount64();
    if (now >= next_log_at) {
      yixue::runner::diagnostics::Log(
          "supervisor_unassigned_child_still_running",
          error == nullptr ? ERROR_TIMEOUT : *error);
      next_log_at = now + 10'000;
    }
    if (!waiting_warning_shown && now - waiting_since >= 10'000) {
      waiting_warning_shown = true;
      ShowSupervisorNoticeWithoutBlockingRetries(
          L"Windows 仍在确认未成功启动的译学界面进程已结束。确认前会保持资料库锁，请不要重复启动。",
          L"译学仍在收尾");
    }
    ::Sleep(50);
  }
}

bool WaitForOwnedProcessTree(HANDLE job, HANDLE process, DWORD timeout_ms,
                             DWORD* error) {
  const ULONGLONG started_at = ::GetTickCount64();
  for (;;) {
    DWORD wait_error = ERROR_SUCCESS;
    const bool process_signaled = IsProcessSignaled(process, &wait_error);
    if (wait_error != ERROR_SUCCESS) {
      if (error != nullptr) *error = wait_error;
      return false;
    }
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting = {};
    if (!::QueryInformationJobObject(
            job, JobObjectBasicAccountingInformation, &accounting,
            sizeof(accounting), nullptr)) {
      if (error != nullptr) *error = ::GetLastError();
      return false;
    }
    if (yixue::runner::IsOwnedProcessTreeConfirmedStopped(
            process_signaled, true, accounting.ActiveProcesses)) {
      return true;
    }
    if (::GetTickCount64() - started_at >= timeout_ms) {
      if (error != nullptr) *error = ERROR_TIMEOUT;
      return false;
    }
    ::Sleep(25);
  }
}

void TerminateOwnedProcessTree(HANDLE* job, HANDLE process,
                               DWORD exit_code, DWORD* error) {
  if (job == nullptr || *job == nullptr || process == nullptr ||
      process == INVALID_HANDLE_VALUE) {
    if (error != nullptr) *error = ERROR_INVALID_HANDLE;
    yixue::runner::diagnostics::Log(
        "supervisor_process_tree_confirmation_unavailable",
        ERROR_INVALID_HANDLE);
    // Do not return to the launcher in an unknown state: its thread owns the
    // single-instance mutex, and releasing it could open the same data store.
    for (;;) ::Sleep(1000);
  }

  // Keep the job handle open while checking its member count. Closing it is a
  // kill-on-close fallback, but would make it impossible to prove that every
  // descendant has stopped before releasing the single-instance mutex.
  ULONGLONG next_retry_at = 0;
  ULONGLONG next_log_at = ::GetTickCount64();
  ULONGLONG waiting_since = next_log_at;
  bool waiting_warning_shown = false;
  DWORD last_error = ERROR_SUCCESS;
  for (;;) {
    DWORD observation_error = ERROR_SUCCESS;
    if (WaitForOwnedProcessTree(*job, process, 1000, &observation_error)) {
      if (error != nullptr) *error = ERROR_SUCCESS;
      return;
    }
    if (observation_error != ERROR_SUCCESS) last_error = observation_error;

    const ULONGLONG now = ::GetTickCount64();
    if (now >= next_retry_at) {
      if (!::TerminateJobObject(*job, exit_code)) {
        last_error = ::GetLastError();
      }
      next_retry_at = now + 1000;
    }
    if (error != nullptr) {
      *error = last_error == ERROR_SUCCESS ? ERROR_TIMEOUT : last_error;
    }
    if (now >= next_log_at) {
      yixue::runner::diagnostics::Log(
          "supervisor_process_tree_still_running",
          last_error == ERROR_SUCCESS ? ERROR_TIMEOUT : last_error);
      next_log_at = now + 10'000;
    }
    if (!waiting_warning_shown && now - waiting_since >= 10'000) {
      waiting_warning_shown = true;
      ShowSupervisorNoticeWithoutBlockingRetries(
          L"Windows 仍在收尾译学及其子进程。确认进程树完全停止前，资料库锁会保持占用，以避免同时写入字幕、录音或录屏历史。",
          L"译学仍在收尾");
    }
    ::Sleep(50);
  }
}

DWORD RunSupervisedApplication(
    const std::vector<std::string>& original_arguments,
    bool* process_tree_confirmed_stopped,
    std::wstring* notice_after_mutex_release) {
  if (process_tree_confirmed_stopped == nullptr ||
      notice_after_mutex_release == nullptr) {
    return ERROR_INVALID_PARAMETER;
  }
  *process_tree_confirmed_stopped = true;
  notice_after_mutex_release->clear();
  yixue::runner::diagnostics::Log("supervisor_start");
  std::vector<wchar_t> executable_buffer(32768, L'\0');
  const DWORD executable_length = ::GetModuleFileNameW(
      nullptr, executable_buffer.data(),
      static_cast<DWORD>(executable_buffer.size()));
  if (executable_length == 0 || executable_length >= executable_buffer.size()) {
    ShowSupervisorError(
        L"\u65E0\u6CD5\u83B7\u53D6\u7A0B\u5E8F\u8DEF\u5F84\u3002",
        ::GetLastError());
    return ERROR_BAD_PATHNAME;
  }
  const std::wstring executable_path(executable_buffer.data(),
                                     executable_length);
  const size_t separator = executable_path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    ShowSupervisorError(
        L"\u8BD1\u5B66\u7A0B\u5E8F\u76EE\u5F55\u65E0\u6548\u3002",
        ERROR_BAD_PATHNAME);
    return ERROR_BAD_PATHNAME;
  }
  const std::wstring working_directory = executable_path.substr(0, separator);
  GUID invocation_id = {};
  const HRESULT guid_result = ::CoCreateGuid(&invocation_id);
  if (FAILED(guid_result)) {
    yixue::runner::diagnostics::Log(
        "supervisor_guid_failed", static_cast<DWORD>(guid_result));
    ShowSupervisorError(L"\u65E0\u6CD5\u521B\u5EFA\u5173\u95ED\u901A\u77E5\u6807\u8BC6\u3002",
                        ERROR_GEN_FAILURE);
    return ERROR_GEN_FAILURE;
  }
  wchar_t invocation_id_text[40] = {};
  if (::StringFromGUID2(invocation_id, invocation_id_text,
                        _countof(invocation_id_text)) == 0) {
    yixue::runner::diagnostics::Log("supervisor_guid_format_failed",
                                    ERROR_INSUFFICIENT_BUFFER);
    ShowSupervisorError(L"\u65E0\u6CD5\u683C\u5F0F\u5316\u5173\u95ED\u901A\u77E5\u6807\u8BC6\u3002",
                        ERROR_GEN_FAILURE);
    return ERROR_GEN_FAILURE;
  }
  const std::wstring event_name =
      std::wstring(kSupervisorEventNamePrefix) +
      std::to_wstring(::GetCurrentProcessId()) + L"." + invocation_id_text;
  const std::wstring app_ready_event_name = event_name + L".AppReady";

  ::SetLastError(ERROR_SUCCESS);
  HANDLE close_event = ::CreateEventW(nullptr, TRUE, FALSE, event_name.c_str());
  const DWORD event_create_result = ::GetLastError();
  if (close_event == nullptr) {
    yixue::runner::diagnostics::Log("supervisor_event_create_failed",
                                    event_create_result);
    ShowSupervisorError(
        L"\u65E0\u6CD5\u521B\u5EFA\u5173\u95ED\u901A\u77E5\u4E8B\u4EF6\u3002",
        event_create_result);
    return event_create_result;
  }
  if (event_create_result == ERROR_ALREADY_EXISTS) {
    yixue::runner::diagnostics::Log("supervisor_event_collision",
                                    event_create_result);
    ::CloseHandle(close_event);
    ShowSupervisorError(
        L"\u95ED\u5408\u901A\u77E5\u6807\u8BC6\u91CD\u590D\uFF0C\u5DF2\u53D6\u6D88\u542F\u52A8\u4EE5\u4FDD\u62A4\u5F53\u524D\u8FDB\u7A0B\u3002",
        ERROR_ALREADY_EXISTS);
    return ERROR_ALREADY_EXISTS;
  }
  yixue::runner::diagnostics::Log("supervisor_event_created");

  ::SetLastError(ERROR_SUCCESS);
  HANDLE app_ready_event =
      ::CreateEventW(nullptr, TRUE, FALSE, app_ready_event_name.c_str());
  const DWORD app_ready_event_create_result = ::GetLastError();
  if (app_ready_event == nullptr ||
      app_ready_event_create_result == ERROR_ALREADY_EXISTS) {
    const DWORD error = app_ready_event == nullptr
                            ? app_ready_event_create_result
                            : ERROR_ALREADY_EXISTS;
    yixue::runner::diagnostics::Log("supervisor_app_ready_event_create_failed",
                                    error);
    if (app_ready_event != nullptr) ::CloseHandle(app_ready_event);
    ::CloseHandle(close_event);
    ShowSupervisorError(
        L"无法创建主窗启动完成通知。", error);
    return error;
  }

  HANDLE job = ::CreateJobObjectW(nullptr, nullptr);
  if (job == nullptr) {
    const DWORD error = ::GetLastError();
    ::CloseHandle(app_ready_event);
    ::CloseHandle(close_event);
    ShowSupervisorError(
        L"\u65E0\u6CD5\u521B\u5EFA\u8FDB\u7A0B\u56DE\u6536\u4FDD\u62A4\u3002",
        error);
    return error;
  }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION job_limits = {};
  job_limits.BasicLimitInformation.LimitFlags =
      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!::SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                 &job_limits, sizeof(job_limits))) {
    const DWORD error = ::GetLastError();
    ::CloseHandle(job);
    ::CloseHandle(app_ready_event);
    ::CloseHandle(close_event);
    ShowSupervisorError(
        L"\u65E0\u6CD5\u542F\u7528\u5B50\u8FDB\u7A0B\u6811\u56DE\u6536\u4FDD\u62A4\u3002",
        error);
    return error;
  }

  std::wstring command_line = QuoteWindowsArgument(executable_path);
  command_line += L" ";
  command_line += QuoteWindowsArgument(kSupervisedUiArgumentWide);
  command_line += L" ";
  command_line += QuoteWindowsArgument(
      std::wstring(L"--yixue-supervisor-event=") + event_name);
  command_line += L" ";
  command_line += QuoteWindowsArgument(
      std::wstring(L"--yixue-supervisor-app-ready-event=") + app_ready_event_name);
  for (const auto& argument : original_arguments) {
    if (argument == kSupervisedUiArgument ||
        argument.rfind(kSupervisorEventArgumentPrefix, 0) == 0 ||
        argument.rfind(kSupervisorAppReadyEventArgumentPrefix, 0) == 0) {
      continue;
    }
    std::wstring wide_argument;
    if (!ConvertUtf8ToWide(argument, &wide_argument)) {
      ::CloseHandle(job);
      ::CloseHandle(app_ready_event);
      ::CloseHandle(close_event);
      ShowSupervisorError(
          L"\u65E0\u6CD5\u8F6C\u53D1\u542F\u52A8\u53C2\u6570\u3002",
          ERROR_NO_UNICODE_TRANSLATION);
      return ERROR_NO_UNICODE_TRANSLATION;
    }
    command_line += L" ";
    command_line += QuoteWindowsArgument(wide_argument);
  }

  STARTUPINFOW startup_info = {};
  startup_info.cb = sizeof(startup_info);
  startup_info.dwFlags = STARTF_USESHOWWINDOW;
  startup_info.wShowWindow = SW_SHOWNORMAL;
  PROCESS_INFORMATION process_info = {};
  if (!::CreateProcessW(executable_path.c_str(), command_line.data(), nullptr,
                        nullptr, FALSE, CREATE_SUSPENDED, nullptr,
                        working_directory.c_str(), &startup_info,
                        &process_info)) {
    const DWORD error = ::GetLastError();
    yixue::runner::diagnostics::Log("supervisor_child_create_failed", error);
    ::CloseHandle(job);
    ::CloseHandle(app_ready_event);
    ::CloseHandle(close_event);
    ShowSupervisorError(
        L"\u65E0\u6CD5\u542F\u52A8\u8BD1\u5B66\u754C\u9762\u8FDB\u7A0B\u3002",
        error);
    return error;
  }
  *process_tree_confirmed_stopped = false;

  if (!::AssignProcessToJobObject(job, process_info.hProcess)) {
    const DWORD error = ::GetLastError();
    DWORD termination_error = ERROR_SUCCESS;
    TerminateUnassignedChild(process_info.hProcess, error,
                             &termination_error);
    *process_tree_confirmed_stopped = true;
    ::CloseHandle(process_info.hThread);
    ::CloseHandle(process_info.hProcess);
    ::CloseHandle(job);
    ::CloseHandle(app_ready_event);
    ::CloseHandle(close_event);
    ShowSupervisorError(
        L"\u65E0\u6CD5\u5C06\u754C\u9762\u8FDB\u7A0B\u653E\u5165\u53EF\u56DE\u6536\u7684\u8FDB\u7A0B\u7EC4\uFF0C\u5DF2\u786E\u8BA4\u672A\u542F\u52A8\u5B64\u7ACB\u5B9E\u4F8B\u3002",
        termination_error == ERROR_SUCCESS ? error : termination_error);
    return error;
  }
  if (::ResumeThread(process_info.hThread) == static_cast<DWORD>(-1)) {
    const DWORD error = ::GetLastError();
    yixue::runner::diagnostics::Log("supervisor_child_resume_failed", error);
    DWORD termination_error = ERROR_SUCCESS;
    TerminateOwnedProcessTree(&job, process_info.hProcess, error,
                              &termination_error);
    *process_tree_confirmed_stopped = true;
    ::CloseHandle(process_info.hThread);
    ::CloseHandle(process_info.hProcess);
    if (job != nullptr) ::CloseHandle(job);
    ::CloseHandle(app_ready_event);
    ::CloseHandle(close_event);
    ShowSupervisorError(
        L"\u65E0\u6CD5\u6062\u590D\u8BD1\u5B66\u754C\u9762\u8FDB\u7A0B\uFF0C\u5DF2\u786E\u8BA4\u8FDB\u7A0B\u7EC4\u5DF2\u6536\u5C3E\u3002",
        error);
    return error;
  }
  ::CloseHandle(process_info.hThread);
  yixue::runner::diagnostics::Log("supervisor_child_resumed",
                                  process_info.dwProcessId);

  HANDLE startup_wait_handles[] = {process_info.hProcess, close_event,
                                  app_ready_event};
  DWORD startup_wait_result = WAIT_FAILED;
  auto startup_outcome =
      yixue::runner::StartupAppWaitOutcome::kFailed;
  bool startup_cancel_requested = false;
  bool process_only_startup_wait = false;
  auto request_startup_cancel = [&]() {
    startup_cancel_requested = true;
    yixue::runner::diagnostics::Log(
        "supervisor_app_startup_cancel_requested",
        process_info.dwProcessId);
    HWND startup_window =
        ::FindWindowW(kMainWindowClassName, kMainWindowTitle);
    DWORD startup_window_process_id = 0;
    if (startup_window != nullptr && ::IsWindow(startup_window)) {
      (void)::GetWindowThreadProcessId(startup_window,
                                       &startup_window_process_id);
    }
    const DWORD child_process_state =
        ::WaitForSingleObject(process_info.hProcess, 0);
    const bool child_is_running = child_process_state == WAIT_TIMEOUT;
    const bool startup_window_is_child =
        yixue::runner::ShouldPostStartupCloseRequest(
            child_is_running, startup_window != nullptr,
            startup_window_process_id, process_info.dwProcessId);
    bool startup_close_request_attempted = false;
    if (startup_window_is_child) {
      DWORD current_window_process_id = 0;
      const bool window_is_still_valid =
          ::IsWindow(startup_window) != FALSE;
      if (window_is_still_valid) {
        (void)::GetWindowThreadProcessId(startup_window,
                                         &current_window_process_id);
      }
      const DWORD current_child_process_state =
          ::WaitForSingleObject(process_info.hProcess, 0);
      if (yixue::runner::ShouldPostStartupCloseRequest(
              current_child_process_state == WAIT_TIMEOUT,
              window_is_still_valid, current_window_process_id,
              process_info.dwProcessId)) {
        startup_close_request_attempted = true;
        if (::PostMessageW(startup_window, WM_CLOSE, 0, 0)) {
          yixue::runner::diagnostics::Log(
              "supervisor_startup_verified_wm_close_posted",
              process_info.dwProcessId);
        } else {
          yixue::runner::diagnostics::Log(
              "supervisor_startup_verified_wm_close_failed",
              ::GetLastError());
        }
      }
    }
    if (!startup_close_request_attempted) {
      yixue::runner::diagnostics::Log(
          "supervisor_startup_close_window_unverified",
          process_info.dwProcessId);
    }

    // Keep the candidate marker until shutdown finishes so other launchers
    // cannot mistake this cancellation for a stale orphan.
    startup_outcome =
        yixue::runner::StartupAppWaitOutcome::kCloseRequested;
  };
  for (;;) {
    if (process_only_startup_wait) {
      startup_wait_result = ::WaitForSingleObject(
          process_info.hProcess, yixue::runner::kChildStartupTimeoutMs);
      startup_outcome =
          yixue::runner::ResolveStartupProcessWaitOutcome(
              startup_wait_result);
    } else {
      startup_wait_result = ::WaitForMultipleObjects(
          _countof(startup_wait_handles), startup_wait_handles, FALSE,
          yixue::runner::kChildStartupTimeoutMs);
      startup_outcome =
          yixue::runner::ResolveStartupAppWaitOutcome(startup_wait_result);
    }
    if (startup_outcome ==
        yixue::runner::StartupAppWaitOutcome::kFailed) {
      const DWORD startup_wait_error = ::GetLastError();
      yixue::runner::diagnostics::Log(
          process_only_startup_wait
              ? "supervisor_process_only_startup_wait_failed"
              : "supervisor_startup_wait_failed",
          startup_wait_error);
      const int wait_failure_choice = ::MessageBoxW(
          nullptr,
          L"Windows 无法监视译学是否启动完成。它可能仍在初始化或写入本地资料库。\n\n选择“是”继续等待并重试监视；选择“否”取消启动，Windows 会先尝试正常关闭已验证的译学窗口，并等待 60 秒。",
          L"译学启动状态未确认",
          MB_YESNO | MB_ICONWARNING |
              yixue::runner::kStartupTimeoutDefaultButton | MB_TOPMOST |
              MB_SETFOREGROUND);
      if (yixue::runner::ResolveStartupTimeoutChoice(wait_failure_choice) ==
          yixue::runner::StartupTimeoutAction::kContinueWaiting) {
        const bool process_only_wait_already_enabled =
            process_only_startup_wait;
        process_only_startup_wait = true;
        yixue::runner::diagnostics::Log(
            "supervisor_process_only_startup_wait_enabled",
            yixue::runner::kChildStartupTimeoutMs);
        if (process_only_wait_already_enabled &&
            startup_wait_error != ERROR_SUCCESS) {
          ::Sleep(yixue::runner::kChildShutdownGracePeriodMs);
        }
        continue;
      }
      request_startup_cancel();
      break;
    }
    if (startup_outcome !=
        yixue::runner::StartupAppWaitOutcome::kTimedOut) {
      break;
    }

    yixue::runner::diagnostics::Log(
        process_only_startup_wait
            ? "supervisor_process_only_startup_poll_timed_out"
            : "supervisor_app_startup_timeout",
        yixue::runner::kChildStartupTimeoutMs);
    const wchar_t* startup_timeout_message = process_only_startup_wait
        ? L"Windows 仍无法确认译学已完成启动，但子进程仍在运行。选择“是”再等待 120 秒；选择“否”取消启动。取消时会先尝试正常关闭，不会自动强制结束。"
        : L"译学在 120 秒内还没有完成启动。它可能仍在初始化本地资料库。\n\n选择“是”继续等待；选择“否”取消启动。取消时，Windows 会先尝试正常关闭已验证的译学窗口，并等待 60 秒；之后才会再次询问是否强制结束。";
    const int timeout_choice = ::MessageBoxW(
        nullptr,
        startup_timeout_message,
        L"\u8BD1\u5B66\u4ECD\u5728\u542F\u52A8",
        MB_YESNO | MB_ICONWARNING |
            yixue::runner::kStartupTimeoutDefaultButton | MB_TOPMOST |
            MB_SETFOREGROUND);
    if (yixue::runner::ResolveStartupTimeoutChoice(timeout_choice) ==
        yixue::runner::StartupTimeoutAction::kContinueWaiting) {
      yixue::runner::diagnostics::Log(
          "supervisor_app_startup_wait_extended",
          yixue::runner::kChildStartupTimeoutMs);
      continue;
    }
    request_startup_cancel();
    break;
  }
  DWORD supervisor_wait_error = ERROR_SUCCESS;
  DWORD wait_result = WAIT_FAILED;
  if (yixue::runner::ShouldWaitForAppLifetime(startup_outcome)) {
    yixue::runner::diagnostics::Log("supervisor_ui_app_ready",
                                    process_info.dwProcessId);
    CloseRecoveryCandidateMarker();
    // Keep the instance mutex owned by this supervisor for the entire UI
    // lifetime. The UI child only opens a synchronize-only handle, so
    // releasing here would let a second launcher enter stale-process
    // recovery while this healthy instance is still running (for example,
    // while its window is hidden or temporarily unavailable to enumeration).
    HANDLE wait_handles[] = {process_info.hProcess, close_event};
    wait_result = ::WaitForMultipleObjects(_countof(wait_handles),
                                           wait_handles, FALSE, INFINITE);
  } else if (startup_outcome ==
      yixue::runner::StartupAppWaitOutcome::kChildExited) {
    CloseRecoveryCandidateMarker();
    wait_result = WAIT_OBJECT_0;
  } else if (startup_outcome ==
      yixue::runner::StartupAppWaitOutcome::kCloseRequested) {
    if (!startup_cancel_requested) CloseRecoveryCandidateMarker();
    wait_result = WAIT_OBJECT_0 + 1;
  } else if (startup_outcome ==
      yixue::runner::StartupAppWaitOutcome::kTimedOut) {
    // Defensive fallback: normal timeouts are converted to an explicit choice.
    wait_result = WAIT_OBJECT_0 + 1;
  } else {
    supervisor_wait_error = ::GetLastError();
    yixue::runner::diagnostics::Log("supervisor_startup_wait_failed",
                                    supervisor_wait_error);
    CloseRecoveryCandidateMarker();
    wait_result = WAIT_FAILED;
  }
  if (wait_result == WAIT_FAILED && supervisor_wait_error == ERROR_SUCCESS) {
    supervisor_wait_error = ::GetLastError();
    if (supervisor_wait_error == ERROR_SUCCESS) {
      supervisor_wait_error = ERROR_GEN_FAILURE;
    }
  }
  DWORD child_exit_code = EXIT_FAILURE;
  bool forced_termination = false;
  bool process_tree_stopped = false;
  DWORD termination_error = ERROR_SUCCESS;
  if (wait_result == WAIT_OBJECT_0) {
    if (!::GetExitCodeProcess(process_info.hProcess, &child_exit_code)) {
      child_exit_code = ::GetLastError();
    }
    yixue::runner::diagnostics::Log("supervisor_child_exited",
                                    child_exit_code);
  } else if (wait_result == WAIT_OBJECT_0 + 1) {
    if (startup_cancel_requested) {
      yixue::runner::diagnostics::Log(
          "supervisor_startup_cancel_close_wait_begin",
          yixue::runner::kChildShutdownGracePeriodMs);
    } else {
      yixue::runner::diagnostics::Log("supervisor_close_event_signaled");
      yixue::runner::diagnostics::Log(
          "supervisor_child_close_wait_begin",
          yixue::runner::kChildShutdownGracePeriodMs);
    }
    DWORD close_wait = ::WaitForSingleObject(
        process_info.hProcess,
        yixue::runner::kChildShutdownGracePeriodMs);
    if (yixue::runner::ShouldDelayStartupForcePromptAfterWaitFailure(
            startup_cancel_requested, close_wait)) {
      yixue::runner::diagnostics::Log(
          "supervisor_startup_cancel_wait_failure_grace_begin",
          yixue::runner::kChildShutdownGracePeriodMs);
      ::Sleep(yixue::runner::kChildShutdownGracePeriodMs);
      close_wait = ::WaitForSingleObject(process_info.hProcess, 0);
    }
    const DWORD close_wait_error =
        close_wait == WAIT_FAILED ? ::GetLastError() : ERROR_SUCCESS;
    const char* close_wait_status =
        close_wait == WAIT_OBJECT_0
            ? "supervisor_child_closed_in_grace"
            : close_wait == WAIT_TIMEOUT
                  ? "supervisor_child_close_wait_timed_out"
                  : "supervisor_child_close_wait_failed";
    yixue::runner::diagnostics::Log(close_wait_status, close_wait);
    if (yixue::runner::DecideChildShutdownDisposition(close_wait == WAIT_OBJECT_0,
                                                      false) ==
        yixue::runner::ChildShutdownDisposition::kAlreadyExited) {
      if (!::GetExitCodeProcess(process_info.hProcess, &child_exit_code)) {
        child_exit_code = ::GetLastError();
      }
    } else {
      const DWORD wait_error = close_wait_error;
      if (close_wait == WAIT_FAILED) {
        yixue::runner::diagnostics::Log("supervisor_child_close_wait_failed",
                                        wait_error);
      }
      const bool close_wait_timed_out = close_wait == WAIT_TIMEOUT;
      const wchar_t* shutdown_wait_message = startup_cancel_requested
          ? close_wait_timed_out
                ? L"\u4F60\u5DF2\u9009\u62E9\u53D6\u6D88\u542F\u52A8\uFF0C\u4F46\u8BD1\u5B66\u5728 60 \u79D2\u5185\u8FD8\u6CA1\u6709\u9000\u51FA\u3002\u5B83\u53EF\u80FD\u4ECD\u5728\u521D\u59CB\u5316\u6216\u5199\u5165\u672C\u5730\u8D44\u6599\u5E93\u3002\n\n\u9009\u62E9\u201C\u662F\u201D\u5F3A\u5236\u7ED3\u675F\uFF0C\u53EF\u80FD\u635F\u574F\u672A\u5B8C\u6210\u7684\u672C\u5730\u5199\u5165\uFF1B\u9009\u62E9\u201C\u5426\u201D\u7EE7\u7EED\u7B49\u5F85\u81EA\u7136\u9000\u51FA\u3002"
                : L"Windows \u65E0\u6CD5\u786E\u8BA4\u53D6\u6D88\u542F\u52A8\u540E\u7684\u8BD1\u5B66\u662F\u5426\u5DF2\u9000\u51FA\u3002\n\n\u9009\u62E9\u201C\u662F\u201D\u5F3A\u5236\u7ED3\u675F\uFF0C\u53EF\u80FD\u635F\u574F\u672C\u5730\u8D44\u6599\uFF1B\u9009\u62E9\u201C\u5426\u201D\u7EE7\u7EED\u7B49\u5F85\u81EA\u7136\u9000\u51FA\u3002"
          : close_wait_timed_out
                ? L"\u8BD1\u5B66\u5173\u95ED\u8D85\u8FC7 60 \u79D2\u4ECD\u672A\u5B8C\u6210\uFF0C\u4ECD\u6709\u5F55\u97F3\u6216\u5F55\u5C4F\u5199\u5165\u64CD\u4F5C\u6CA1\u6709\u8FD4\u56DE\u3002\n\n\u9009\u62E9\u201C\u662F\u201D\u5F3A\u5236\u7ED3\u675F\uFF0C\u672A\u5B8C\u6210\u7684\u5A92\u4F53\u6587\u4EF6\u53EF\u80FD\u635F\u574F\uFF1B\u9009\u62E9\u201C\u5426\u201D\u4F1A\u7EE7\u7EED\u7B49\u5F85\u8BD1\u5B66\u81EA\u7136\u4FDD\u5B58\u5E76\u9000\u51FA\u3002"
                : L"Windows \u65E0\u6CD5\u786E\u8BA4\u8BD1\u5B66\u662F\u5426\u5DF2\u5173\u95ED\u3002\n\n\u9009\u62E9\u201C\u662F\u201D\u5F3A\u5236\u7ED3\u675F\uFF0C\u5F55\u97F3\u6216\u5F55\u5C4F\u6587\u4EF6\u53EF\u80FD\u635F\u574F\uFF1B\u9009\u62E9\u201C\u5426\u201D\u4F1A\u7EE7\u7EED\u7B49\u5F85\u8BD1\u5B66\u81EA\u7136\u4FDD\u5B58\u5E76\u9000\u51FA\u3002";
      const wchar_t* shutdown_wait_title = close_wait_timed_out
          ? L"\u8BD1\u5B66\u4ECD\u5728\u6536\u5C3E"
          : L"\u8BD1\u5B66\u5173\u95ED\u72B6\u6001\u672A\u786E\u8BA4";
      const int force_choice = ::MessageBoxW(
          nullptr, shutdown_wait_message, shutdown_wait_title,
          MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2);
      const bool force_termination_confirmed = force_choice == IDYES;
      const DWORD prompt_return_wait =
          ::WaitForSingleObject(process_info.hProcess, 0);
      const bool child_exited_while_prompt_was_open =
          prompt_return_wait == WAIT_OBJECT_0;
      if (prompt_return_wait == WAIT_FAILED) {
        const DWORD prompt_wait_error = ::GetLastError();
        yixue::runner::diagnostics::Log(
            "supervisor_child_prompt_return_wait_failed", prompt_wait_error);
      }
      const auto disposition = yixue::runner::DecideChildShutdownDisposition(
          child_exited_while_prompt_was_open, force_termination_confirmed);
      if (disposition ==
          yixue::runner::ChildShutdownDisposition::kAlreadyExited) {
        wait_result = WAIT_OBJECT_0;
        if (!::GetExitCodeProcess(process_info.hProcess, &child_exit_code)) {
          child_exit_code = ::GetLastError();
        }
        yixue::runner::diagnostics::Log(
            "supervisor_child_exited_while_shutdown_prompt_open",
            child_exit_code);
      } else if (disposition ==
                 yixue::runner::ChildShutdownDisposition::
                     kForceTerminateOwnedProcessTree) {
        forced_termination = true;
        TerminateOwnedProcessTree(&job, process_info.hProcess,
                                  yixue::runner::kForcedChildExitCode,
                                  &termination_error);
        process_tree_stopped = true;
        child_exit_code = yixue::runner::kForcedChildExitCode;
        yixue::runner::diagnostics::Log(
            process_tree_stopped ? "supervisor_child_tree_reclaimed"
                                 : "supervisor_child_tree_reclaim_failed",
            termination_error);
      } else {
        yixue::runner::diagnostics::Log(
            "supervisor_child_shutdown_waiting_for_natural_exit",
            wait_error);
        for (;;) {
          const DWORD natural_wait = ::WaitForSingleObject(
              process_info.hProcess,
              yixue::runner::kChildShutdownGracePeriodMs);
          if (!yixue::runner::ShouldRepeatNaturalShutdownPrompt(natural_wait)) {
            break;
          }
          DWORD natural_wait_error = ERROR_TIMEOUT;
          if (natural_wait == WAIT_FAILED) {
            natural_wait_error = ::GetLastError();
            yixue::runner::diagnostics::Log(
                "supervisor_child_natural_exit_wait_failed",
                natural_wait_error);
          }
          if (yixue::runner::ShouldBackoffBeforeRepeatedShutdownPrompt(
                  natural_wait)) {
            ::Sleep(yixue::runner::kChildShutdownGracePeriodMs);
            const DWORD delayed_wait =
                ::WaitForSingleObject(process_info.hProcess, 0);
            if (delayed_wait == WAIT_OBJECT_0) break;
            if (delayed_wait == WAIT_FAILED) {
              yixue::runner::diagnostics::Log(
                  "supervisor_child_delayed_wait_failed", ::GetLastError());
            }
          }

          const int repeat_force_choice = ::MessageBoxW(
              nullptr,
              startup_cancel_requested
                  ? L"取消启动后，译学仍未退出。选择“是”强制结束，可能损坏本地资料；选择“否”再等待 60 秒。"
                  : L"译学仍未完成退出。选择“是”强制结束，未完成的录音或录屏可能损坏；选择“否”再等待 60 秒。",
              L"译学仍在收尾",
              MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2);
          const DWORD repeat_prompt_return_wait =
              ::WaitForSingleObject(process_info.hProcess, 0);
          if (repeat_prompt_return_wait == WAIT_OBJECT_0) break;
          if (repeat_prompt_return_wait == WAIT_FAILED) {
            yixue::runner::diagnostics::Log(
                "supervisor_child_repeat_prompt_wait_failed",
                ::GetLastError());
          }
          if (repeat_force_choice == IDYES) {
            forced_termination = true;
            wait_result = WAIT_OBJECT_0 + 1;
            TerminateOwnedProcessTree(
                &job, process_info.hProcess,
                yixue::runner::kForcedChildExitCode, &termination_error);
            process_tree_stopped = true;
            child_exit_code = yixue::runner::kForcedChildExitCode;
            yixue::runner::diagnostics::Log(
                "supervisor_child_tree_reclaimed_after_extended_wait",
                termination_error);
            break;
          }
          yixue::runner::diagnostics::Log(
              "supervisor_child_natural_exit_wait_extended", natural_wait_error);
        }
        if (!forced_termination) {
          wait_result = WAIT_OBJECT_0;
          if (!::GetExitCodeProcess(process_info.hProcess, &child_exit_code)) {
            child_exit_code = ::GetLastError();
          }
          yixue::runner::diagnostics::Log(
              "supervisor_child_exited_after_extended_wait", child_exit_code);
        }
      }
    }
  } else {
    const DWORD error = wait_result == WAIT_FAILED
                            ? supervisor_wait_error
                            : ERROR_GEN_FAILURE;
    yixue::runner::diagnostics::Log("supervisor_wait_failed", error);
    // A failed wait does not prove the UI or its media workers have stopped.
    // Keep the job and instance lock until natural exit is observed or the user
    // explicitly confirms forced termination below.
    child_exit_code = error;
  }

  // Natural exit of the UI does not imply that every descendant has finished
  // saving media. Wait for the whole job to exit; force it only after an
  // explicit user confirmation.
  while (!process_tree_stopped) {
    DWORD tree_wait_error = ERROR_SUCCESS;
    if (WaitForOwnedProcessTree(
            job, process_info.hProcess,
            yixue::runner::kChildShutdownGracePeriodMs, &tree_wait_error)) {
      process_tree_stopped = true;
      break;
    }
    if (tree_wait_error != ERROR_TIMEOUT) {
      yixue::runner::diagnostics::Log(
          "supervisor_process_tree_natural_wait_failed", tree_wait_error);
      ::Sleep(yixue::runner::kChildShutdownGracePeriodMs);
    }

    const auto primary_process_state =
        yixue::runner::ResolvePrimaryProcessExitState(
            ::WaitForSingleObject(process_info.hProcess, 0));
    const wchar_t* primary_process_message =
        primary_process_state ==
                yixue::runner::PrimaryProcessExitState::kExited
            ? L"译学主窗口进程已退出，但 Windows 尚未确认媒体子进程全部收尾。"
            : primary_process_state ==
                      yixue::runner::PrimaryProcessExitState::kRunning
                  ? L"译学主窗口进程仍在运行，Windows 尚未确认媒体操作及子进程全部收尾。"
                  : L"Windows 无法确认译学主窗口是否退出，也未确认媒体子进程全部收尾。";
    const std::wstring tree_shutdown_message =
        std::wstring(primary_process_message) +
        L"Windows 已等待 60 秒。\n\n选择“是”仅在你确认后强制结束，可能损坏未保存的录音或录屏；选择“否”继续等待自然完成。";
    const int tree_choice = ::MessageBoxW(
        nullptr, tree_shutdown_message.c_str(),
        L"\u8BD1\u5B66\u6B63\u5728\u4FDD\u5B58\u5A92\u4F53",
        MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2 | MB_TOPMOST |
            MB_SETFOREGROUND);
    const auto tree_disposition =
        yixue::runner::DecideOwnedProcessTreeShutdownDisposition(
            process_tree_stopped, tree_choice == IDYES);
    if (tree_disposition ==
        yixue::runner::OwnedProcessTreeShutdownDisposition::
            kForceTerminateAfterConfirmation) {
      forced_termination = true;
      TerminateOwnedProcessTree(&job, process_info.hProcess,
                                yixue::runner::kForcedChildExitCode,
                                &termination_error);
      process_tree_stopped = true;
      child_exit_code = yixue::runner::kForcedChildExitCode;
      yixue::runner::diagnostics::Log(
          "supervisor_child_tree_force_terminated_after_user_confirmation",
          termination_error);
    } else if (tree_disposition ==
               yixue::runner::OwnedProcessTreeShutdownDisposition::
                   kWaitForNaturalExit) {
      yixue::runner::diagnostics::Log(
          "supervisor_process_tree_natural_wait_extended", tree_wait_error);
    }
  }

  *process_tree_confirmed_stopped = true;

  if (job != nullptr) ::CloseHandle(job);
  ::CloseHandle(app_ready_event);
  ::CloseHandle(close_event);
  ::CloseHandle(process_info.hProcess);
  CloseRecoveryCandidateMarker();
  if (forced_termination) {
    if (startup_cancel_requested) {
      yixue::runner::diagnostics::Log(
          "supervisor_startup_cancel_force_termination_confirmed",
          yixue::runner::kChildShutdownGracePeriodMs);
      *notice_after_mutex_release =
          L"\u4F60\u9009\u62E9\u4E86\u53D6\u6D88\u542F\u52A8\uFF0C\u5E76\u5728 60 \u79D2\u7B49\u5F85\u540E\u518D\u6B21\u786E\u8BA4\u5F3A\u5236\u7ED3\u675F\u3002\n\n\u5982\u679C\u542F\u52A8\u671F\u95F4\u6B63\u5728\u521D\u59CB\u5316\u6216\u5199\u5165\u672C\u5730\u8D44\u6599\uFF0C\u5F3A\u5236\u7ED3\u675F\u53EF\u80FD\u4F1A\u635F\u574F\u672A\u5B8C\u6210\u7684\u5199\u5165\u3002";
    } else if (wait_result == WAIT_OBJECT_0 + 1) {
      yixue::runner::diagnostics::Log("supervisor_force_termination_confirmed",
                                      yixue::runner::kChildShutdownGracePeriodMs);
      *notice_after_mutex_release =
          L"\u4F60\u9009\u62E9\u4E86\u5F3A\u5236\u7ED3\u675F\u8BD1\u5B66\u3002\n\n\u5982\u679C\u6B63\u5728\u5F55\u97F3\u6216\u5F55\u5C4F\uFF0C\u672A\u5B8C\u6210\u7684\u5A92\u4F53\u6587\u4EF6\u53EF\u80FD\u635F\u574F\uFF1B\u8BF7\u4FDD\u7559 .partial.mp4 \u6587\u4EF6\u4F9B\u540E\u7EED\u6062\u590D\u3002";
    } else {
      *notice_after_mutex_release =
          L"\u76D1\u7763\u7A0B\u5E8F\u7B49\u5F85\u8BD1\u5B66\u5B9E\u4F8B\u65F6\u53D1\u751F\u9519\u8BEF\u3002Windows \u5DF2\u786E\u8BA4\u6536\u5C3E\u8FDB\u7A0B\u7EC4\uFF0C\u73B0\u5728\u53EF\u91CD\u8BD5\u542F\u52A8\u3002\n\nWindows \u9519\u8BEF\u4EE3\u7801\uFF1A" +
          std::to_wstring(supervisor_wait_error);
    }
  }
  if (forced_termination) {
    return process_tree_stopped ? EXIT_SUCCESS : ERROR_PROCESS_ABORTED;
  }
  return child_exit_code;
}

bool IsSupervisedUiArgument(const std::string& argument) {
  return argument == kSupervisedUiArgument;
}

std::optional<std::wstring> ReadSupervisorEventArgument(
    const std::vector<std::string>& arguments) {
  for (const auto& argument : arguments) {
    if (argument.rfind(kSupervisorEventArgumentPrefix, 0) != 0) continue;
    const std::string value =
        argument.substr(sizeof(kSupervisorEventArgumentPrefix) - 1);
    std::wstring wide_value;
    if (!ConvertUtf8ToWide(value, &wide_value) || wide_value.empty()) {
      return std::nullopt;
    }
    return wide_value;
  }
  return std::nullopt;
}

std::optional<std::wstring> ReadSupervisorAppReadyEventArgument(
    const std::vector<std::string>& arguments) {
  for (const auto& argument : arguments) {
    if (argument.rfind(kSupervisorAppReadyEventArgumentPrefix, 0) != 0) continue;
    const std::string value = argument.substr(
        sizeof(kSupervisorAppReadyEventArgumentPrefix) - 1);
    std::wstring wide_value;
    if (!ConvertUtf8ToWide(value, &wide_value) || wide_value.empty()) {
      return std::nullopt;
    }
    return wide_value;
  }
  return std::nullopt;
}

std::vector<std::string> FilterSupervisorArguments(
    const std::vector<std::string>& arguments) {
  std::vector<std::string> filtered;
  filtered.reserve(arguments.size());
  for (const auto& argument : arguments) {
    if (IsSupervisedUiArgument(argument) ||
        argument.rfind(kSupervisorEventArgumentPrefix, 0) == 0 ||
        argument.rfind(kSupervisorAppReadyEventArgumentPrefix, 0) == 0) {
      continue;
    }
    filtered.push_back(argument);
  }
  return filtered;
}

}  // namespace

void yixue::runner::SignalUiCleanupWatchdogStart() noexcept {
  if (g_ui_cleanup_start_event != nullptr &&
      !::SetEvent(g_ui_cleanup_start_event)) {
    yixue::runner::diagnostics::Log(
        "main_cleanup_watchdog_signal_failed", ::GetLastError());
    TerminateHungUiCleanup();
  }
  if (g_ui_cleanup_watchdog_wait_failed != nullptr &&
      g_ui_cleanup_watchdog_wait_failed->load(std::memory_order_acquire)) {
    yixue::runner::diagnostics::Log(
        "main_cleanup_watchdog_unavailable", ERROR_GEN_FAILURE);
    TerminateHungUiCleanup();
  }
}

void yixue::runner::SignalParentSupervisorCloseRequest() noexcept {
  if (g_supervisor_closing_event != nullptr &&
      !::SetEvent(g_supervisor_closing_event)) {
    yixue::runner::diagnostics::Log(
        "supervised_ui_signal_closing_event_failed", ::GetLastError());
  }
  if (g_supervisor_close_event != nullptr) {
    ::SetEvent(g_supervisor_close_event);
  }
}

bool yixue::runner::SignalParentSupervisorAppReady() noexcept {
  // Direct launches have no supervisor event and are already considered
  // ready by the parent process. A supervised launch must not acknowledge the
  // method call until Windows accepts the event signal.
  if (g_supervisor_app_ready_event == nullptr) return true;
  if (::SetEvent(g_supervisor_app_ready_event)) {
    yixue::runner::diagnostics::Log("supervised_ui_app_ready_event_signaled");
    CloseSupervisorAppReadyEvent();
    return true;
  }
  yixue::runner::diagnostics::Log(
      "supervised_ui_app_ready_event_signal_failed", ::GetLastError());
  // Keep the handle open so Dart's bounded retry loop can retry the signal.
  return false;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool subtitle_process =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                kSubtitleChildArgument) != command_line_arguments.end();
  const bool supervised_ui = std::any_of(
      command_line_arguments.begin(), command_line_arguments.end(),
      IsSupervisedUiArgument);
#if defined(_DEBUG)
  wchar_t integration_test_mode[2] = {};
  const DWORD integration_test_mode_length = ::GetEnvironmentVariableW(
      L"YIXUE_WINDOWS_INTEGRATION_TEST", integration_test_mode,
      _countof(integration_test_mode));
  const bool integration_test_requested =
      integration_test_mode_length == 1 && integration_test_mode[0] == L'1';
#else
  constexpr bool integration_test_requested = false;
#endif
  const bool direct_integration_test =
      yixue::runner::ShouldBypassSupervisorForIntegrationTest(
#if defined(_DEBUG)
          true,
#else
          false,
#endif
          integration_test_requested, subtitle_process, supervised_ui);
  yixue::runner::diagnostics::Log(
      subtitle_process ? "subtitle_process_entry"
                       : supervised_ui ? "supervised_ui_process_entry"
                       : direct_integration_test
                           ? "debug_integration_test_entry"
                           : "primary_process_entry");
  ::SetUnhandledExceptionFilter(
      &yixue::runner::diagnostics::CaptureUnhandledException);
  if (!subtitle_process && !supervised_ui && !direct_integration_test) {
    if (!AcquireSingleInstance()) return EXIT_SUCCESS;
    bool process_tree_confirmed_stopped = true;
    std::wstring notice_after_mutex_release;
    const DWORD exit_code = RunSupervisedApplication(
        command_line_arguments, &process_tree_confirmed_stopped,
        &notice_after_mutex_release);
    if (!yixue::runner::CanReleaseSingleInstanceMutex(
            process_tree_confirmed_stopped)) {
      yixue::runner::diagnostics::Log(
          "supervisor_lock_retained_without_tree_confirmation",
          ERROR_PROCESS_ABORTED);
      ::MessageBoxW(
          nullptr,
          L"Windows 尚未确认译学及其子进程全部退出。为防止数据库并发访问，启动器会继续保持单实例锁；此时再次启动会被阻止。",
          L"译学仍在收尾", MB_OK | MB_ICONWARNING);
      for (;;) ::Sleep(1000);
    }
    CloseRecoveryCandidateMarker();
    CloseSingleInstanceMutex();
    if (!notice_after_mutex_release.empty()) {
      ::MessageBoxW(nullptr, notice_after_mutex_release.c_str(),
                    L"\u8BD1\u5B66\u8FDB\u7A0B\u5DF2\u6536\u5C3E",
                    MB_OK | MB_ICONWARNING);
    }
    return static_cast<int>(exit_code);
  }
  if (!subtitle_process && supervised_ui) {
    const auto event_name = ReadSupervisorEventArgument(command_line_arguments);
    const auto app_ready_event_name =
        ReadSupervisorAppReadyEventArgument(command_line_arguments);
    if (!event_name.has_value() || !app_ready_event_name.has_value()) {
      ShowSupervisorError(
          L"\u76D1\u7763\u5173\u95ED\u6216\u542F\u52A8\u5C31\u7EEA\u901A\u77E5\u7F3A\u5931\uFF0C\u4E3A\u4FDD\u62A4\u5A92\u4F53\u8D44\u6E90\u4E0D\u4F1A\u542F\u52A8\u3002",
          ERROR_INVALID_PARAMETER);
      return EXIT_FAILURE;
    }
    yixue::runner::diagnostics::Log("supervised_ui_open_event_begin");
    g_supervisor_close_event =
        ::OpenEventW(EVENT_MODIFY_STATE, FALSE, event_name->c_str());
    if (g_supervisor_close_event == nullptr) {
      yixue::runner::diagnostics::Log("supervised_ui_open_event_failed",
                                      ::GetLastError());
      ShowSupervisorError(
          L"\u76D1\u7763\u8FDB\u7A0B\u5DF2\u9000\u51FA\uFF0C\u672A\u542F\u52A8\u5A92\u4F53\u4F1A\u8BDD\u3002",
          ::GetLastError());
      return EXIT_FAILURE;
    }
    yixue::runner::diagnostics::Log("supervised_ui_open_event_succeeded");
    g_supervisor_app_ready_event =
        ::OpenEventW(EVENT_MODIFY_STATE, FALSE, app_ready_event_name->c_str());
    if (g_supervisor_app_ready_event == nullptr) {
      const DWORD error = ::GetLastError();
      yixue::runner::diagnostics::Log(
          "supervised_ui_open_app_ready_event_failed", error);
      ::CloseHandle(g_supervisor_close_event);
      g_supervisor_close_event = nullptr;
      ShowSupervisorError(
          L"\u65E0\u6CD5\u901A\u77E5\u76D1\u7763\u7A0B\u5E8F\u4E3B\u7A97\u5DF2\u5B8C\u6210\u521D\u59CB\u5316\u3002",
          error);
      return EXIT_FAILURE;
    }
    yixue::runner::diagnostics::Log("supervised_ui_open_app_ready_event_succeeded");
    g_single_instance_mutex =
        ::OpenMutexW(SYNCHRONIZE, FALSE, kSingleInstanceMutexName);
    if (g_single_instance_mutex == nullptr) {
      const DWORD error = ::GetLastError();
      yixue::runner::diagnostics::Log("supervised_ui_open_mutex_failed",
                                      error);
      ::CloseHandle(g_supervisor_close_event);
      g_supervisor_close_event = nullptr;
      CloseSupervisorAppReadyEvent();
      ShowSupervisorError(
          L"\u65E0\u6CD5\u4FDD\u6301\u8BD1\u5B66\u5355\u5B9E\u4F8B\u4FDD\u62A4\u3002",
          error);
      return EXIT_FAILURE;
    }
    yixue::runner::diagnostics::Log("supervised_ui_open_mutex_succeeded");
    DWORD closing_event_error = ERROR_SUCCESS;
    if (!CreateSupervisorClosingEvent(&closing_event_error)) {
      if (g_supervisor_close_event != nullptr) {
        ::CloseHandle(g_supervisor_close_event);
        g_supervisor_close_event = nullptr;
      }
      CloseSupervisorAppReadyEvent();
      ::CloseHandle(g_single_instance_mutex);
      g_single_instance_mutex = nullptr;
      ShowSupervisorError(
          L"无法创建旧实例正常关闭状态标记。为避免误结束已有进程，本次启动已取消。",
          closing_event_error == ERROR_SUCCESS ? ERROR_GEN_FAILURE
                                               : closing_event_error);
      return EXIT_FAILURE;
    }
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  const HRESULT com_result =
      ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const bool com_initialized = SUCCEEDED(com_result);
  if (!subtitle_process) {
    yixue::runner::diagnostics::Log(
        "main_com_initialize_result", static_cast<DWORD>(com_result));
  }

  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments(
      supervised_ui ? FilterSupervisorArguments(command_line_arguments)
                    : std::move(command_line_arguments));

  FlutterWindow window(project, subtitle_process, supervised_ui);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  const wchar_t* title = kMainWindowTitle;
  if (subtitle_process) {
    title = kSubtitleWindowTitle;
    // Match the first Flutter view size used by subtitle_window_runtime.dart.
    // Resizing immediately after engine startup recreates the Flutter surface
    // during the child window's first frame and can destabilize the renderer.
    size = Win32Window::Size(1000, 180);
  }
  if (!subtitle_process) {
    yixue::runner::diagnostics::Log("main_window_create_begin");
  }
  if (!window.Create(title, origin, size)) {
    if (!subtitle_process) {
      yixue::runner::diagnostics::Log("main_window_create_failed",
                                      ERROR_GEN_FAILURE);
    }
    if (com_initialized) ::CoUninitialize();
    if (g_supervisor_close_event != nullptr) {
      ::CloseHandle(g_supervisor_close_event);
      g_supervisor_close_event = nullptr;
    }
    CloseSupervisorClosingEvent();
    CloseSupervisorAppReadyEvent();
    if (g_single_instance_mutex != nullptr) {
      ::CloseHandle(g_single_instance_mutex);
      g_single_instance_mutex = nullptr;
    }
    return EXIT_FAILURE;
  }
  // Flutter or a native plugin may install its own process filter while the
  // engine starts. Reinstall the privacy-safe recorder for runtime failures.
  ::SetUnhandledExceptionFilter(
      &yixue::runner::diagnostics::CaptureUnhandledException);
  window.SetQuitOnClose(true);
  // A direct UI keeps a local final-resort watchdog. The supervised UI leaves
  // forced termination to its parent, which asks the user after the grace
  // period and respects the choice to keep waiting.
  UiCleanupWatchdog cleanup_watchdog(
      yixue::runner::ShouldUseLocalUiCleanupWatchdog(supervised_ui));
  if (!subtitle_process) {
    yixue::runner::diagnostics::Log("main_window_created");
    yixue::runner::diagnostics::Log("supervised_ui_waiting_for_dart_app_ready");
    yixue::runner::diagnostics::Log("main_message_loop_begin");
  }

  ::MSG msg;
  int message_loop_exit_code = EXIT_SUCCESS;
  for (;;) {
    const int get_message_result =
        static_cast<int>(::GetMessage(&msg, nullptr, 0, 0));
    const auto disposition =
        yixue::runner::DecideMessageLoopDisposition(get_message_result);
    if (disposition ==
        yixue::runner::MessageLoopDisposition::kExitNormally) {
      if (!subtitle_process) {
        yixue::runner::diagnostics::Log(
            "main_message_loop_quit", static_cast<DWORD>(msg.wParam));
      }
      break;
    }
    if (disposition ==
        yixue::runner::MessageLoopDisposition::kReportFailure) {
      DWORD error = ::GetLastError();
      if (error == ERROR_SUCCESS) error = ERROR_GEN_FAILURE;
      message_loop_exit_code = static_cast<int>(error);
      if (!subtitle_process) {
        yixue::runner::diagnostics::Log(
            "main_message_loop_getmessage_failed", error);
      }
      yixue::runner::SignalParentSupervisorCloseRequest();
      break;
    }
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // Keep the Flutter engine alive until any method-channel callback that
  // initiated WM_DESTROY has returned to the message loop.
  yixue::runner::SignalUiCleanupWatchdogStart();
  if (!subtitle_process) {
    yixue::runner::diagnostics::Log("main_cleanup_after_loop_begin",
                                    static_cast<DWORD>(message_loop_exit_code));
  }
  if (cleanup_watchdog.startup_failed()) {
    // Native teardown must remain bounded even when the watchdog thread could
    // not be allocated. At this point the app is already closing; keep any
    // partial recording for recovery and release the process/database lock.
    yixue::runner::diagnostics::Log("main_cleanup_watchdog_start_failed",
                                    ERROR_NOT_ENOUGH_MEMORY);
    TerminateHungUiCleanup();
  }
  window.CleanupAfterMessageLoop();
  if (window.must_exit_process_after_cleanup()) {
    if (yixue::runner::ShouldDeferHungUiCleanupToSupervisor(supervised_ui)) {
      yixue::runner::diagnostics::Log(
          "main_cleanup_waiting_for_supervisor_user_decision", ERROR_TIMEOUT);
      // Keep FlutterWindow and native media owners alive. The parent will ask
      // after its grace period and can terminate the whole job if the user
      // explicitly chooses force-close.
      for (;;) ::Sleep(1000);
    }
    if (!subtitle_process) {
      yixue::runner::diagnostics::Log(
          "main_cleanup_forced_process_exit", ERROR_TIMEOUT);
    }
    TerminateHungUiCleanup();
  }
  if (!cleanup_watchdog.Complete()) {
    TerminateHungUiCleanup();
  }
  if (!subtitle_process) {
    yixue::runner::diagnostics::Log("main_cleanup_after_loop_end");
  }
  if (com_initialized) ::CoUninitialize();
  if (g_supervisor_close_event != nullptr) {
    ::CloseHandle(g_supervisor_close_event);
    g_supervisor_close_event = nullptr;
  }
  CloseSupervisorClosingEvent();
  CloseSupervisorAppReadyEvent();
  if (g_single_instance_mutex != nullptr) {
    ::CloseHandle(g_single_instance_mutex);
    g_single_instance_mutex = nullptr;
  }
  if (!subtitle_process) {
    yixue::runner::diagnostics::Log("main_process_return",
                                    static_cast<DWORD>(message_loop_exit_code));
  }
  if (message_loop_exit_code != EXIT_SUCCESS) {
    ShowSupervisorError(
        L"\u8BD1\u5B66\u7A97\u53E3\u6D88\u606F\u5FAA\u73AF\u9047\u5230\u9519\u8BEF\uFF0C\u7A0B\u5E8F\u5DF2\u6267\u884C\u6E05\u7406\u5E76\u901A\u77E5\u76D1\u7763\u8FDB\u7A0B\u3002",
        static_cast<DWORD>(message_loop_exit_code));
  }
  return message_loop_exit_code;
}
