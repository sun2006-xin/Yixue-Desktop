#include "../screen_capture_completion_drain.h"
#include "../screen_capture_completion_once.h"

#include <iostream>
#include <vector>

namespace {

int TestClosedPosterQueueDiscardsEveryQueuedCompletion() {
  int discard_calls = 0;
  int dispatch_calls = 0;
  std::vector<LPARAM> queued;
  queued.push_back(reinterpret_cast<LPARAM>(
      new yixue::runner::PendingScreenCaptureCompletion{
          [&] { ++dispatch_calls; }, [&] { ++discard_calls; }}));
  queued.push_back(reinterpret_cast<LPARAM>(
      new yixue::runner::PendingScreenCaptureCompletion{
          [&] { ++dispatch_calls; }, [&] { ++discard_calls; }}));

  const auto discarded = yixue::runner::DiscardPendingScreenCaptureCompletions(
      [&queued](LPARAM* payload) {
        if (queued.empty()) return false;
        *payload = queued.front();
        queued.erase(queued.begin());
        return true;
      });

  if (discarded != 2 || discard_calls != 2 || dispatch_calls != 0 ||
      !queued.empty()) {
    return 10;
  }
  return 0;
}

int TestFailedPostResetsStateAndRepliesExactlyOnce() {
  yixue::runner::ScreenCaptureCompletionReply start_failure_claim;
  yixue::runner::ScreenCaptureCompletionReply start_method_reply;
  int start_state = 1;
  int start_reply_count = 0;
  const auto handle_start_failure = [&] {
    start_state = 0;
    start_method_reply.InvokeOnce([&] { ++start_reply_count; });
  };

  if (!yixue::runner::RunScreenCapturePostFailureOnce(
          false, start_failure_claim, handle_start_failure) ||
      start_state != 0 || start_reply_count != 1) {
    return 20;
  }
  if (yixue::runner::RunScreenCapturePostFailureOnce(
          false, start_failure_claim, handle_start_failure) ||
      start_reply_count != 1) {
    return 21;
  }

  yixue::runner::ScreenCaptureCompletionReply stop_failure_claim;
  yixue::runner::ScreenCaptureCompletionReply stop_method_reply;
  int stop_state = 2;
  int stop_reply_count = 0;
  const auto handle_stop_failure = [&] {
    stop_state = 0;
    stop_method_reply.InvokeOnce([&] { ++stop_reply_count; });
  };
  if (!yixue::runner::RunScreenCapturePostFailureOnce(
          false, stop_failure_claim, handle_stop_failure) ||
      stop_state != 0 || stop_reply_count != 1) {
    return 22;
  }
  if (yixue::runner::RunScreenCapturePostFailureOnce(
          false, stop_failure_claim, handle_stop_failure) ||
      stop_reply_count != 1) {
    return 23;
  }
  return 0;
}

}  // namespace

int main() {
  if (const int result = TestClosedPosterQueueDiscardsEveryQueuedCompletion()) {
    return result;
  }
  if (const int result = TestFailedPostResetsStateAndRepliesExactlyOnce()) {
    return result;
  }
  std::cout << "PASS: queued UI completions are discarded exactly once on close\n";
  std::cout << "PASS: failed completion posts reset state and reply once\n";
  return 0;
}
