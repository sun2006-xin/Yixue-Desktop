#include <Windows.h>
#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdint>
#include <iostream>

using Microsoft::WRL::ComPtr;

namespace {
constexpr UINT32 kWidth = 320;
constexpr UINT32 kHeight = 240;
constexpr UINT32 kFramesPerSecond = 30;
constexpr UINT32 kFrameCount = 90;
constexpr UINT64 kFrameDuration = 10'000'000 / kFramesPerSecond;
constexpr UINT32 kAudioSampleRate = 48'000;
constexpr UINT32 kAudioChannels = 2;
constexpr UINT32 kAudioBitsPerSample = 16;
constexpr UINT32 kAudioPacketsPerSecond = 10;
constexpr UINT32 kAudioPacketSamples = kAudioSampleRate / kAudioPacketsPerSecond;
constexpr UINT64 kAudioPacketDuration = 10'000'000 / kAudioPacketsPerSecond;

HRESULT ConfigureMediaType(IMFMediaType* type, REFGUID subtype) {
  HRESULT result = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (SUCCEEDED(result)) result = type->SetGUID(MF_MT_SUBTYPE, subtype);
  if (SUCCEEDED(result)) {
    result = MFSetAttributeSize(type, MF_MT_FRAME_SIZE, kWidth, kHeight);
  }
  if (SUCCEEDED(result)) {
    result = MFSetAttributeRatio(type, MF_MT_FRAME_RATE, kFramesPerSecond, 1);
  }
  if (SUCCEEDED(result)) {
    result = MFSetAttributeRatio(type, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  }
  if (SUCCEEDED(result)) {
    result = type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  }
  return result;
}

HRESULT WriteFrame(IMFSinkWriter* writer, DWORD streamIndex, UINT32 frameIndex) {
  ComPtr<IMFMediaBuffer> buffer;
  const DWORD bufferLength = kWidth * kHeight * 4;
  HRESULT result = MFCreateMemoryBuffer(bufferLength, &buffer);
  if (FAILED(result)) return result;

  BYTE* pixels = nullptr;
  DWORD maxLength = 0;
  DWORD currentLength = 0;
  result = buffer->Lock(&pixels, &maxLength, &currentLength);
  if (FAILED(result)) return result;

  for (UINT32 y = 0; y < kHeight; ++y) {
    for (UINT32 x = 0; x < kWidth; ++x) {
      const UINT32 band = ((x + frameIndex * 3) / 40) % 6;
      const UINT32 offset = (y * kWidth + x) * 4;
      // RGB32 is stored as B, G, R, X on little-endian Windows.
      pixels[offset + 0] = static_cast<BYTE>((band * 47 + frameIndex) & 0xff);
      pixels[offset + 1] = static_cast<BYTE>((band * 83 + y) & 0xff);
      pixels[offset + 2] = static_cast<BYTE>((band * 31 + x / 2) & 0xff);
      pixels[offset + 3] = 0xff;
    }
  }

  result = buffer->Unlock();
  if (FAILED(result)) return result;
  result = buffer->SetCurrentLength(bufferLength);
  if (FAILED(result)) return result;

  ComPtr<IMFSample> sample;
  result = MFCreateSample(&sample);
  if (FAILED(result)) return result;
  result = sample->AddBuffer(buffer.Get());
  if (FAILED(result)) return result;
  result = sample->SetSampleTime(frameIndex * kFrameDuration);
  if (FAILED(result)) return result;
  result = sample->SetSampleDuration(kFrameDuration);
  if (FAILED(result)) return result;
  return writer->WriteSample(streamIndex, sample.Get());
}

HRESULT WriteSilentAudioPacket(IMFSinkWriter* writer,
                               DWORD streamIndex,
                               UINT32 packetIndex) {
  constexpr DWORD bufferLength = kAudioPacketSamples * kAudioChannels *
                                (kAudioBitsPerSample / 8);
  ComPtr<IMFMediaBuffer> buffer;
  HRESULT result = MFCreateMemoryBuffer(bufferLength, &buffer);
  if (FAILED(result)) return result;

  BYTE* samples = nullptr;
  DWORD maxLength = 0;
  DWORD currentLength = 0;
  result = buffer->Lock(&samples, &maxLength, &currentLength);
  if (FAILED(result)) return result;
  std::fill(samples, samples + bufferLength, 0);
  result = buffer->Unlock();
  if (FAILED(result)) return result;
  result = buffer->SetCurrentLength(bufferLength);
  if (FAILED(result)) return result;

  ComPtr<IMFSample> sample;
  result = MFCreateSample(&sample);
  if (FAILED(result)) return result;
  result = sample->AddBuffer(buffer.Get());
  if (FAILED(result)) return result;
  result = sample->SetSampleTime(packetIndex * kAudioPacketDuration);
  if (FAILED(result)) return result;
  result = sample->SetSampleDuration(kAudioPacketDuration);
  if (FAILED(result)) return result;
  return writer->WriteSample(streamIndex, sample.Get());
}

void PrintFailure(const wchar_t* operation, HRESULT result) {
  std::wcerr << operation << L" failed with HRESULT 0x" << std::hex << result
             << L"\n";
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc != 2 || argv[1] == nullptr || argv[1][0] == L'\0') {
    std::wcerr << L"Usage: windows_mp4_fixture_generator.exe <output.mp4>\n";
    return 2;
  }

  HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(result)) {
    PrintFailure(L"CoInitializeEx", result);
    return 1;
  }
  result = MFStartup(MF_VERSION, MFSTARTUP_FULL);
  if (FAILED(result)) {
    PrintFailure(L"MFStartup", result);
    CoUninitialize();
    return 1;
  }

