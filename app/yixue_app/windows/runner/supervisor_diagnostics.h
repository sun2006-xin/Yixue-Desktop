#ifndef RUNNER_SUPERVISOR_DIAGNOSTICS_H_
#define RUNNER_SUPERVISOR_DIAGNOSTICS_H_

#include <windows.h>

#include <cstdio>
#include <cstdint>
#include <string>
#include <vector>

namespace yixue::runner::diagnostics {

inline HANDLE OpenLogFile() noexcept {
  try {
    const DWORD required =
        ::GetEnvironmentVariableW(L"YIXUE_DATA_DIR", nullptr, 0);
    if (required <= 1 || required > 32768) return INVALID_HANDLE_VALUE;

    std::vector<wchar_t> data_directory(required, L'\0');
    const DWORD directory_length = ::GetEnvironmentVariableW(
        L"YIXUE_DATA_DIR", data_directory.data(), required);
    if (directory_length == 0 || directory_length >= required) {
      return INVALID_HANDLE_VALUE;
    }

    std::wstring log_directory(data_directory.data(), directory_length);
    if (!log_directory.empty() && log_directory.back() != L'\\' &&
        log_directory.back() != L'/') {
      log_directory.push_back(L'\\');
    }
    log_directory += L"diagnostics";
    if (!::CreateDirectoryW(log_directory.c_str(), nullptr) &&
        ::GetLastError() != ERROR_ALREADY_EXISTS) {
      return INVALID_HANDLE_VALUE;
    }
    log_directory += L"\\windows-lifecycle.log";

    return ::CreateFileW(
        log_directory.c_str(), FILE_APPEND_DATA,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  } catch (...) {
    return INVALID_HANDLE_VALUE;
  }
}

// Lifecycle diagnostics contain process and module metadata only. The module
// value is a basename, never a full user path; media, subtitles, and user
// content are never written to this file.
inline void Log(const char* event, DWORD detail = 0) noexcept {
  if (event == nullptr) return;
  try {
    HANDLE file = OpenLogFile();
    if (file == INVALID_HANDLE_VALUE) return;

    SYSTEMTIME now = {};
    ::GetLocalTime(&now);
    char line[512] = {};
    const int line_length = ::sprintf_s(
        line, sizeof(line),
        "%04u-%02u-%02uT%02u:%02u:%02u.%03u pid=%lu tid=%lu event=%s detail=%lu\r\n",
        now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond,
        now.wMilliseconds, ::GetCurrentProcessId(), ::GetCurrentThreadId(),
        event, detail);
    if (line_length > 0) {
      DWORD written = 0;
      ::WriteFile(file, line, static_cast<DWORD>(line_length), &written,
                  nullptr);
    }
    ::CloseHandle(file);
  } catch (...) {
    // Diagnostics must never interfere with startup or teardown.
  }
}

inline void LogText(const char* event, const char* value) noexcept {
  if (event == nullptr || value == nullptr) return;
  try {
    HANDLE file = OpenLogFile();
    if (file == INVALID_HANDLE_VALUE) return;

    SYSTEMTIME now = {};
    ::GetLocalTime(&now);
    char line[512] = {};
    const int line_length = ::sprintf_s(
        line, sizeof(line),
        "%04u-%02u-%02uT%02u:%02u:%02u.%03u pid=%lu tid=%lu event=%s value=%s\r\n",
        now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond,
        now.wMilliseconds, ::GetCurrentProcessId(), ::GetCurrentThreadId(),
        event, value);
    if (line_length > 0) {
      DWORD written = 0;
      ::WriteFile(file, line, static_cast<DWORD>(line_length), &written,
                  nullptr);
    }
    ::CloseHandle(file);
  } catch (...) {
    // Diagnostics must never interfere with startup or teardown.
  }
}

inline LONG WINAPI CaptureUnhandledException(
    EXCEPTION_POINTERS* exception_info) noexcept {
  const DWORD exception_code =
      exception_info != nullptr && exception_info->ExceptionRecord != nullptr
          ? exception_info->ExceptionRecord->ExceptionCode
          : ERROR_GEN_FAILURE;
  Log("unhandled_seh_exception", exception_code);
  if (exception_info != nullptr && exception_info->ExceptionRecord != nullptr) {
    const auto exception_address =
        exception_info->ExceptionRecord->ExceptionAddress;
    const auto address =
        reinterpret_cast<std::uintptr_t>(exception_address);
    Log("unhandled_seh_address_low",
        static_cast<DWORD>(address & 0xFFFFFFFFULL));
    Log("unhandled_seh_address_high",
        static_cast<DWORD>(address >> 32U));
    HMODULE module = nullptr;
    if (::GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(exception_address), &module)) {
      wchar_t module_path[MAX_PATH] = {};
      const DWORD path_length =
          ::GetModuleFileNameW(module, module_path, MAX_PATH);
      if (path_length > 0 && path_length < static_cast<DWORD>(MAX_PATH)) {
        const wchar_t* module_name = module_path + path_length;
        while (module_name > module_path && module_name[-1] != L'\\' &&
               module_name[-1] != L'/') {
          --module_name;
        }
        char utf8_module_name[256] = {};
        if (::WideCharToMultiByte(CP_UTF8, 0, module_name, -1,
                                  utf8_module_name,
                                  static_cast<int>(sizeof(utf8_module_name)),
                                  nullptr, nullptr) > 0) {
          LogText("unhandled_seh_module", utf8_module_name);
        }
      }
      const auto module_base = reinterpret_cast<std::uintptr_t>(module);
      const auto relative_address = address - module_base;
      Log("unhandled_seh_module_rva_low",
          static_cast<DWORD>(relative_address & 0xFFFFFFFFULL));
      Log("unhandled_seh_module_rva_high",
          static_cast<DWORD>(relative_address >> 32U));
    } else {
      Log("unhandled_seh_module_unknown");
    }
  }
  return EXCEPTION_EXECUTE_HANDLER;
}

}  // namespace yixue::runner::diagnostics

#endif  // RUNNER_SUPERVISOR_DIAGNOSTICS_H_
