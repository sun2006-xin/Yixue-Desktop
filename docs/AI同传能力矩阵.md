# AI 同传能力矩阵

更新时间：2026-11-05

## 当前源码中的能力边界

| 能力 | 当前支持 | 路径与限制 |
| --- | --- | --- |
| 英语 / 中文语音识别 | 英语、普通话 | 本地 Zipformer 流式识别 |
| 多语种语音识别 | 日语、韩语、西班牙语、法语、德语、葡萄牙语、俄语；另有自动识别 | 本地 Whisper Tiny INT8 + VAD 分段识别；字幕会在语音段处理后更新，不能当作逐帧流式延迟 |
| 自动识别结果 | 上述注册语言 | 注册表之外的识别码不会被伪装成已支持语种；未识别结果按 `und` 处理 |
| 翻译方向 | 32 个有向语言组合 | 由 `TranslationDirection` 登记。语言识别已支持，不代表任意语言对都能翻译 |
| 随包本地翻译 | 英语 ↔ 中文 | 其他语向需要用户配置且明确启用兼容 Provider；Provider 被列入路由不等于它通过了逐语向能力测试 |

选择翻译目标时，界面只显示方向表中存在的语言对；Provider 是否配置、该模型是否真的支持这个方向，仍由路由准备和实际请求单独判定。模型页也明确提醒：显示的外接 API 路由尚未逐语种自动验证。

## 音频保存与旧文件兼容

- 新录音保存为 PCM16 WAV。单声道和立体声使用标准 PCM 头；超过两个声道使用 `WAVEFORMATEXTENSIBLE`，并保留声道布局或明确标记未指定布局。
- 旧版已完成多声道 WAV 若使用播放器可能无法识别的普通 PCM 头，会在历史中显示为“兼容副本”候选。创建副本时保留旧文件，不在原路径改写。
- 新版历史内置播放器基于 MediaKit。源码测试验证文件结构、索引与恢复副本；实际 Windows 解码、播放设备、旧视频容器兼容性仍需要桌面验收。

## 内容和模型来源

- 多语 ASR 的候选运行时参考：[OpenAI Whisper](https://github.com/openai/whisper) 和 [sherpa-onnx Whisper ONNX 文档](https://github.com/k2-fsa/sherpa/blob/master/docs/source/onnx/pretrained_models/whisper/export-onnx.rst)。
- 运行时选出的九个语种只表示程序接受相应代码及模型路由，不是语音质量认证。新增五个语种尚无逐语种 CER/WER 基准和真实内容准确率结论。
- 词典与学习材料来源、版本、许可证和本地候选状态见 [`开放词典来源与合规清单.md`](开放词典来源与合规清单.md)。当前学习短文为译学自写材料；开放词典、例句语料仍按各自来源与许可隔离，不冒充商业词典或出版社教材。

## Windows WAV 格式依据

微软说明，超过两个声道的 PCM 需要 `WAVEFORMATEXTENSIBLE` 来描述声道布局；零声道掩码表示没有指定扬声器位置，声道数仍由 `nChannels` 给出。参见 [WAVEFORMATEX](https://learn.microsoft.com/en-us/windows/win32/api/mmreg/ns-mmreg-waveformatex)、[WAVEFORMATEXTENSIBLE](https://learn.microsoft.com/en-us/windows/win32/api/mmreg/ns-mmreg-waveformatextensible) 和 [DirectOut 声道掩码说明](https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/dsspeaker-directout-speaker-configuration)。
