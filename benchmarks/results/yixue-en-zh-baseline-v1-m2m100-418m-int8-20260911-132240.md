# yixue-en-zh-baseline-v1 · M2M100 418M INT8 基准

- 样例：16
- 延迟：平均 468.56 ms；P50 375 ms；P95 1310 ms；最大 1310 ms
- 首次加载：917 ms
- 峰值工作集：850.51 MiB
- 模型包：476.58 MiB
- 格式保留：2/3

| ID | 原文 | 模型译文 | 参考译文 | 耗时 ms | 格式 | 人工评分 |
|---|---|---|---|---:|---|---|
| en-zh-daily-01 | Could you open the window? It is getting warm in here. | 你能打开窗户吗?这里温暖了。 | 你能把窗户打开吗？这里开始变热了。 | 266 | — | 待盲评 |
| en-zh-spoken-01 | Give me a minute. I am almost done. | 给我一分钟,我已经完成了。 | 稍等我一下，我马上就好。 | 242 | — | 待盲评 |
| en-zh-ambiguity-01 | The bank is closed. | 银行关闭了。 | 银行关门了。 | 164 | — | 待盲评 |
| en-zh-technical-01 | The cache is invalidated whenever the model configuration changes. | 每当模型配置更改时,缓存将被关闭。 | 每当模型配置发生变化时，缓存都会失效。 | 375 | — | 待盲评 |
| en-zh-academic-01 | The results suggest that context improves terminology consistency without increasing factual errors. | 结果表明,背景改善了术语一致性,而不会增加事实错误。 | 结果表明，上下文可以提高术语一致性，而不会增加事实性错误。 | 423 | — | 待盲评 |
| en-zh-terminology-01 | The local inference engine verifies the model package before loading it. | 當地引擎在充電之前檢查模型包。 | 本地推理引擎会在加载模型包之前对其进行校验。 | 356 | — | 待盲评 |
| en-zh-formatting-01 | Version 2.1 costs $0 and uses 512 MB of memory. | 版本 2.1 花费 0 美元,使用 512 MB 的内存。 | 2.1 版本费用为 $0，占用 512 MB 内存。 | 379 | 失败 | 待盲评 |
| en-zh-long-01 | Although the meeting ended earlier than expected, the team stayed online to compare the translated transcript with the original recording and correct several names that the speech recognizer had misunderstood. | 雖然會議比預期更早結束,但團隊留在線上,將翻譯的翻譯與原始錄音相比較,並修正了演講識別者誤解的幾個名字。 | 虽然会议比预期更早结束，但团队仍然在线核对翻译稿与原始录音，并纠正了几个被语音识别器误解的人名。 | 1119 | — | 待盲评 |
| zh-en-daily-01 | 我把钥匙放在桌上了，出门时别忘了带。 | I put the key on the table and don’t forget to bring it out. | I left the keys on the table. Do not forget to take them when you leave. | 375 | — | 待盲评 |
| zh-en-spoken-01 | 没关系，我们下次再试。 | No matter, we will try again the next time. | It is okay. We can try again next time. | 259 | — | 待盲评 |
| zh-en-ambiguity-01 | 他没有同意这个建议。 | He did not agree with this proposal. | He did not agree to the proposal. | 222 | — | 待盲评 |
| zh-en-technical-01 | 应用会在本地计算文件的 SHA-256，然后再允许加载模型。 | The application will locally calculate the SHA-256 file and then allow the model to be loaded. | The application computes the file's SHA-256 locally before allowing the model to load. | 474 | 通过 | 待盲评 |
| zh-en-academic-01 | 本研究评估了不同分段策略对长文翻译准确性和连贯性的影响。 | This study evaluates the impact of different segmentation strategies on the accuracy and consistency of long term translation. | This study evaluated the effects of different segmentation strategies on the accuracy and coherence of long-document translation. | 625 | — | 待盲评 |
| zh-en-terminology-01 | 术语表应当覆盖产品名称、缩写和用户指定的固定译法。 | The term tables should cover the product name, abbreviation and fixed translations specified by the user. | The glossary should cover product names, abbreviations, and user-specified fixed translations. | 549 | — | 待盲评 |
| zh-en-formatting-01 | API 请求在 45 秒后超时，错误码为 E-104。 | The API request exceeds 45 seconds and the error code is E-104. | The API request times out after 45 seconds with error code E-104. | 359 | 通过 | 待盲评 |
| zh-en-long-01 | 为了让读者在不打断阅读节奏的情况下理解论文，软件需要保留原始版式，同时把译文、批注和术语解释放在容易查看但不会遮挡正文的位置。 | To enable readers to understand the paper without interrupting the reading rhythm, the software needs to keep the original version, while putting the translations, notes and term interpretations in a place that is easy to view but does not cover the original. | To help readers understand a paper without interrupting their reading flow, the software needs to preserve the original layout while placing translations, annotations, and terminology explanations where they are easy to view without covering the text. | 1310 | — | 待盲评 |
