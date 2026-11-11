# yixue-en-zh-baseline-v1 · OPUS-MT INT8 基准

- 样例：16
- 延迟：平均 177.06 ms；P50 157 ms；P95 490 ms；最大 490 ms
- 峰值工作集：138.27 MiB
- 格式保留：2/3

| ID | 原文 | 模型译文 | 参考译文 | 耗时 ms | 格式 | 人工评分 |
|---|---|---|---|---:|---|---|
| en-zh-daily-01 | Could you open the window? It is getting warm in here. | 你能打开窗户吗? | 你能把窗户打开吗？这里开始变热了。 | 87 | — | 待盲评 |
| en-zh-spoken-01 | Give me a minute. I am almost done. | 给我一分钟,我快好了 | 稍等我一下，我马上就好。 | 64 | — | 待盲评 |
| en-zh-ambiguity-01 | The bank is closed. | 银行关门了 | 银行关门了。 | 45 | — | 待盲评 |
| en-zh-technical-01 | The cache is invalidated whenever the model configuration changes. | 当模型配置改变时,缓存将无效 。 | 每当模型配置发生变化时，缓存都会失效。 | 124 | — | 待盲评 |
| en-zh-academic-01 | The results suggest that context improves terminology consistency without increasing factual errors. | 结果显示,背景情况提高了术语的一致性,而没有增加事实错误。 | 结果表明，上下文可以提高术语一致性，而不会增加事实性错误。 | 157 | — | 待盲评 |
| en-zh-terminology-01 | The local inference engine verifies the model package before loading it. | 本地推论引擎在装货前验证模型包。 | 本地推理引擎会在加载模型包之前对其进行校验。 | 139 | — | 待盲评 |
| en-zh-formatting-01 | Version 2.1 costs $0 and uses 512 MB of memory. | 第2.1版费用为0美元,使用512MB内存。 | 2.1 版本费用为 $0，占用 512 MB 内存。 | 175 | 失败 | 待盲评 |
| en-zh-long-01 | Although the meeting ended earlier than expected, the team stayed online to compare the translated transcript with the original recording and correct several names that the speech recognizer had misunderstood. | 虽然会议比预期提前结束,但小组仍然在网上将翻译稿与原录作作比较,并更正了语音识别器误解的若干名字。 | 虽然会议比预期更早结束，但团队仍然在线核对翻译稿与原始录音，并纠正了几个被语音识别器误解的人名。 | 316 | — | 待盲评 |
| zh-en-daily-01 | 我把钥匙放在桌上了，出门时别忘了带。 | I left the keys on the table, so don't forget to take them when you're out. | I left the keys on the table. Do not forget to take them when you leave. | 237 | — | 待盲评 |
| zh-en-spoken-01 | 没关系，我们下次再试。 | It's okay. We'll try again. | It is okay. We can try again next time. | 121 | — | 待盲评 |
| zh-en-ambiguity-01 | 他没有同意这个建议。 | He did not agree with that suggestion. | He did not agree to the proposal. | 83 | — | 待盲评 |
| zh-en-technical-01 | 应用会在本地计算文件的 SHA-256，然后再允许加载模型。 | The application will be used to calculate the file locally in SHA-256 and then allow the model to be loaded. | The application computes the file's SHA-256 locally before allowing the model to load. | 227 | 通过 | 待盲评 |
| zh-en-academic-01 | 本研究评估了不同分段策略对长文翻译准确性和连贯性的影响。 | This study assesses the impact of the different sub-strategies on the accuracy and consistency of long-language translations. | This study evaluated the effects of different segmentation strategies on the accuracy and coherence of long-document translation. | 222 | — | 待盲评 |
| zh-en-terminology-01 | 术语表应当覆盖产品名称、缩写和用户指定的固定译法。 | The glossary should cover product names, abbreviations and fixed translations specified by the user. | The glossary should cover product names, abbreviations, and user-specified fixed translations. | 168 | — | 待盲评 |
| zh-en-formatting-01 | API 请求在 45 秒后超时，错误码为 E-104。 | API requests timeout after 45 seconds with the error code E-104. | The API request times out after 45 seconds with error code E-104. | 178 | 通过 | 待盲评 |
| zh-en-long-01 | 为了让读者在不打断阅读节奏的情况下理解论文，软件需要保留原始版式，同时把译文、批注和术语解释放在容易查看但不会遮挡正文的位置。 | In order for the reader to understand the paper without disrupting the reading rhythm, the software needs to retain the original layout, while placing translations, comments and terminology interpretation in an easily viewed position that does not obscure the text. | To help readers understand a paper without interrupting their reading flow, the software needs to preserve the original layout while placing translations, annotations, and terminology explanations where they are easy to view without covering the text. | 490 | — | 待盲评 |
