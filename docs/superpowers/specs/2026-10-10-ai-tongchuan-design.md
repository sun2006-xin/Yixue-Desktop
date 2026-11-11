# 译学助手 AI 同传规格

日期：2026-10-11
状态：Windows 的系统播放声/麦克风采集、流式识别、显式 Provider 翻译、文本历史、可选 WAV 留存、屏幕录制及会后复盘源码已接入；Windows Release 编译通过。真实设备音频帧、识别/翻译质量、录音/录屏回放与音画同步仍未验收；默认资料库灰屏/锁冲突报告仍需在隔离环境复核；macOS 冻结至 Windows Gate 通过。

## 目标

在译学助手中增加可跨视频、网页课程、直播和会议复用的字幕会话。第一阶段面向 Windows 桌面用户，按独立来源采集默认播放端点 Loopback 和可选麦克风，形成带时间轴的原文与译文。来源标识不代表说话人身份；会话是否覆盖完整会议取决于用户选中的设备与音频路由。会话默认只保存字幕文本，WAV 录音和 MP4 屏幕录制必须由用户单独开启；屏幕录制视频内当前最多保留一个所选音源，不能把麦克风与系统声混成同一音轨。完成 Windows Gate 后再推进 macOS 适配与验收；手机端不属于本功能范围。

成功条件：

- 对用户明确选定且操作系统允许的音源，页面能准确显示“未连接 / 正在采集 / 无信号 / 已停止”等状态；只有首个有效音频帧进入有界原生到 Dart 事件队列后才标记音源已采集，不能把启动请求、PCM 回调或转换成功当成采集成功。
- ASR 临时结果与确认结果有稳定 `(sessionId, captureAttemptId, segmentId)`、相对会话的起止毫秒、语言、音源和修订号；重连后的旧尝试结果必须丢弃，更新同一片段时不重复追加，final 之后的迟到 interim 不得使片段回退。
- 只翻译确认片段；译文沿用原文 ID 与时间轴；排队、失败、取消和迟到结果都有可见且可控的处理方式。
- 每个会话在启动时分别固定英译中和中译英 Provider 路由；Provider 删除、禁用、重新分配或路由参数变化时明确失败，不静默改用另一条本地或远程路径。
- 会话准备/运行/暂停/停止与音源状态分开显示；只有首个有效音频帧进入有界队列后才显示采集中；字幕本地保存成功或失败也明确可见。
- 字幕历史只保存确认字幕与可用译文，不保存音频帧、interim、Provider 密钥或媒体路径；可选 WAV/MP4 媒体保存在各自本机目录，由媒体历史独立管理；目标语种随会话保存，重开历史本身不得自动发起远程翻译。
- 双语字幕能在本机回看并导出 SRT/VTT；默认不保存原始音频或视频。
- 用户显式选择远程 Provider 时先说明会发送的内容和目标 Provider；本地失败后不自动切到网络。英中两个方向只有通过固定语料和参考设备验收后才开放。

## 背景与范围

- 当前工作区维护 Flutter 桌面应用；Windows runner 是第一阶段交付目标。macOS runner 原型源码已预置，但在 Windows 阶段完成前冻结；音频帧与字幕领域合同保持平台无关。
- 产品技术框架已要求系统声音和麦克风分源、原文与译文、时间戳和修订、可选录制、结束后总结，以及不绕过 DRM、会员和应用权限。
- 当前 AI 同传工作台已接入 Windows 系统播放声与麦克风独立采集、流式 ASR、用户选择的翻译 Provider、本地字幕会话、可选分源 WAV、可选 WGC/Media Foundation MP4 和基于已保存字幕的会后输出；Release 编译不等于设备及质量验收。学习页的 `speech_to_text` 仍只覆盖短时麦克风练习。
- 本期的“视频/直播/会议”不承诺解析平台视频 URL、控制第三方播放器时间轴或绕过内容保护。Windows 不提供按应用筛选，也不识别具体说话人。MP4 只写入一个选择的音源；屏幕录制整个显示器时，显示器上实际可见的字幕浮窗也可能进入画面，当前没有独立的排除浮窗开关。系统声与麦克风可分别保留为 WAV。macOS ScreenCaptureKit 音频及其系统权限要求属于 Windows Gate 通过后的适配。任意外部播放源没有通用播放时间码；当前使用采集时钟，不能点击字幕跳回媒体位置。

## 用户与需求推断

这些角色结论来自本次产品分析，不是对真实用户的访谈。

