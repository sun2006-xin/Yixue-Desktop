#ifndef YIXUE_RUNNER_RECORDING_FILENAME_POLICY_H_
#define YIXUE_RUNNER_RECORDING_FILENAME_POLICY_H_

#include <cstddef>
#include <string>

namespace yixue::runner {

inline std::wstring SessionIdFilenameToken(const std::string& session_id) {
  constexpr char kAudioOnlyPrefix[] = "audio-only-";
  constexpr std::size_t kAudioOnlyPrefixLength = sizeof(kAudioOnlyPrefix) - 1;
  const bool audio_only =
      session_id.compare(0, kAudioOnlyPrefixLength, kAudioOnlyPrefix) == 0;
  const std::size_t uuid_offset = audio_only ? kAudioOnlyPrefixLength : 0;
  if (session_id.size() != uuid_offset + 36) return {};

  std::wstring token;
  token.reserve(session_id.size());
  if (audio_only) token.append(L"audio-only-");
  for (std::size_t index = 0; index < 36; ++index) {
    const char value = session_id[uuid_offset + index];
    const bool separator = index == 8 || index == 13 || index == 18 || index == 23;
    if (separator) {
      if (value != '-') return {};
      token.push_back(L'-');
      continue;
    }
    const bool hexadecimal = (value >= '0' && value <= '9') ||
                             (value >= 'a' && value <= 'f') ||
                             (value >= 'A' && value <= 'F');
    if (!hexadecimal) return {};
    token.push_back(static_cast<wchar_t>(value >= 'A' && value <= 'F'
                                             ? value - 'A' + 'a'
                                             : value));
  }
  return token;
}

}  // namespace yixue::runner

#endif  // YIXUE_RUNNER_RECORDING_FILENAME_POLICY_H_
