#include "wasapi_audio_callback_boundary.h"

#include <exception>
#include <stdexcept>

namespace {

bool g_callback_exception_reported = false;

__declspec(noinline) void ThrowInjectedFailure() {
  throw std::runtime_error("injected native callback failure");
}

__declspec(noinline) void ReportInjectedFailure(std::exception_ptr exception) {
  try {
    std::rethrow_exception(exception);
  } catch (const std::runtime_error&) {
    g_callback_exception_reported = true;
  }
}

__declspec(noinline) void ThrowFromErrorReporter(std::exception_ptr) {
  throw std::runtime_error("injected error-reporting failure");
}

__declspec(noinline) bool TryBeginReply(
    yixue::runner::NativeMethodReplyGate* gate) {
  return gate->TryBeginReply();
}

}  // namespace

int main() {
  g_callback_exception_reported = false;
  bool callback_exception_escaped = false;
  bool callback_succeeded = true;
  try {
    callback_succeeded = yixue::runner::RunWasapiAudioPluginCallbackSafely(
        &ThrowInjectedFailure, &ReportInjectedFailure);
  } catch (...) {
    callback_exception_escaped = true;
  }
  if (callback_exception_escaped || callback_succeeded ||
      !g_callback_exception_reported) {
    return 1;
  }

  const bool reporting_exception_is_contained =
      yixue::runner::RunWasapiAudioPluginCallbackSafely(
          &ThrowInjectedFailure, &ThrowFromErrorReporter);
  if (reporting_exception_is_contained) return 2;

  yixue::runner::NativeMethodReplyGate reply_gate;
  if (!TryBeginReply(&reply_gate) || TryBeginReply(&reply_gate)) return 3;

  return 0;
}