  int exitCode = 0;
  ComPtr<IMFSinkWriter> writer;
  result = MFCreateSinkWriterFromURL(argv[1], nullptr, nullptr, &writer);
  if (FAILED(result)) {
    PrintFailure(L"MFCreateSinkWriterFromURL", result);
    exitCode = 1;
    goto cleanup;
  }

  {
    ComPtr<IMFMediaType> outputType;
    result = MFCreateMediaType(&outputType);
    if (SUCCEEDED(result)) result = ConfigureMediaType(outputType.Get(), MFVideoFormat_H264);
    if (SUCCEEDED(result)) result = outputType->SetUINT32(MF_MT_AVG_BITRATE, 600'000);
    if (SUCCEEDED(result)) result = outputType->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Base);
    if (FAILED(result)) {
      PrintFailure(L"Configure H.264 output type", result);
      exitCode = 1;
      goto cleanup;
    }

    DWORD streamIndex = 0;
    result = writer->AddStream(outputType.Get(), &streamIndex);
    if (FAILED(result)) {
      PrintFailure(L"IMFSinkWriter::AddStream", result);
      exitCode = 1;
      goto cleanup;
    }

    ComPtr<IMFMediaType> inputType;
    result = MFCreateMediaType(&inputType);
    if (SUCCEEDED(result)) result = ConfigureMediaType(inputType.Get(), MFVideoFormat_RGB32);
    if (SUCCEEDED(result)) {
      result = inputType->SetUINT32(MF_MT_DEFAULT_STRIDE, kWidth * 4);
    }
    if (FAILED(result)) {
      PrintFailure(L"Configure RGB input type", result);
      exitCode = 1;
      goto cleanup;
    }
    result = writer->SetInputMediaType(streamIndex, inputType.Get(), nullptr);
    if (FAILED(result)) {
      PrintFailure(L"IMFSinkWriter::SetInputMediaType", result);
      exitCode = 1;
      goto cleanup;
    }

    ComPtr<IMFMediaType> outputAudioType;
    result = MFCreateMediaType(&outputAudioType);
    if (SUCCEEDED(result)) {
      result = outputAudioType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    }
    if (SUCCEEDED(result)) {
      result = outputAudioType->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
    }
    if (SUCCEEDED(result)) {
      result = outputAudioType->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS,
                                          kAudioChannels);
    }
    if (SUCCEEDED(result)) {
      result = outputAudioType->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,
                                          kAudioSampleRate);
    }
    if (SUCCEEDED(result)) {
      result = outputAudioType->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                                          192'000 / 8);
    }
    if (SUCCEEDED(result)) {
      result = outputAudioType->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE,
                                          kAudioBitsPerSample);
    }
    DWORD audioStreamIndex = 0;
    if (SUCCEEDED(result)) {
      result = writer->AddStream(outputAudioType.Get(), &audioStreamIndex);
    }
    if (FAILED(result)) {
      PrintFailure(L"Configure AAC output type", result);
      exitCode = 1;
      goto cleanup;
    }

    ComPtr<IMFMediaType> inputAudioType;
    result = MFCreateMediaType(&inputAudioType);
    if (SUCCEEDED(result)) {
      result = inputAudioType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    }
    if (SUCCEEDED(result)) {
      result = inputAudioType->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    }
    if (SUCCEEDED(result)) {
      result = inputAudioType->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS,
                                         kAudioChannels);
    }
    if (SUCCEEDED(result)) {
      result = inputAudioType->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,
                                         kAudioSampleRate);
    }
    if (SUCCEEDED(result)) {
      result = inputAudioType->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE,
                                         kAudioBitsPerSample);
    }
    if (SUCCEEDED(result)) {
      result = inputAudioType->SetUINT32(
          MF_MT_AUDIO_BLOCK_ALIGNMENT,
          kAudioChannels * kAudioBitsPerSample / 8);
    }
    if (SUCCEEDED(result)) {
      result = inputAudioType->SetUINT32(
          MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
          kAudioSampleRate * kAudioChannels * kAudioBitsPerSample / 8);
    }
    if (SUCCEEDED(result)) {
      result = writer->SetInputMediaType(audioStreamIndex,
                                         inputAudioType.Get(), nullptr);
    }
    if (FAILED(result)) {
      PrintFailure(L"Configure PCM input type", result);
      exitCode = 1;
      goto cleanup;
    }

    result = writer->BeginWriting();
    if (FAILED(result)) {
      PrintFailure(L"IMFSinkWriter::BeginWriting", result);
      exitCode = 1;
      goto cleanup;
    }
    for (UINT32 frame = 0; frame < kFrameCount; ++frame) {
      result = WriteFrame(writer.Get(), streamIndex, frame);
      if (FAILED(result)) {
        PrintFailure(L"IMFSinkWriter::WriteSample", result);
        exitCode = 1;
        goto cleanup;
      }
      if (frame % (kFramesPerSecond / kAudioPacketsPerSecond) == 0) {
        result = WriteSilentAudioPacket(
            writer.Get(), audioStreamIndex,
            frame / (kFramesPerSecond / kAudioPacketsPerSecond));
        if (FAILED(result)) {
          PrintFailure(L"IMFSinkWriter::WriteAudioSample", result);
          exitCode = 1;
          goto cleanup;
        }
      }
    }
  }

  result = writer->Finalize();
  if (FAILED(result)) {
    PrintFailure(L"IMFSinkWriter::Finalize", result);
    exitCode = 1;
    goto cleanup;
  }
  std::wcout << argv[1] << L"\n";

cleanup:
  writer.Reset();
  MFShutdown();
  CoUninitialize();
  return exitCode;
}
