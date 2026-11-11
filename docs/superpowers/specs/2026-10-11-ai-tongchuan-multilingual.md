# Spec: Windows AI 同传多语种升级

## Objective

在既有 Windows 同传预览版上实现首批多语种能力：英语、普通话、日语、韩语识别；支持用户手动选择原文语言和自动按短句判断语种；字幕历史保留真实语种；译文方向遵循所选 Provider 的语言能力。旧英中低延迟流式路径保持可用。目标是可下载、可回归、可复核的 Windows 预览更新，不把源码通过冒充真实设备验收。

## Tech Stack

- Flutter/Dart Windows 桌面端，当前 `sherpa_onnx: 1.13.8`、本地 ONNX ASR、现有 WASAPI capture 与 subtitle session pipeline。
- 语言标识使用稳定规范代码；`auto` 是识别模式，不是语言代码，不得写成字幕源语种。
- 多语 ASR：固定 revision 的 sherpa-onnx Whisper Tiny multilingual int8（en/zh/ja/ko）配 Silero VAD，按语句离线解码；Whisper 转换仓库未提供独立 license 元数据，随软件保留 OpenAI Whisper MIT 来源与许可说明，并将模型权重单独显式下载，不打包进 EXE。现有 bilingual Zipformer 继续负责英语/普通话低延迟流式路径。
- 英中本地翻译现状保留；其他方向只有在用户显式选择、且 Provider 声明支持时才允许。没有对应路由时保留原文字幕并清楚提示，不静默联网。

## Commands

- Focused multilingual regression: flutter test --no-pub test/asr_language_registry_test.dart test/live_subtitle_session_test.dart test/multilingual_asr_model_store_test.dart test/streaming_asr_language_routing_test.dart test/subtitle_session_persistence_test.dart test/subtitle_session_store_test.dart test/subtitle_translation_language_route_test.dart test/subtitle_unknown_language_test.dart test/subtitle_window_language_test.dart test/simultaneous_interpretation_multilingual_ui_test.dart test/quick_translation_service_test.dart test/translation_quality_guard_test.dart
- Full Flutter regression: flutter test --no-pub; Windows native bridge tests also require YIXUE_CORE_DLL to point to the built yixue_ffi.dll.
- Static analysis: dart analyze.
- Model smoke: flutter test --no-pub test/multilingual_asr_model_smoke_test.dart, with the five YIXUE_ASR_*/YIXUE_SHERPA_RUNTIME_DIR inputs set to pinned test models, WAVs, and the packaged runtime DLL directory.
- Windows Release build: tool/build-windows.ps1 -Mode Release.
## Project Structure

- ASR language/model registry and recognizer adapters: `app/yixue_app/lib/features/simultaneous_interpretation/` and `app/yixue_app/lib/core/`.
- Translation capability routing: existing `quick_translation_service.dart`, Provider profile contracts, and subtitle translation executor.
- Session/history/UI: simultaneous interpretation contracts, store, and workbench page.
- Regression coverage: `app/yixue_app/test/`.
- Planning and changelog: this spec, matching plan under `docs/superpowers/plans/`, `tasks/plan.md`, `tasks/todo.md`, and `CHANGELOG.md`.

## Code Style

Use immutable language and model specs. Keep detection mode separate from actual segment language. Preserve the existing bounded audio queue, request IDs, session/capture IDs, cancellation, model hash validation, explicit network/Provider boundaries, and local history compatibility. Example contract shape:

```dart
final class AsrLanguage {
  const AsrLanguage({required this.code, required this.nativeName});
  final String code; // e.g. ja, ko, zh, en
  final String nativeName;
}

final class TranscriptRevision {
  // languageCode is the recognized language for this segment, never "auto".
}
```

## Testing Strategy

- Unit: language normalization and labels; manual/auto mode separation; supported versus unsupported codes; model-pack manifest and safe installation; detected language propagation; unknown-language behavior; translation route capability/no silent fallback; history round-trip including legacy data; UI model-install gates and selectors.
- Native/model smoke: pinned local model pack hashes, sample WAV recognition for each exposed language, auto-language output, non-empty timestamps, model startup/teardown, VAD endpoint flush, cancellation, and no transcript language relabeling.
- Quality report: per-language CER/WER, language identification correctness, endpoint-to-caption latency, real-time factor and process memory on the current Windows reference host. Clearly identify sample corpus provenance and that public model samples do not establish broad accent/noise quality.
- Final build: Windows Release package contains runtime dependencies and model installer code, but not model weights or user data. Real meeting-app, physical microphone, noisy room, and long-session acceptance must be reported separately from unit/model/build evidence.

## Boundaries

- Always: keep audio local; explicit model download only; model downloads pin upstream revision, file size, hashes and license; `auto` never becomes the transcript language; unknown output is not translated; local/remote Provider route is shown and frozen per session; history stores actual per-segment language.
- Ask first: add a model whose license forbids redistribution/derivatives, bundle model weights into the EXE, or enable cloud ASR/audio upload.
- Never: claim universal auto-detection or word-level code-switching; silently route unsupported translation to cloud; mark a language production-accepted solely from compile/unit tests.

## Success Criteria

- User can choose English, Chinese, Japanese or Korean, or Auto; required model availability/download gates are correct.
- Auto mode produces per-utterance detected language for supported speech and preserves `und`/original-only behavior for unsupported output; historical transcript and exports show the actual language.
- Translation target choices and execution reflect explicit Provider capability; every supported direction passes, unsupported pairs fail visibly with no hidden upload.
- Existing English/Chinese path, existing history data, capture cancellation, session stop and export remain regression-safe.
- Current Windows build, focused/full Flutter regression and analyzer pass; pinned model files pass hash checks; per-language sample results and performance are recorded.
- Branch is pushed, reviewed, merged under the existing repository process, and a new Windows Preview ZIP/EXE asset is published only after gates pass.

## Open Questions

- Whisper Tiny 的 sherpa-onnx API 以空 language 启用短句级语言检测，并在结果提供 lang；Auto 验收只覆盖固定语音片段上的标签传递，不承诺置信度阈值。
- Live microphone/meeting-app acceptance requires a user-authorized controlled run and cannot be inferred from offline WAV recognition.
