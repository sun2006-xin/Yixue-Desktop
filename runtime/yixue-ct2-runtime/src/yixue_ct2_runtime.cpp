#include "yixue_ct2_runtime.h"

#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include <ctranslate2/translator.h>
#include <sentencepiece_processor.h>
#include <absl/types/span.h>

namespace {

constexpr int kRuntimeAbiVersion = 1;

char* copy_string(const std::string& value) {
  auto* result = new char[value.size() + 1];
  std::memcpy(result, value.c_str(), value.size() + 1);
  return result;
}

void set_error(char** error_utf8, const std::string& message) {
  if (error_utf8 != nullptr) {
    *error_utf8 = copy_string(message);
  }
}

void clear_error(char** error_utf8) {
  if (error_utf8 != nullptr) {
    *error_utf8 = nullptr;
  }
}

void require_utf8_argument(const char* value, const char* name) {
  if (value == nullptr || value[0] == '\0') {
    throw std::invalid_argument(std::string(name) + " must not be empty");
  }
}

std::filesystem::path utf8_path(const std::string& value) {
  return std::filesystem::u8path(value);
}

std::string read_binary_file(const std::filesystem::path& path) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) {
    throw std::runtime_error("Unable to open tokenizer model: " + path.u8string());
  }
  stream.seekg(0, std::ios::end);
  const auto size = stream.tellg();
  if (size <= 0) {
    throw std::runtime_error("Tokenizer model is empty: " + path.u8string());
  }
  std::string bytes(static_cast<size_t>(size), '\0');
  stream.seekg(0, std::ios::beg);
  stream.read(bytes.data(), size);
  if (!stream) {
    throw std::runtime_error("Unable to read tokenizer model: " + path.u8string());
  }
  return bytes;
}

void load_sentencepiece(
    sentencepiece::SentencePieceProcessor& processor,
    const std::filesystem::path& path) {
  const std::string model = read_binary_file(path);
  const auto status = processor.LoadFromSerializedProto(model);
  if (!status.ok()) {
    throw std::runtime_error(
        "Unable to load tokenizer model " + path.u8string() + ": " +
        status.ToString());
  }
}

}  // namespace

struct YixueCt2Runtime {
  explicit YixueCt2Runtime(const std::string& model_dir_utf8)
      : translator(
            model_dir_utf8,
            ctranslate2::Device::CPU,
            ctranslate2::ComputeType::DEFAULT) {
    const auto model_dir = utf8_path(model_dir_utf8);
    load_sentencepiece(source_processor, model_dir / "source.spm");
    load_sentencepiece(target_processor, model_dir / "target.spm");
  }

  ctranslate2::Translator translator;
  sentencepiece::SentencePieceProcessor source_processor;
  sentencepiece::SentencePieceProcessor target_processor;
  std::mutex mutex;
};

extern "C" {

int yixue_ct2_runtime_abi_version(void) {
  return kRuntimeAbiVersion;
}

YixueCt2Runtime* yixue_ct2_open(
    const char* model_dir_utf8,
    char** error_utf8) {
  clear_error(error_utf8);
  try {
    require_utf8_argument(model_dir_utf8, "model_dir_utf8");
    return new YixueCt2Runtime(model_dir_utf8);
  } catch (const std::exception& error) {
    set_error(error_utf8, error.what());
    return nullptr;
  } catch (...) {
    set_error(error_utf8, "Unknown error while opening the translation model");
    return nullptr;
  }
}

char* yixue_ct2_translate(
    YixueCt2Runtime* runtime,
    const char* source_utf8,
    char** error_utf8) {
  clear_error(error_utf8);
  try {
    if (runtime == nullptr) {
      throw std::invalid_argument("runtime must not be null");
    }
    require_utf8_argument(source_utf8, "source_utf8");

    std::lock_guard<std::mutex> lock(runtime->mutex);
    std::vector<std::string> source_tokens;
    const auto encode_status = runtime->source_processor.Encode(
        source_utf8, &source_tokens);
    if (!encode_status.ok()) {
      throw std::runtime_error("Unable to tokenize input: " + encode_status.ToString());
    }
    if (source_tokens.empty()) {
      throw std::runtime_error("Tokenizer produced no source tokens");
    }

    // Marian tokenizers terminate each source sequence with EOS.
    source_tokens.emplace_back("</s>");
    auto results = runtime->translator.translate_batch({source_tokens});
    if (results.size() != 1) {
      throw std::runtime_error("Translation runtime returned an invalid batch size");
    }

    std::string output;
    const auto& output_tokens = results.front().output();
    const auto decode_status = runtime->target_processor.Decode(
        absl::MakeConstSpan(output_tokens), &output);
    if (!decode_status.ok()) {
      throw std::runtime_error("Unable to decode output: " + decode_status.ToString());
    }
    if (output.empty()) {
      throw std::runtime_error("Translation runtime returned empty text");
    }
    return copy_string(output);
  } catch (const std::exception& error) {
    set_error(error_utf8, error.what());
    return nullptr;
  } catch (...) {
    set_error(error_utf8, "Unknown error while translating text");
    return nullptr;
  }
}

void yixue_ct2_close(YixueCt2Runtime* runtime) {
  delete runtime;
}

void yixue_ct2_string_free(char* value) {
  delete[] value;
}

}  // extern "C"
