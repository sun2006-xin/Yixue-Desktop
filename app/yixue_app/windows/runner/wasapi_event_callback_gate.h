#ifndef RUNNER_WASAPI_EVENT_CALLBACK_GATE_H_
#define RUNNER_WASAPI_EVENT_CALLBACK_GATE_H_

#include <functional>
#include <memory>
#include <mutex>
#include <utility>

// A capture worker takes a shared snapshot of the callback and invokes it
// without holding the gate lock. Disabling a callback is therefore bounded
// even when an in-flight callback is slow. Callback targets that reference
// shorter-lived owners must use weak/shared state rather than raw `this`.
template <typename Event>
class WasapiEventCallbackGate {
 public:
  using EventCallback = std::function<bool(Event event, bool is_audio_frame)>;

  explicit WasapiEventCallbackGate(EventCallback callback)
      : callback_(std::make_shared<EventCallback>(std::move(callback))) {}

  WasapiEventCallbackGate(const WasapiEventCallbackGate&) = delete;
  WasapiEventCallbackGate& operator=(const WasapiEventCallbackGate&) = delete;

  bool Dispatch(Event event, bool is_audio_frame) noexcept {
    std::shared_ptr<EventCallback> callback;
    try {
      std::lock_guard<std::mutex> lock(mutex_);
      callback = callback_;
    } catch (...) {
      return false;
    }
    if (!callback || !*callback) return false;
    try {
      return (*callback)(std::move(event), is_audio_frame);
    } catch (...) {
      return false;
    }
  }

  void Disable() noexcept {
    std::shared_ptr<EventCallback> disabled;
    try {
      std::lock_guard<std::mutex> lock(mutex_);
      disabled.swap(callback_);
    } catch (...) {
      // If the lock itself fails, keep the callback owner alive. The capture
      // retirement path will also keep the worker's parent alive.
    }
  }

 private:
  std::mutex mutex_;
  std::shared_ptr<EventCallback> callback_;
};

#endif  // RUNNER_WASAPI_EVENT_CALLBACK_GATE_H_
