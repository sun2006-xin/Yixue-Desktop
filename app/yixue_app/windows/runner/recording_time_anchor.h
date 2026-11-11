#pragma once

#include <cstdint>
#include <string>

// QPC timestamps and their recording origin are represented in 100 ns units.
// Keeping this predicate platform independent lets the production recorder
// and its focused boundary test share exactly the same rule.
inline bool IsQpcAtOrAfterRecordingOrigin(int64_t timestamp_100ns,
                                          int64_t origin_100ns) noexcept {
  return timestamp_100ns > 0 && origin_100ns > 0 &&
         timestamp_100ns >= origin_100ns;
}

inline bool IsMatchingAudioCaptureIdentity(
    const std::string& frame_session_id,
    const std::string& frame_source_id,
    const std::string& frame_capture_attempt_id,
    const std::string& recording_session_id,
    const std::string& recording_source_id,
    const std::string& recording_capture_attempt_id) {
  return frame_session_id == recording_session_id &&
         frame_source_id == recording_source_id &&
         frame_capture_attempt_id == recording_capture_attempt_id;
}