| 角色 | 主要任务 | 首期重点 | 后续价值 |
| --- | --- | --- | --- |
| 看英文课程的学生 | 继续用原播放器听课，边听边看双语字幕 | 稳定字幕、手动源语言、术语、字幕时间线 | 搜索、课程笔记、回到可定位的媒体时间 |
| 经常开会的员工 | 看懂系统播放中的会议对端声音，避免未经知情的录音，结束后找回内容 | 明示首期只处理播放声音；字幕默认本地保存；原文/译文配对 | 麦克风接入后的完整会议来源、说话人区分、纪要、行动项和组织策略检查 |
| 视频/游戏直播观众 | 不离开正在看的 App，听懂没有可靠字幕的直播 | 系统音频采集、字幕先显原文再跟译文、可移动/可调整字幕窗 | SRT/VTT、会话搜索、热词和专名 |

## 产品调研：现有能力与机会

信息核验日期为 2026-10-10。产品套餐和功能可能随供应商调整，正式发布前要再核验。

| 产品 | 官方资料可确认的能力 | 对译学的启发与差异空间 |
| --- | --- | --- |
| Windows 11 Live Captions | 跨应用为系统音频生成字幕；离线工作、在本机处理；翻译功能要求 Copilot+ PC 且 Windows 11 24H2 或更高版本；字幕本身不保存 | 已有强系统级替代。译学要突出用户可选本地/远程 Provider、字幕会话回看/导出和更多设备覆盖，不能宣称首个跨应用字幕工具。 |
| Chrome Live Caption / Live Translate | Chrome 内媒体可用拖动气泡字幕；Live Caption 本地处理且不保存；开启 Live Translate 时字幕会发给 Google | 必须把远程翻译数据去向讲清；译学可以统一 Chrome 以外的系统音源并保留用户控制。 |
| Microsoft Teams | 提供会中实时字幕；单独开启转录后才有会后转录下载；翻译字幕受许可/会议设置影响 | 会议原生字幕通常更了解发言者和会议上下文；译学侧重统一历史和跨平台播放音源，不替代组织策略。 |
| Zoom | 会议/网络研讨会提供实时翻译字幕；主持方预先决定可用语种，参与者可选个人显示语言；要求特定套餐或附加许可 | 许可和主持方设置会限制用户；需要显式设置语种和清楚报告音源状态。 |
| Google Meet | 有实时翻译字幕、可调样式和会中回看；受 Workspace 版本与可用语种影响 | 会议内原生路径更直接；译学以跨应用、可本地保存和用户选择 Provider 为重点。 |
| YouTube / Twitch | YouTube 直播自动字幕官方说明仍是英语、频道逐步开放并要求正常延迟；Twitch 的专业实时字幕只覆盖部分 Twitch 制作的活动，其他直播依赖主播接入 | 不能依赖平台一定提供可用字幕；系统音频字幕有实际需求，但要清晰提示无声、独占输出、重叠讲话和不可采集状态。 |

### GitHub 方案调研

这些仓库说明开源项目能提供哪些实现参考；它们的 README、示例和星数不等于译学已集成，也不能代替固定语料、资源和延迟验收。

