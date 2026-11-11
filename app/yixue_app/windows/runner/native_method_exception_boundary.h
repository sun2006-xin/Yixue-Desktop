#ifndef RUNNER_NATIVE_METHOD_EXCEPTION_BOUNDARY_H_
#define RUNNER_NATIVE_METHOD_EXCEPTION_BOUNDARY_H_

#include <exception>
#include <utility>

namespace yixue::runner {

// Flutter's Windows method-channel callback is not an exception boundary.
// Convert native failures into method results before returning to the engine.
template <typename Operation, typename ExceptionHandler>
bool RunNativeOperationSafely(Operation&& operation,
                              ExceptionHandler&& exception_handler) noexcept {
  try {
    std::forward<Operation>(operation)();
    return true;
  } catch (...) {
    try {
      std::forward<ExceptionHandler>(exception_handler)(
          std::current_exception());
    } catch (...) {
      // An error-reporting failure must not escape the native callback either.
    }
    return false;
  }
}

}  // namespace yixue::runner

#endif  // RUNNER_NATIVE_METHOD_EXCEPTION_BOUNDARY_H_
