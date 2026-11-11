#include "yixue_ct2_runtime.h"

#include <cstdlib>
#include <iostream>
#include <string>

#include <nlohmann/json.hpp>

namespace {

using json = nlohmann::json;

constexpr std::size_t kMaximumProtocolBytes = 1024 * 1024;
constexpr std::size_t kMaximumTextBytes = 50000;
constexpr int kSchemaVersion = 1;

enum class ReadResult { kLine, kTooLarge, kEnd };

ReadResult read_bounded_line(std::string& line) {
  line.clear();
  bool too_large = false;
  char value = '\0';
  while (std::cin.get(value)) {
    if (value == '\n') {
      return too_large ? ReadResult::kTooLarge : ReadResult::kLine;
    }
    if (value == '\r') {
      continue;
    }
    if (line.size() < kMaximumProtocolBytes) {
      line.push_back(value);
    } else {
      too_large = true;
    }
  }
  if (too_large) {
    return ReadResult::kTooLarge;
  }
  return line.empty() ? ReadResult::kEnd : ReadResult::kLine;
}

void send(const json& response) {
  std::cout << response.dump(-1, ' ', false, json::error_handler_t::replace)
            << '\n'
            << std::flush;
}

json error_response(const json& id, const char* code, const char* message) {
  return {
      {"schema_version", kSchemaVersion},
      {"id", id},
      {"ok", false},
      {"code", code},
      {"message", message},
  };
}

bool valid_id(const json& id) {
  return id.is_string() && !id.get_ref<const std::string&>().empty() &&
         id.get_ref<const std::string&>().size() <= 128;
}

}  // namespace

int main() {
  std::ios::sync_with_stdio(false);
  YixueCt2Runtime* runtime = nullptr;
  std::string line;

  while (true) {
    const auto read_result = read_bounded_line(line);
    if (read_result == ReadResult::kEnd) {
      std::_Exit(0);
    }
    if (read_result == ReadResult::kTooLarge) {
      send(error_response(nullptr, "request_too_large",
                          "The worker request is too large"));
      continue;
    }

    json request;
    try {
      request = json::parse(line);
    } catch (...) {
      send(error_response(nullptr, "invalid_json",
                          "The worker request is not valid JSON"));
      continue;
    }

    if (!request.is_object()) {
      send(error_response(nullptr, "invalid_request",
                          "The worker request must be an object"));
      continue;
    }

    const json id = request.contains("id") ? request["id"] : json(nullptr);
    if (!request.contains("schema_version") ||
        !request["schema_version"].is_number_integer() ||
        request["schema_version"] != kSchemaVersion ||
        !valid_id(id) || !request.contains("command") ||
        !request["command"].is_string()) {
      send(error_response(id, "invalid_request",
                          "The worker request is incomplete"));
      continue;
    }

    const std::string command = request["command"].get<std::string>();
    if (command == "open") {
      if (runtime != nullptr) {
        send(error_response(id, "model_already_open",
                            "A translation model is already open"));
        continue;
      }
      if (!request.contains("model_path") || !request["model_path"].is_string() ||
          request["model_path"].get_ref<const std::string&>().empty()) {
        send(error_response(id, "invalid_model_path",
                            "The verified model path is required"));
        continue;
      }
      char* native_error = nullptr;
      runtime = yixue_ct2_open(
          request["model_path"].get_ref<const std::string&>().c_str(),
          &native_error);
      yixue_ct2_string_free(native_error);
      if (runtime == nullptr) {
        send(error_response(id, "model_open_failed",
                            "The verified translation model could not be opened"));
        continue;
      }
      send({{"schema_version", kSchemaVersion},
            {"id", id},
            {"ok", true},
            {"ready", true}});
      continue;
    }

    if (command == "translate") {
      if (runtime == nullptr) {
        send(error_response(id, "model_not_open",
                            "Open a verified translation model first"));
        continue;
      }
      if (!request.contains("text") || !request["text"].is_string() ||
          request["text"].get_ref<const std::string&>().empty()) {
        send(error_response(id, "invalid_text", "Translation text is required"));
        continue;
      }
      const auto& text = request["text"].get_ref<const std::string&>();
      if (text.size() > kMaximumTextBytes) {
        send(error_response(id, "text_too_large",
                            "Translation text exceeds the local limit"));
        continue;
      }
      char* native_error = nullptr;
      char* translated = yixue_ct2_translate(runtime, text.c_str(), &native_error);
      yixue_ct2_string_free(native_error);
      if (translated == nullptr) {
        send(error_response(id, "translation_failed",
                            "The local translation model could not translate this text"));
        continue;
      }
      const std::string result(translated);
      yixue_ct2_string_free(translated);
      send({{"schema_version", kSchemaVersion},
            {"id", id},
            {"ok", true},
            {"translation", result}});
      continue;
    }

    send(error_response(id, "unknown_command",
                        "The worker command is not supported"));
  }
}