| 项目 | 可复用的技术线索 | 采用边界 |
| --- | --- | --- |
| [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | 官方 C++ 示例包含 Windows/macOS/Linux 的实时麦克风 streaming ASR、离线 ASR 和 streaming WebSocket server | 作为本地流式识别候选；先验证可用英中模型、模型包许可、CPU/RAM/实时因子和 Flutter/Rust/Windows 集成，再决定是否接入。 |
| [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp) | 项目提供 `whisper-stream` 实时麦克风示例、`livestream.sh`、HTTP server 与离线转录示例 | 可作识别质量和实现结构对照；其麦克风示例不能直接证明系统声音采集、低延迟或目标机器性能。 |
| [SYSTRAN/faster-whisper](https://github.com/SYSTRAN/faster-whisper) | 支持文件转录、分段时间戳、可选词级时间戳与 VAD | 更适合作为离线媒体/基准对照；Python 批处理能力不等于桌面实时 ASR。开源 issue 也记录过 VAD 与词时间戳重建偏移问题，验收必须单独测时间轴。 |
| [collabora/WhisperLive](https://github.com/collabora/WhisperLive) | README 展示近实时 WebSocket、客户端、词时间戳、热词和可选说话人分离等组合 | 作为数据流和产品切片参考；项目描述为“nearly-live”且依赖服务端后端，不能直接采用为本地离线运行结论。 |

### 角色评审结论

- **产品经理：**第一阶段先交付并验收 Windows 默认播放声音的双语字幕闭环，会议仅覆盖系统播放的对端声音；P7 含最小可移动置顶字幕窗，会后摘要排在 macOS 适配之前。Windows Gate 通过后再推进 macOS。
- **测试工程师：**固定英中素材覆盖口音、噪声、音乐、中英混说、重叠发言、静音、拔插设备、停止会话和翻译慢/失败。测 WER/CER、段落时间误差、采集到字幕延迟、队列积压和恢复；当前没有依据承诺一个固定延迟值。
- **代码开发者：**音源、ASR、翻译和存储分离；现有文字翻译接口一次仅支持一个活动请求，需增加有序队列和会话取消语义。避免把学习页的 SAPI 麦克风识别复用成系统音频 ASR。
- **学生/会议员工/直播观众：**共同要求可回看、原译对照、明确数据去向；学生偏术语与定位，员工偏隐私和会后检索，直播观众偏字幕紧凑、可移动、可切换视图和识别积压反馈。

## 首期架构

```text
Windows 音源选择                         macOS 音源选择
  └─ 首期：WASAPI shared-mode loopback     └─ 首期：ScreenCaptureKit 系统音频
      后续：Application Loopback               （macOS 13+，用户授权）
      P8：独立 microphone input                后续：Core Audio Process Tap
                                                    （精确应用音频，macOS 14.2+）
        ↓ PCM frames + monotonic capture time + sourceId
replaceable streaming ASR
        ↓ RecognitionUpdate(sessionId, captureAttemptId, segmentId, revision, startMs, endMs, text, language, speakerId?, isFinal)
ordered translation queue (confirmed segments only)
        ↓ typed request/result preserve session, segment, revision, request attempt, and time range
local subtitle timeline → bilingual view / SRT / VTT
```

- Windows 系统 Loopback 是共享模式输出混音，可能混入其他程序声音；独占模式及受保护音源可能不可用。首期不包含 Application Loopback 筛选；后续支持时需满足 Windows 版本门槛。macOS 使用 ScreenCaptureKit 的 `SCStreamConfiguration.capturesAudio`，需要屏幕录制授权；屏幕内容不注册为输出，也不传入 Dart。ScreenCaptureKit 的音频过滤按应用边界工作，首期选显示器过滤音频，不承诺将窗口筛选当成严格的应用音频隔离。未来需要单应用输出时，评估 macOS 14.2+ Core Audio Process Tap。两个平台都只有在收到首个有效音频帧后才显示音源“已采集”；采集请求、等待首帧、无信号、权限拒绝、设备断开和失败必须区分，不切换到未授权音源。
- 首选调查方向是独立本地 streaming ASR 运行时；候选仓库不构成选型通过。远程 ASR 当前无配置契约，不能作为默认路径。
- 翻译复用现有用户明确选定的本地/远程翻译配置，并在会话开始时按语言方向固定路由；路由配置变化后失败关闭，不静默换 Provider。ASR 与 MT 是不同能力，不因翻译 API 配置就自动获得音频识别能力。
- 会话历史以本地元数据和分片字幕文件保存；`preparing`、采集中和暂停中的会话在重开时持久化为 `interrupted`；空 final 更正写入版本墓碑以防旧回调复活字幕。单条删除和批量清理只允许影响终态会话，防止历史页误删仍在写入的记录；保留清理是用户触发的一次性操作。SRT/WebVTT 首期导出原文及当前可用译文，未译片段保留原文。恢复未译字幕需要明确会话目标语种和用户动作，不自动上传。
- 会话存储通过独立资料库目录和 OS 文件锁隔离会话数据，并发写入由同一 isolate 串行处理；macOS 文件锁按进程生效，存储控制器必须由单一 app isolate 持有。应用先持有资料库根的单实例租约，再执行中断会话恢复，避免第二个 app 进程把仍活动的会话标成中断。macOS 资料库路径由 Foundation `applicationSupportDirectory` 提供，以遵循沙盒容器位置；首期 macOS 使用应用数据目录，不提供任意外部目录选择，也拒绝指向外部路径的环境覆盖或旧路径偏好；遇到旧偏好时给出警告并允许切换到安全默认目录，旧资料不会自动搬移或删除，环境覆盖则要求用户移除后重启；待安全范围书签方案确定后再开放。Windows 首期保留用户选目录。网络盘或共享目录的锁语义不在首期保证范围内。
- macOS 的 `file_selector` 保存对话框需在 Debug/Profile 和 Release 沙盒 entitlement 中声明用户选定文件读写权限；打开对话框不等于后续文件写入已验收。长期保存用户选择的资料库路径仍需可恢复的安全范围授权。
- 先只存字幕会话；保留音频/录像是独立、明确且持续可见的选项。首期不做录音、录屏、说话人身份识别或 TTS 配音；Windows 会后摘要、术语表和行动项在字幕历史闭环后作为可选的后续阶段实现。
- 历史页展示音源类别，不据此推断或展示具体应用名称/发言人身份；如未来需要追溯来源，必须分别定义经用户选择的应用元数据与通过验证的说话人分离能力。
- 原始音频片段在处理后释放；错误日志只写错误码和非敏感状态，不写音频、完整字幕或密钥。

## 技术栈、目录和工程约束

- 当前：Flutter/Dart 桌面端，Rust Core 通过 Dart FFI；Windows native runner 为 C++。当前同传 UI 位于 `app/yixue_app/lib/features/`，shell 导航接在 `home_shell.dart`。
- 首个协议定义放在 `app/yixue_app/lib/features/simultaneous_interpretation/`；字幕唯一键使用 `(sessionId, captureAttemptId, segmentId)`；Windows C++ WASAPI 与 macOS Swift ScreenCaptureKit 捕获实现分别放在平台适配层；ASR 模型/运行时管理不能混进页面 widget。
- 沿用项目 Dart 命名（lowerCamelCase、PascalCase 类名）、不可变状态对象和显式错误码；Flutter UI 保持当前深蓝工作台的桌面信息密度，窄窗口下仍能查看字幕。
- 当前工作树有其他未提交修改。本功能首期新增独立文件；需要改 `home_shell.dart`、`pubspec.yaml`、Windows runner 或模型设置时，只做最窄修改并保留原有 diff。

## 测试策略与验收

本规格定义未来验证，不表示本轮已运行测试。

| 层级 | 验收范围 |
| --- | --- |
| 领域单测 | 同一 `(sessionId, captureAttemptId, segmentId)` 临时/确认修订覆盖；旧修订、旧采集尝试及 final 后迟到 interim 丢弃；起止时间为正；仅在队列接受后显示 queued；旧 revision/旧 requestId 的迟到译文被丢弃；翻译状态只能按合法路径推进。 |
| Windows native integration | 首期默认系统输出设备、设备切换/拔出、静音、无支持设备、权限/应用拒绝；应用输出筛选另列后续能力；首帧前不显示监听中；启动/暂停/停止正确释放 COM/WASAPI 资源。 |
| macOS native integration | macOS 13+ ScreenCaptureKit 系统音频权限/拒绝、首帧、无信号、停流、主显示器变化和启动失败；仅订阅音频输出；核对首次授权后是否需要重启；macOS 12.x 显示功能不可用；应用级 Core Audio Tap 作为独立后续能力。 |
| ASR/模型评估 | 获准英中双向固定素材；WER/CER、时间边界误差、首段延迟、p50/p95 延迟、实时因子、CPU/RAM、热词和多人重叠。只有已通过的语言方向才可在 UI 中选择，具体门槛以参考硬件实测后确定。 |
| 翻译集成 | 远程配置仅用户明确选择；网络失败不得静默上传或改用另一 Provider；拥塞、取消、会话关闭和翻译结果晚到时不串段、不乱序；结果必须匹配会话、片段、转写修订和请求尝试。 |
| UI/数据 | 置顶窗支持原文+译文/仅原文/仅译文、字号和高对比背景；最小可移动/置顶/缩放字幕窗；会话状态与音源范围、处理路径、临时/确认字幕、队列/翻译/取消状态、保存成功/失败清楚可见；透明度、多显示器增强、会话删除、SRT/VTT 回读和 Unicode 后续补验；默认不写原始音频。 |
| 目标应用 | 经授权的网页播放器、普通桌面播放器、会议和直播客户端分别实测；记录独占输出、DRM、源应用策略和低延迟流带来的限制。 |

未来可用的仓库命令：应用目录 `flutter test`、`flutter analyze`；仓库根目录按 README 的工具链准备 `cargo test --workspace`。是否执行由当前任务明确要求决定。

## 必须始终遵守的边界

- 默认本地处理、字幕文字保存在本机；不默认上传音频/字幕，也不默认录音或录屏。
- 远程能力必须由用户选择，并明确数据去向；远程失败不可静默回退或上传。
- 不绕过 DRM、付费会员、会议策略、权限提示或应用的音频捕获策略。
- 只对确认片段触发翻译；每条译文都能追溯到同一原文片段和时间轴。
- “系统声音已请求”“等待首帧”“音频帧已采集”“ASR 已输出”“已进入队列”“字幕已翻译”是不同状态，界面与日志不可合并成一个模糊的“正在同传”。

## 来源

### 官方产品与平台资料

- [Windows Live Captions](https://support.microsoft.com/en-us/accessibility/windows/use-live-captions-to-better-understand-audio)
- [Chrome captions and translations](https://support.google.com/chrome/answer/10538231?hl=en-GB)
- [Teams live captions](https://support.microsoft.com/en-us/teams/meetings/use-live-captions-in-microsoft-teams-meetings)
- [Zoom translated captions](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0059081)
- [Google Meet translated captions](https://support.google.com/meet/answer/10964115?hl=en-GB)
- [YouTube automatic captions and live-caption limits](https://support.google.com/youtube/answer/6373554?hl=en)
- [Twitch closed captions](https://help.twitch.tv/s/article/guide-to-closed-captions?language=en_US)
- [Microsoft WASAPI loopback](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording)
- [Microsoft Application Loopback sample, published 2026-02-19](https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/)
- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Apple ScreenCaptureKit availability and sample](https://developer.apple.com/videos/play/wwdc2022/10156/)
- [Apple Core Audio Process Taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Flutter platform channels](https://docs.flutter.dev/platform-integration/platform-channels)

### GitHub implementation references

- [sherpa-onnx C++ examples](https://github.com/k2-fsa/sherpa-onnx/blob/master/sherpa-onnx/csrc/README.md)
- [whisper.cpp examples](https://github.com/ggml-org/whisper.cpp)
- [faster-whisper](https://github.com/SYSTRAN/faster-whisper)
- [WhisperLive](https://github.com/collabora/WhisperLive)

## 2026-10-11 Windows 桌面字幕 UI 研究与决定

本次依据官方产品帮助文档和 GitHub 项目说明补充同类功能观察。外部资料说明的是对应产品或仓库文档中的能力，不代表我们运行过这些产品，也不构成译学助手已实现相同能力的证据。

| 参考 | 提取的界面/功能模式 | 译学助手的落地方式 |
| --- | --- | --- |
| [Microsoft Teams 实时字幕](https://support.microsoft.com/en-gb/teams/meetings/use-live-captions-in-microsoft-teams-meetings) | 字幕显示是独立动作；讲话语言、目标语言和字幕外观可以调整。 | 把字幕内容、字号和高对比选项放进置顶字幕窗的单一设置菜单；同传前后都直接显示语言方向。 |
| [Google Meet 翻译字幕](https://support.google.com/meet/answer/10964115?hl=en-SG) | 用户能调整字幕字号、文字/背景颜色，并在会中回看字幕。 | 置顶窗提供 18/21/25 px 字号、稳定的高对比深色背景、双语/单语切换；字幕设置保存到本机。保留会话历史作为完整回看路径。 |
| [Zoom 翻译字幕](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0060844) | 参会者可以自选字幕目标语言，目标语言偏好可用于后续会议。 | 让当前源/目标语言在字幕窗可见；不把用户的语言选择藏在翻译结果或设备设置中。 |
| [OBS 快速开始与工作区](https://obsproject.com/kb/quick-start-guide) | 直播工作流在操作前先确认来源，运行时显示音频电平和输出状态。 | 继续分别呈现音源、识别、翻译队列和保存状态；不把它们合并成含糊的“正在同传”。OBS 多面板和主播输出概念不进入首期工作台。 |
| [Windows Live Captions](https://support.microsoft.com/en-us/accessibility/windows/use-live-captions-to-better-understand-audio) 与 [Chrome Live Caption](https://support.google.com/chrome/answer/10538231?hl=en-GB) | 用户已熟悉跨应用/拖动字幕气泡、可调外观及本地字幕的模式；翻译可能有硬件或数据路径条件。 | Windows 版采用明确启动的桌面置顶字幕窗，并标出远程 Provider 数据边界；不宣称任何 Windows 设备都具备系统级翻译硬件条件。 |

GitHub 项目只作需求和实现模式参考：[Live Translation](https://github.com/fmadore/Live-translation) 的暂停续接、字幕搜索/导出与本地历史；[realtime-subtitles](https://github.com/Preygle/realtime-subtitles) 的未完成字幕预览与已确认字幕稳定显示；[WhisperLive](https://github.com/collabora/WhisperLive) 的临时/确认转写区分及 PCM 流式输入。以上 README 声明未在本项目中运行或复测。

### 本轮确定的 Windows 字幕设置

- 置顶字幕窗直接提供“原文 + 译文 / 仅原文 / 仅译文”，并在窗内显示当前语言方向和显示模式。
- 提供 18、21、25 px 三档字幕字号；高对比深色背景默认开启，便于视频画面变化时保持文字可读。
- 原文、译文未到、翻译失败和重试状态按模式显示。选择仅译文时，翻译失败仍显示原文备份，避免字幕信息丢失。
- 显示模式、字号和高对比设置保存在本机数据目录，不改变音频采集、翻译 Provider 或会话记录内容。
- 首期仍不增加单应用采集、多说话人身份、透明度调节或 OBS 观众字幕输出；浮窗不等于已写入直播流。
- UI 源码核验后还需 Windows 实机检查字号/缩放、按钮布局、会话运行、失败重试和偏好重启恢复；当前没有完成这些运行验收。

## 2026-10-11 用户确认的通用工作流与 Windows 优先交付顺序

用户确认采用“采集、翻译、字幕显示、历史复盘相互独立”的产品方向，适用于会议、视频课程和直播；本功能仍只面向 Windows 与 macOS 电脑，不含手机。

| 顺序 | 用户看到的能力 | 会话处理 | 关闭/数据语义 | 开发门槛 |
| --- | --- | --- | --- | --- |
| W1 | 主窗口负责会话设置与历史；运行时显示实际可用的控制入口；字幕用独立、可移动/置顶/缩放的展示窗，展示样式可选 | 可选择系统播放声和麦克风；开始前可关闭翻译，仍可识别并保存原文 | 关闭/隐藏字幕窗只影响显示；控制窗或字幕窗不另开采集器或资料库；退出选择“隐藏到托盘”或“彻底退出” | 源码与 Release 构建已完成；目标 Windows 的窗口生命周期、单一会话 owner、历史、焦点和字幕窗同步待验收 |
| W2 | 系统播放声和麦克风作为独立来源，可分别启停和查看状态 | 来源保持独立身份与统一会话时间；来源类型不等于说话人身份 | 只采集用户选择的音源；留存由独立选项决定，默认关闭 | 源码及 Release 编译已完成；麦克风权限、静音、设备断开、时钟漂移与双源历史待设备验收 |
| W3 | 增加可选音频留存 | 录音开关与实时转写/翻译分离；每个音源保存独立 WAV，运行中显示状态 | 默认不录音；结束后可从本机录音历史打开或删除媒体 | 源码及 Release 编译已完成；长时稳定性、磁盘空间与中断恢复待设备验收 |
| W4 | 增加屏幕录制选项，可单独控制字幕展示 | WGC 选择器采集屏幕/窗口，MP4 可附带一个所选音源，音频与画面采用共同 QPC 时间原点；系统声与麦克风不会混成单轨 | 录屏与字幕会话分别停止；若选择整块显示器，当前可见的浮窗也可能被录入；选应用窗口可避免录入其他窗口 | 源码及 Release 编译已完成；音画播放同步、受保护窗口行为和大文件稳定性待设备验收 |
| W5 | 历史提供文本重温、搜索和会后总结/行动项 | 原文与译文按时间轴成对保留；摘要、术语和行动项按需生成并引用原片段 | 文本历史默认本地；远程 Provider 单独确认内容和去向；用户可分别管理字幕、录音和视频 | 源码及 Release 编译已完成；真实 Provider 运行、摘要溯源与媒体生命周期待验收 |

### W1 信息架构决定

- 主同传页继续作为设置和完整时间线入口；用户开始会话前选择是否翻译；会话开始后，用户能直接找到暂停/继续、字幕显示/隐藏和停止并保存。
- 字幕窗只呈现当前原文/译文、必要的音源/翻译/保存状态以及样式菜单，不承载资料库、音频采集或翻译 Provider 初始化。
- 字幕开关控制的是呈现，不控制 ASR、翻译或持久化。用户关掉字幕窗后，主同传页仍能显示时间线与错误；字幕窗重开后读取当前会话快照。
- 麦克风、录音和屏幕录制控件已接入各自采集与持久化链路；Release 编译通过仍不代表设备上的权限、首帧、实际文件和关闭恢复已经验收。
- W1 首期继续默认保存确认字幕文字，不自动保存原始音频或视频。任何媒体留存都需要独立开关、可见状态、保存位置和删除入口。
