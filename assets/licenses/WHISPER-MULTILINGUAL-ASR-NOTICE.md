# 多语种语音识别模型来源说明

译学助手不会在 Windows EXE 或预览 ZIP 中捆绑这组语音模型。用户在工作台显式下载时，应用从下列固定来源取得模型文件，并逐个校验 SHA-256：

- sherpa-onnx Whisper Tiny multilingual int8，revision `18e7b4cce9526312a66981ec3af7b9446b70db66`：<https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny/tree/18e7b4cce9526312a66981ec3af7b9446b70db66>
- sherpa-onnx Silero VAD model：<https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx>

OpenAI Whisper 项目声明其代码与模型权重使用 MIT License：<https://github.com/openai/whisper#license>。上述 sherpa-onnx 转换权重仓库未提供独立 model card 或 license 元数据；该许可来源说明不构成对转换文件权利链的独立法律确认。Silero VAD 上游项目声明 MIT License：<https://github.com/snakers4/silero-vad#license>；K2 发布的转换文件没有附带单独的 license 文件。

这组文件只在用户明确请求下载后保存到本机模型目录。它们不会随应用包分发，也不会自动上传录音或字幕。正式再分发模型权重前，应补齐转换模型与文件的许可证确认。
