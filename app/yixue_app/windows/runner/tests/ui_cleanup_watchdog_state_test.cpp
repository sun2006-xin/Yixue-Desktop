#include "ui_cleanup_watchdog_state.h"

#include <atomic>
#include <thread>

int main() {
  using yixue::runner::UiCleanupWatchdogState;
  using yixue::runner::UiCleanupWatchdogStatus;

  UiCleanupWatchdogState dormant;
  if (dormant.status() != UiCleanupWatchdogStatus::kDormant) return 1;
  if (dormant.TryMarkExpired()) return 2;
  if (!dormant.TryStart()) return 3;
  if (dormant.TryStart()) return 4;

  UiCleanupWatchdogState completed;
  if (!completed.TryStart()) return 5;
  if (!completed.TryMarkCompleted()) return 6;
  if (completed.status() != UiCleanupWatchdogStatus::kCompleted) return 7;
  if (completed.TryMarkExpired()) return 8;

  UiCleanupWatchdogState expired;
  if (!expired.TryStart()) return 9;
  if (!expired.TryMarkExpired()) return 10;
  if (expired.status() != UiCleanupWatchdogStatus::kExpired) return 11;
  if (expired.TryMarkCompleted()) return 12;

  for (int iteration = 0; iteration < 128; ++iteration) {
    UiCleanupWatchdogState raced;
    if (!raced.TryStart()) return 13;
    std::atomic<int> ready{0};
    std::atomic<bool> release{false};
    std::atomic<int> terminal_transitions{0};
    std::thread complete([&] {
      ready.fetch_add(1, std::memory_order_relaxed);
      while (!release.load(std::memory_order_acquire)) {
        std::this_thread::yield();
      }
      if (raced.TryMarkCompleted()) {
        terminal_transitions.fetch_add(1, std::memory_order_relaxed);
      }
    });
    std::thread expire([&] {
      ready.fetch_add(1, std::memory_order_relaxed);
      while (!release.load(std::memory_order_acquire)) {
        std::this_thread::yield();
      }
      if (raced.TryMarkExpired()) {
        terminal_transitions.fetch_add(1, std::memory_order_relaxed);
      }
    });
    while (ready.load(std::memory_order_acquire) != 2) {
      std::this_thread::yield();
    }
    release.store(true, std::memory_order_release);
    complete.join();
    expire.join();
    if (terminal_transitions.load(std::memory_order_relaxed) != 1) return 14;
    const auto terminal = raced.status();
    if (terminal != UiCleanupWatchdogStatus::kCompleted &&
        terminal != UiCleanupWatchdogStatus::kExpired) {
      return 15;
    }
  }
  return 0;
}
