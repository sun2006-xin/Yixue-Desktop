#ifndef RUNNER_WINDOWS_SCREEN_RECORDING_PLUGIN_H_
#define RUNNER_WINDOWS_SCREEN_RECORDING_PLUGIN_H_

#include <flutter/plugin_registry.h>

#include <windows.h>

#include <memory>

namespace yixue::runner {
class ScreenRecordingReplyGate;
}

void RegisterWindowsScreenRecordingPlugin(flutter::PluginRegistry* registry,
                                          HWND owner_window,
                                          std::shared_ptr<yixue::runner::ScreenRecordingReplyGate>
                                              reply_gate);

#endif  // RUNNER_WINDOWS_SCREEN_RECORDING_PLUGIN_H_
