#ifndef RUNNER_RECORDING_PUBLICATION_POLICY_H_
#define RUNNER_RECORDING_PUBLICATION_POLICY_H_

#include <cstdint>
#include <cwctype>
#include <filesystem>
#include <system_error>
#include <string_view>

namespace yixue::runner {

// A finalized container is not a screen recording unless it contains at least
// one successfully written video sample. Audio samples alone are insufficient.
constexpr bool CanPublishScreenRecording(
    std::uint64_t video_frames_written) noexcept {
  return video_frames_written > 0;
}

// Failed recording startup must keep the already-created file recognizable
// to SubtitleVideoRecordingIndex, which lists .partial.mp4 files as protected
// recovery entries without attempting playback.
inline bool ShouldRetainPartialScreenRecording(
    const std::filesystem::path& path) noexcept {
  try {
    const std::wstring filename = path.filename().wstring();
    constexpr std::wstring_view suffix = L".partial.mp4";
    if (filename.size() < suffix.size()) return false;
    const auto candidate =
        std::wstring_view(filename).substr(filename.size() - suffix.size());
    for (std::size_t index = 0; index < suffix.size(); ++index) {
      if (std::towlower(candidate[index]) != suffix[index]) return false;
    }
    return true;
  } catch (...) {
    return false;
  }
}

// Startup failures should leave .partial.mp4 visible to the existing history
// recovery flow. Other temporary paths retain the previous cleanup behavior.
[[nodiscard]] inline bool RemoveFailedScreenRecordingFile(
    const std::filesystem::path& path,
    std::error_code* error = nullptr) noexcept {
  if (error != nullptr) error->clear();
  if (ShouldRetainPartialScreenRecording(path)) return false;
  try {
    std::error_code remove_error;
    const bool removed = std::filesystem::remove(path, remove_error);
    if (error != nullptr) *error = remove_error;
    return removed;
  } catch (...) {
    if (error != nullptr) {
      *error = std::make_error_code(std::errc::not_enough_memory);
    }
    return false;
  }
}

}  // namespace yixue::runner

#endif  // RUNNER_RECORDING_PUBLICATION_POLICY_H_
