#ifndef RUNNER_WASAPI_AUDIO_CALLBACK_BOUNDARY_H_
#define RUNNER_WASAPI_AUDIO_CALLBACK_BOUNDARY_H_

#include <exception>
#include <utility>

namespace yixue::runner {

template <typename Operation, typename ExceptionHandler>
bool RunWasapiAudioPluginCallbackSafely(Operation&& operation,
                                       ExceptionHandler&& exception_handler) noexcept {
  try {
    std::forward<Operation>(operation)();
    return true;
  } catch (...) {
    try {
      std::forward<ExceptionHandler>(exception_handler)(
          std::current_exception());
    } catch (...) {
      // Error reporting must not escape a native callback boundary either.
    }
    return false;
  }
}

class NativeMethodReplyGate final {
 public:
  bool TryBeginReply() noexcept {
    if (reply_started_) return false;
    reply_started_ = true;
    return true;
  }

 private:
  bool reply_started_ = false;
};

}  // namespace yixue::runner

#endif  // RUNNER_WASAPI_AUDIO_CALLBACK_BOUNDARY_H_
