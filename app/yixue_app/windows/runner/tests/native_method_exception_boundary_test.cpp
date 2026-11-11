#include "native_method_exception_boundary.h"

#include <exception>
#include <stdexcept>

int main() {
  bool handler_called = false;
  const bool success = yixue::runner::RunNativeOperationSafely(
      [] {}, [&handler_called](std::exception_ptr) { handler_called = true; });
  if (!success || handler_called) return 1;

  bool expected_exception_received = false;
  const bool failed = yixue::runner::RunNativeOperationSafely(
      [] { throw std::runtime_error("injected native failure"); },
      [&expected_exception_received](std::exception_ptr exception) {
        try {
          std::rethrow_exception(exception);
        } catch (const std::runtime_error&) {
          expected_exception_received = true;
        }
      });
  if (failed || !expected_exception_received) return 2;

  const bool handler_failure_is_contained =
      yixue::runner::RunNativeOperationSafely(
          [] { throw std::runtime_error("injected native failure"); },
          [](std::exception_ptr) {
            throw std::runtime_error("injected reporting failure");
          });
  if (handler_failure_is_contained) return 3;
  return 0;
}
