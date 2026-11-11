# yixue-en-zh-evaluation-v2 · M2M100 418M INT8 基准

- 样例：64
- 延迟：平均 400.31 ms；P50 394 ms；P95 547 ms；最大 662 ms
- 首次加载：783 ms
- 峰值工作集：851.62 MiB
- 模型包：476.58 MiB
- 格式保留：10/16

| ID | 原文 | 模型译文 | 参考译文 | 耗时 ms | 格式 | 人工评分 |
|---|---|---|---|---:|---|---|
| en-zh-completeness-01 | Could you open the window? It is getting warm in here. | 你能打开窗户吗?这里温暖了。 | 你能把窗户打开吗？这里开始变热了。 | 268 | — | 待盲评 |
| en-zh-completeness-02 | If the update fails, the application will keep the previous version and no files will be uploaded. | 如果更新失败,应用程序将保持以前的版本,并且不会上传任何文件。 | 如果更新失败，应用将保留先前版本，而且不会上传任何文件。 | 398 | — | 待盲评 |
| en-zh-completeness-03 | Although the report was ready, the researcher did not send it because two figures had not been verified. | 虽然报告已经准备好了,但研究人员没有发送,因为两个数字没有被验证。 | 虽然报告已经完成，但研究人员没有发送，因为其中两幅图还没有经过核验。 | 425 | — | 待盲评 |
| en-zh-completeness-04 | Please save the draft before closing the reader; otherwise, your unsaved annotations will be lost. | 请在关闭读者之前保存草案;否则,您的未保存的笔记将被丢失。 | 关闭阅读器前请保存草稿，否则未保存的批注将会丢失。 | 509 | — | 待盲评 |
| en-zh-completeness-05 | By the time the class began, the subtitles had been corrected but the summary was still being generated. | 在课堂开始时,字幕已被纠正,但总结仍在进行中。 | 课程开始时，字幕已经校正完毕，但总结仍在生成。 | 391 | — | 待盲评 |
| en-zh-completeness-06 | The system not only recognized the speaker's question but also linked the answer to the correct timestamp. | 该系统不仅识别了发言人的问题,还将答案与正确的时间线联系起来。 | 系统不仅识别出了发言者的问题，还把答案关联到了正确的时间点。 | 437 | — | 待盲评 |
| en-zh-completeness-07 | Unless you enable cloud sync yourself, every note remains only on this computer. | 除非您自行启用云同步,否则每个笔记只留在此计算机上。 | 除非你主动启用云同步，否则所有笔记都只保留在这台电脑上。 | 470 | — | 待盲评 |
| en-zh-completeness-08 | She said that he could join the discussion after finishing the experiment, but she did not promise to wait. | 她说,在试验结束后,他可以加入讨论,但她没有承诺等待。 | 她说他做完实验后可以参加讨论，但她没有答应等他。 | 416 | — | 待盲评 |
| en-zh-terminology-01 | The cache is invalidated whenever the model configuration changes. | 每当模型配置更改时,缓存将被关闭。 | 每当模型配置发生变化时，缓存都会失效。 | 325 | — | 待盲评 |
| en-zh-terminology-02 | The local inference engine verifies the model package before loading it. | 當地引擎在充電之前檢查模型包。 | 本地推理引擎会在加载模型包之前对其进行校验。 | 309 | — | 待盲评 |
| en-zh-terminology-03 | The speech recognizer produced a transcript with word-level timestamps. | 演讲识别器制作了一个经文与词级时间表。 | 语音识别器生成了一份带逐词时间戳的转写稿。 | 323 | — | 待盲评 |
| en-zh-terminology-04 | A user-defined glossary should override the model's default translation for approved terms. | 用户定义的词汇应该超过模型的默认翻译,以获得批准的术语。 | 对于已经确认的术语，用户自定义术语表应覆盖模型的默认译法。 | 426 | — | 待盲评 |
| en-zh-terminology-05 | A longer context window can improve coherence, but it also increases memory usage. | 更长的背景窗口可以改善一致性,但它也增加了内存使用量。 | 更长的上下文窗口可以提高连贯性，但也会增加内存占用。 | 396 | — | 待盲评 |
| en-zh-terminology-06 | The fine-tuning dataset must remain separate from the held-out evaluation set. | 精细调整的数据集必须与进行评估的数据集分开。 | 微调数据集必须与留出的评测集保持分离。 | 324 | — | 待盲评 |
| en-zh-terminology-07 | Optical character recognition extracts text from the selected screen region. | 光学字符识别从所选择的屏幕区域提取文本。 | 光学字符识别会从选定的屏幕区域中提取文字。 | 355 | — | 待盲评 |
| en-zh-terminology-08 | End-to-end encryption protects content in transit, while local encryption protects data at rest. | 终端加密在过境时保护内容,而本地加密则在休息时保护数据。 | 端到端加密保护传输中的内容，而本地加密保护静态存储的数据。 | 425 | — | 待盲评 |
| en-zh-academic-01 | The results suggest that context improves terminology consistency without increasing factual errors. | 结果表明,背景改善了术语一致性,而不会增加事实错误。 | 结果表明，上下文可以提高术语一致性，而不会增加事实性错误。 | 366 | — | 待盲评 |
| en-zh-academic-02 | The observed association should not be interpreted as evidence of a causal relationship. | 观察到的联系不应被视为因果关系的证据。 | 不应将观察到的关联解释为存在因果关系的证据。 | 324 | — | 待盲评 |
| en-zh-academic-03 | The small sample size limits the generalizability of these findings. | 小型样品大小限制了这些发现的普遍性。 | 样本量较小，限制了这些研究结果的普适性。 | 273 | — | 待盲评 |
| en-zh-academic-04 | The confidence interval was wide, indicating substantial uncertainty in the estimated effect. | 信任间隔广泛,表明估计效应的显著不确定性。 | 置信区间较宽，表明估计效应存在较大的不确定性。 | 382 | — | 待盲评 |
| en-zh-academic-05 | One limitation of the study is that all measurements were collected in a controlled environment. | 研究的一个限制是,所有测量都被收集在控制的环境中。 | 本研究的一个局限是，所有测量数据均在受控环境中采集。 | 374 | — | 待盲评 |
| en-zh-academic-06 | These findings are consistent with the hypothesis, although alternative explanations remain possible. | 这些发现与假设一致,尽管其他解释仍然是可能的。 | 这些结果与该假设一致，但仍可能存在其他解释。 | 312 | — | 待盲评 |
| en-zh-academic-07 | A longitudinal study is needed to determine whether the improvement persists over time. | 需要长期研究,以确定是否随着时间的推移,改善会持续下去。 | 需要开展纵向研究，以确定这种改善是否能随时间持续。 | 366 | — | 待盲评 |
| en-zh-academic-08 | Future work should evaluate the method across languages and under realistic operating conditions. | 未来的工作应该通过语言和现实的运营条件来评估该方法。 | 未来的工作应在多种语言和真实运行条件下评估该方法。 | 327 | — | 待盲评 |
| en-zh-formatting-01 | Version 2.1 costs $0 and uses 512 MB of memory. | 版本 2.1 花费 0 美元,使用 512 MB 的内存。 | 2.1 版本费用为 $0，占用 512 MB 内存。 | 324 | 失败 | 待盲评 |
| en-zh-formatting-02 | Send the request to /v1/translate with Content-Type: application/json. | 发送请求到 /v1/翻译与内容类型:应用程序/json。 | 请将请求发送到 /v1/translate，并使用 Content-Type: application/json。 | 417 | 失败 | 待盲评 |
| en-zh-formatting-03 | The request timed out after 45 seconds with error code E-104. | 请求在 45 秒后以错误代码 E-104 结束。 | 请求在 45 秒后超时，错误码为 E-104。 | 355 | 通过 | 待盲评 |
| en-zh-formatting-04 | Open report_v2.3.pdf at 14:30 and review pages 12–18. | 开放报告_v2.3.pdf 下午 14:30 和评论页面 12–18. | 请在 14:30 打开 report_v2.3.pdf，并检查第 12–18 页。 | 393 | 失败 | 待盲评 |
| en-zh-formatting-05 | Verify SHA-256 before loading model-q8.bin. | 在充电前检查 SHA-256 模型-q8.bin。 | 加载 model-q8.bin 前请校验 SHA-256。 | 317 | 失败 | 待盲评 |
| en-zh-formatting-06 | Peak RAM was 1.5 GB while CPU usage remained below 37%. | 最高的RAM是 1.5 GB 而 CPU 使用率仍然低于 37%. | 峰值 RAM 为 1.5 GB，同时 CPU 使用率保持在 37% 以下。 | 340 | 通过 | 待盲评 |
| en-zh-formatting-07 | Replace {student_name} and keep %score% unchanged. | 取代 {student_name} 并保持 %score% 无变化。 | 请替换 {student_name}，并保持 %score% 不变。 | 357 | 通过 | 待盲评 |
| en-zh-formatting-08 | Keep **Important**, Ctrl+Shift+T, and https://example.invalid/help exactly as written. | 保持 ** Important**、Ctrl+Shift+T 和 https://example.invalid/help 正如所写的那样。 | 请原样保留 **Important**、Ctrl+Shift+T 和 https://example.invalid/help。 | 662 | 失败 | 待盲评 |
| zh-en-completeness-01 | 我把钥匙放在桌上了，出门时别忘了带。 | I put the key on the table and don’t forget to bring it out. | I left the keys on the table. Do not forget to take them when you leave. | 324 | — | 待盲评 |
| zh-en-completeness-02 | 如果明天仍然下雨，我们就把户外活动改到体育馆，而且不会另外收费。 | If tomorrow is still rain, we will change outdoor activities to the gym, and no additional fee. | If it is still raining tomorrow, we will move the outdoor activity to the gym and will not charge an additional fee. | 380 | — | 待盲评 |
| zh-en-completeness-03 | 虽然实验已经结束，但在核对原始记录之前，团队没有公布任何结论。 | Although the experiment was over, the team did not make any conclusions before verifying the original record. | Although the experiment had ended, the team did not publish any conclusions before checking the original records. | 397 | — | 待盲评 |
| zh-en-completeness-04 | 请先下载离线模型，再断开网络测试；否则无法证明翻译完全在本地完成。 | Please first download the offline model and then interrupt the network test; otherwise it cannot be proven that the translation is completely locally completed. | Download the offline model first and then disconnect from the network for testing; otherwise, you cannot prove that the translation was completed entirely locally. | 589 | — | 待盲评 |
| zh-en-completeness-05 | 课程开始前，讲义已经上传，但双语字幕还在校对。 | Before the course begins, the lecture has been uploaded, but the bilingual subtitles are still adjusted. | Before the class began, the handout had been uploaded, but the bilingual subtitles were still being proofread. | 497 | — | 待盲评 |
| zh-en-completeness-06 | 这个工具不但能找出错词，还能说明句子的时态为什么不合适。 | This tool can not only find the wrong word, it can also explain why the phrase’s timing is not suitable. | This tool can not only identify incorrect words but also explain why the tense of the sentence is inappropriate. | 496 | — | 待盲评 |
| zh-en-completeness-07 | 除非用户明确选择在线服务，否则本地失败后也不能自动上传原文。 | Unless the user clearly chooses the online service, it will not be possible to automatically upload the original text after a local failure. | Unless the user explicitly selects an online service, the original text must not be uploaded automatically even after a local failure. | 526 | — | 待盲评 |
| zh-en-completeness-08 | 老师说完成练习后可以看参考答案，但没有说可以跳过听力部分。 | The teacher said he could see reference answers after the exercise was completed, but he didn’t say he could jump over the hearing part. | The teacher said that the students could view the reference answers after completing the exercises, but did not say that they could skip the listening section. | 565 | — | 待盲评 |
| zh-en-terminology-01 | 模型配置变化后，旧缓存必须立即失效。 | After the model configuration changes, the old cache must disappear immediately. | The old cache must be invalidated immediately after the model configuration changes. | 305 | — | 待盲评 |
| zh-en-terminology-02 | 本地推理引擎只加载通过完整性校验的模型包。 | The local reasoning engine is only charged with a model package that passes the integrity test. | The local inference engine loads only model packages that pass integrity verification. | 411 | — | 待盲评 |
| zh-en-terminology-03 | 语音识别完成后，转写稿应保留说话人标签和时间戳。 | After the voice recognition is completed, the transcript should be kept with the speaker label and time mark. | After speech recognition is complete, the transcript should retain speaker labels and timestamps. | 464 | — | 待盲评 |
| zh-en-terminology-04 | 术语表应当覆盖产品名称、缩写和用户指定的固定译法。 | The term tables should cover the product name, abbreviation and fixed translations specified by the user. | The glossary should cover product names, abbreviations, and user-specified fixed translations. | 493 | — | 待盲评 |
| zh-en-terminology-05 | 上下文窗口过短时，长文中的指代关系容易丢失。 | When the upper text window is too short, the indication relationship in the long text is easily lost. | When the context window is too short, coreference relationships in long documents can easily be lost. | 397 | — | 待盲评 |
| zh-en-terminology-06 | 留出评测集不得参与微调或超参数选择。 | The remaining review set shall not be involved in the micronutrient or superparameter selection. | The held-out evaluation set must not be used for fine-tuning or hyperparameter selection. | 431 | — | 待盲评 |
| zh-en-terminology-07 | 光学字符识别结果需要经过版面分析才能恢复阅读顺序。 | The optical character identification results need to be analyzed through the edition to restore the reading order. | Optical character recognition results require layout analysis to restore the reading order. | 422 | — | 待盲评 |
| zh-en-terminology-08 | 静态数据加密不能代替传输层的端到端加密。 | Static data encryption cannot replace end-to-end encryption of the transmission layer. | Encryption for data at rest cannot replace end-to-end encryption at the transport layer. | 445 | — | 待盲评 |
| zh-en-academic-01 | 结果表明，上下文有助于提高术语一致性，但对推理速度有轻微影响。 | The results show that the above text helps to improve the consistency of terms, but has a slight impact on the speed of reasoning. | The results suggest that context helps improve terminology consistency but has a slight impact on inference speed. | 547 | — | 待盲评 |
| zh-en-academic-02 | 该相关性并不足以证明训练方法导致了准确率提升。 | This relevance is not sufficient to prove that training methods lead to increased accuracy. | This correlation is insufficient to prove that the training method caused the improvement in accuracy. | 394 | — | 待盲评 |
| zh-en-academic-03 | 由于样本来自单一场景，这些结果未必适用于其他人群。 | Since the samples come from a single scene, these results do not necessarily apply to other populations. | Because the sample came from a single setting, these findings may not apply to other populations. | 422 | — | 待盲评 |
| zh-en-academic-04 | 较宽的置信区间说明效应估计仍存在较大不确定性。 | There is still a large uncertainty in the explaining effect estimates of the broader confidence range. | The wide confidence interval indicates that substantial uncertainty remains in the effect estimate. | 473 | — | 待盲评 |
| zh-en-academic-05 | 本研究的主要局限在于缺少真实使用环境下的长期观察。 | The main limitation of this study is that there is no long-term observation in real-use environments. | The main limitation of this study is the lack of long-term observation in real-world use. | 430 | — | 待盲评 |
| zh-en-academic-06 | 现有证据与该解释一致，但不能排除其他机制。 | The existing evidence is consistent with that explanation, but no other mechanisms can be excluded. | The available evidence is consistent with this explanation, but other mechanisms cannot be ruled out. | 420 | — | 待盲评 |
| zh-en-academic-07 | 需要通过纵向研究判断学习效果能否在干预结束后保持。 | It is necessary to determine through vertical research whether the learning effect can beined after the end of the intervention. | A longitudinal study is needed to determine whether the learning gains persist after the intervention ends. | 483 | — | 待盲评 |
| zh-en-academic-08 | 未来研究应比较不同语言和设备条件下的性能差异。 | Future research should compare performance differences in different language and equipment conditions. | Future research should compare performance differences across languages and device conditions. | 290 | — | 待盲评 |
| zh-en-formatting-01 | API 请求在 45 秒后超时，错误码为 E-104。 | The API request exceeds 45 seconds and the error code is E-104. | The API request timed out after 45 seconds with error code E-104. | 311 | 通过 | 待盲评 |
| zh-en-formatting-02 | 请向 /v1/models 发送 GET 请求，不要改成 POST。 | Please send a GET request to /v1/models and not change it to POST. | Send a GET request to /v1/models; do not change it to POST. | 359 | 通过 | 待盲评 |
| zh-en-formatting-03 | 安装包大小为 197.23 MiB，版本号是 v0.1.0。 | The installation package is 197.23 MiB and the version number is v0.1.0. | The installation package is 197.23 MiB and the version number is v0.1.0. | 369 | 通过 | 待盲评 |
| zh-en-formatting-04 | 请在 09:15 打开 chapter_04.docx，并阅读第 21–26 页。 | Please open chapter_04.docx at 9:15 and read the 21–26 pages. | Open chapter_04.docx at 09:15 and read pages 21–26. | 353 | 失败 | 待盲评 |
| zh-en-formatting-05 | 文件 model-int8.bin 的 SHA-256 必须与清单一致。 | The SHA-256 for the file model-int8.bin must be consistent with the list. | The SHA-256 of model-int8.bin must match the manifest. | 381 | 通过 | 待盲评 |
| zh-en-formatting-06 | GPU 占用为 0%，峰值 RAM 为 842 MB。 | The GPU occupies 0%, the top RAM is 842 MB. | GPU usage was 0%, and peak RAM was 842 MB. | 292 | 通过 | 待盲评 |
| zh-en-formatting-07 | 把 {course_title} 替换为课程名，但保留 ${price}。 | Replace {course_title} with the course name, but keep ${price}. | Replace {course_title} with the course name, but preserve ${price}. | 409 | 通过 | 待盲评 |
| zh-en-formatting-08 | 不要翻译 `model_id`、Ctrl+L 和 https://example.invalid/docs。 | Do not translate `model_id`, Ctrl+L and https://example.invalid/docs. | Do not translate `model_id`, Ctrl+L, or https://example.invalid/docs. | 459 | 通过 | 待盲评 |
