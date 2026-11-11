#ifndef RUNNER_TEXTURE_UNREGISTRATION_SAFETY_H_
#define RUNNER_TEXTURE_UNREGISTRATION_SAFETY_H_

#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>

class TextureUnregistrationCompletion {
 public:
  void Complete() noexcept {
    try {
      {
        std::lock_guard<std::mutex> lock(mutex_);
        completed_ = true;
      }
      changed_.notify_all();
    } catch (...) {
      // Do not allow an exception to cross Flutter's C callback boundary.
    }
  }

  bool WaitFor(std::chrono::milliseconds timeout) const noexcept {
    try {
      std::unique_lock<std::mutex> lock(mutex_);
      return changed_.wait_for(lock, timeout,
                               [this] { return completed_; });
    } catch (...) {
      return false;
    }
  }

  bool IsComplete() const noexcept {
    try {
      std::lock_guard<std::mutex> lock(mutex_);
      return completed_;
    } catch (...) {
      return false;
    }
  }

 private:
  mutable std::mutex mutex_;
  mutable std::condition_variable changed_;
  bool completed_ = false;
};

// Flutter owns this context after texture unregistration starts. Keeping the
// callback owner here makes a late unregister callback safe after the window
// has returned from its bounded shutdown wait.
struct TextureUnregisterCallbackContext {
  std::shared_ptr<void> keep_alive;
  std::shared_ptr<TextureUnregistrationCompletion> completion;

  static void CompleteAndRelease(void* user_data) noexcept {
    std::unique_ptr<TextureUnregisterCallbackContext> context(
        static_cast<TextureUnregisterCallbackContext*>(user_data));
    if (context != nullptr && context->completion != nullptr) {
      context->completion->Complete();
    }
  }
};

#endif  // RUNNER_TEXTURE_UNREGISTRATION_SAFETY_H_
