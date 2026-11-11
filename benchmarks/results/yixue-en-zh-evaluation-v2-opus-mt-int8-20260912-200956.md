# yixue-en-zh-evaluation-v2 · OPUS-MT INT8 基准

- 样例：64
- 延迟：平均 131.52 ms；P50 126 ms；P95 180 ms；最大 313 ms
- 峰值工作集：139 MiB
- 格式保留：5/16

| ID | 原文 | 模型译文 | 参考译文 | 耗时 ms | 格式 | 人工评分 |
|---|---|---|---|---:|---|---|
| en-zh-completeness-01 | Could you open the window? It is getting warm in here. | 你能打开窗户吗? | 你能把窗户打开吗？这里开始变热了。 | 69 | — | 待盲评 |
| en-zh-completeness-02 | If the update fails, the application will keep the previous version and no files will be uploaded. | 如果更新失败, 应用程序将保留上一个版本, 并且不会上传任何文件 。 | 如果更新失败，应用将保留先前版本，而且不会上传任何文件。 | 149 | — | 待盲评 |
| en-zh-completeness-03 | Although the report was ready, the researcher did not send it because two figures had not been verified. | 尽管报告已经准备好,但研究人员没有寄出,因为两个数字没有被核实。 | 虽然报告已经完成，但研究人员没有发送，因为其中两幅图还没有经过核验。 | 130 | — | 待盲评 |
| en-zh-completeness-04 | Please save the draft before closing the reader; otherwise, your unsaved annotations will be lost. | 请在关闭读者前保存草稿; 否则的话, 您的未保存的注释将会丢失 。 | 关闭阅读器前请保存草稿，否则未保存的批注将会丢失。 | 145 | — | 待盲评 |
| en-zh-completeness-05 | By the time the class began, the subtitles had been corrected but the summary was still being generated. | 上课开始时,字幕已经更正,但摘要仍在制作中。 | 课程开始时，字幕已经校正完毕，但总结仍在生成。 | 105 | — | 待盲评 |
| en-zh-completeness-06 | The system not only recognized the speaker's question but also linked the answer to the correct timestamp. | 该系统不仅承认发言者的问题,而且还将答案与正确的时间戳联系起来。 | 系统不仅识别出了发言者的问题，还把答案关联到了正确的时间点。 | 120 | — | 待盲评 |
| en-zh-completeness-07 | Unless you enable cloud sync yourself, every note remains only on this computer. | 除非你能让云层同步自己 否则每个音符都只留在电脑上 | 除非你主动启用云同步，否则所有笔记都只保留在这台电脑上。 | 141 | — | 待盲评 |
| en-zh-completeness-08 | She said that he could join the discussion after finishing the experiment, but she did not promise to wait. | 她说,他可以在试验结束后参加讨论,但她没有答应等待。 | 她说他做完实验后可以参加讨论，但她没有答应等他。 | 118 | — | 待盲评 |
| en-zh-terminology-01 | The cache is invalidated whenever the model configuration changes. | 当模型配置改变时,缓存将无效 。 | 每当模型配置发生变化时，缓存都会失效。 | 87 | — | 待盲评 |
| en-zh-terminology-02 | The local inference engine verifies the model package before loading it. | 本地推论引擎在装货前验证模型包。 | 本地推理引擎会在加载模型包之前对其进行校验。 | 108 | — | 待盲评 |
| en-zh-terminology-03 | The speech recognizer produced a transcript with word-level timestamps. | 语音识别器制作了一份文字级别时间戳的文字记录。 | 语音识别器生成了一份带逐词时间戳的转写稿。 | 98 | — | 待盲评 |
| en-zh-terminology-04 | A user-defined glossary should override the model's default translation for approved terms. | 用户定义的词汇表应取代模型的默认译文,以取代核定术语。 | 对于已经确认的术语，用户自定义术语表应覆盖模型的默认译法。 | 134 | — | 待盲评 |
| en-zh-terminology-05 | A longer context window can improve coherence, but it also increases memory usage. | 较长的上下文窗口可以提高一致性,但也增加记忆的使用。 | 更长的上下文窗口可以提高连贯性，但也会增加内存占用。 | 112 | — | 待盲评 |
| en-zh-terminology-06 | The fine-tuning dataset must remain separate from the held-out evaluation set. | 微调数据集必须与搁置评价数据集分开。 | 微调数据集必须与留出的评测集保持分离。 | 74 | — | 待盲评 |
| en-zh-terminology-07 | Optical character recognition extracts text from the selected screen region. | 光学字符识别从选定的屏幕区域提取文字。 | 光学字符识别会从选定的屏幕区域中提取文字。 | 92 | — | 待盲评 |
| en-zh-terminology-08 | End-to-end encryption protects content in transit, while local encryption protects data at rest. | 端对端加密保护过境内容,而本地加密则保护休息时的数据。 | 端到端加密保护传输中的内容，而本地加密保护静态存储的数据。 | 125 | — | 待盲评 |
| en-zh-academic-01 | The results suggest that context improves terminology consistency without increasing factual errors. | 结果显示,背景情况提高了术语的一致性,而没有增加事实错误。 | 结果表明，上下文可以提高术语一致性，而不会增加事实性错误。 | 107 | — | 待盲评 |
| en-zh-academic-02 | The observed association should not be interpreted as evidence of a causal relationship. | 被观察的社团不应被解释为因果关系的证据。 | 不应将观察到的关联解释为存在因果关系的证据。 | 83 | — | 待盲评 |
| en-zh-academic-03 | The small sample size limits the generalizability of these findings. | 样本规模小限制了这些调查结果的可概括性。 | 样本量较小，限制了这些研究结果的普适性。 | 93 | — | 待盲评 |
| en-zh-academic-04 | The confidence interval was wide, indicating substantial uncertainty in the estimated effect. | 信心间隔很宽,表明估计效果有很大不确定性。 | 置信区间较宽，表明估计效应存在较大的不确定性。 | 86 | — | 待盲评 |
| en-zh-academic-05 | One limitation of the study is that all measurements were collected in a controlled environment. | 研究的一个局限是,所有测量都是在受控制的环境中采集的。 | 本研究的一个局限是，所有测量数据均在受控环境中采集。 | 112 | — | 待盲评 |
| en-zh-academic-06 | These findings are consistent with the hypothesis, although alternative explanations remain possible. | 这些调查结果与假设一致,但仍有可能作出其他解释。 | 这些结果与该假设一致，但仍可能存在其他解释。 | 96 | — | 待盲评 |
| en-zh-academic-07 | A longitudinal study is needed to determine whether the improvement persists over time. | 需要进行纵向研究,以确定这种改善是否长期存在。 | 需要开展纵向研究，以确定这种改善是否能随时间持续。 | 87 | — | 待盲评 |
| en-zh-academic-08 | Future work should evaluate the method across languages and under realistic operating conditions. | 今后的工作应在现实的运作条件下评估跨语言的方法。 | 未来的工作应在多种语言和真实运行条件下评估该方法。 | 79 | — | 待盲评 |
| en-zh-formatting-01 | Version 2.1 costs $0 and uses 512 MB of memory. | 第2.1版费用为0美元,使用512MB内存。 | 2.1 版本费用为 $0，占用 512 MB 内存。 | 132 | 失败 | 待盲评 |
| en-zh-formatting-02 | Send the request to /v1/translate with Content-Type: application/json. | 将请求发送到/v1/ / 翻译内容- 类型: 应用程序/ json 。 | 请将请求发送到 /v1/translate，并使用 Content-Type: application/json。 | 180 | 失败 | 待盲评 |
| en-zh-formatting-03 | The request timed out after 45 seconds with error code E-104. | 请求在45秒后暂停,并附有错误代码E-104。 | 请求在 45 秒后超时，错误码为 E-104。 | 123 | 通过 | 待盲评 |
| en-zh-formatting-04 | Open report_v2.3.pdf at 14:30 and review pages 12–18. | 公开报告_v2.3.pdf,第230页和评论第12-18页。 | 请在 14:30 打开 report_v2.3.pdf，并检查第 12–18 页。 | 172 | 失败 | 待盲评 |
| en-zh-formatting-05 | Verify SHA-256 before loading model-q8.bin. | 在装入模型q8.bin之前核查 SHA -256。 | 加载 model-q8.bin 前请校验 SHA-256。 | 122 | 失败 | 待盲评 |
| en-zh-formatting-06 | Peak RAM was 1.5 GB while CPU usage remained below 37%. | 峰值内存为1.5GB,而CPU的使用率仍低于37%。 | 峰值 RAM 为 1.5 GB，同时 CPU 使用率保持在 37% 以下。 | 143 | 失败 | 待盲评 |
| en-zh-formatting-07 | Replace {student_name} and keep %score% unchanged. | 替换 {学生_name} 并保持 %score% 不变。 | 请替换 {student_name}，并保持 %score% 不变。 | 145 | 失败 | 待盲评 |
| en-zh-formatting-08 | Keep **Important**, Ctrl+Shift+T, and https://example.invalid/help exactly as written. | ** 保持进口** 、 Ctrl+Shifft+T 和 https://example.invalid/help 与书面内容完全相同。 | 请原样保留 **Important**、Ctrl+Shift+T 和 https://example.invalid/help。 | 313 | 失败 | 待盲评 |
| zh-en-completeness-01 | 我把钥匙放在桌上了，出门时别忘了带。 | I left the keys on the table, so don't forget to take them when you're out. | I left the keys on the table. Do not forget to take them when you leave. | 175 | — | 待盲评 |
| zh-en-completeness-02 | 如果明天仍然下雨，我们就把户外活动改到体育馆，而且不会另外收费。 | If it still rains tomorrow, we will change the outdoors to the gym, without additional charges. | If it is still raining tomorrow, we will move the outdoor activity to the gym and will not charge an additional fee. | 174 | — | 待盲评 |
| zh-en-completeness-03 | 虽然实验已经结束，但在核对原始记录之前，团队没有公布任何结论。 | Although the experiment was completed, the team did not publish any conclusions until the original records were checked. | Although the experiment had ended, the team did not publish any conclusions before checking the original records. | 158 | — | 待盲评 |
| zh-en-completeness-04 | 请先下载离线模型，再断开网络测试；否则无法证明翻译完全在本地完成。 | Please download the offline model before disconnecting the network test; otherwise it cannot be proved that the translation was done entirely locally. | Download the offline model first and then disconnect from the network for testing; otherwise, you cannot prove that the translation was completed entirely locally. | 186 | — | 待盲评 |
| zh-en-completeness-05 | 课程开始前，讲义已经上传，但双语字幕还在校对。 | The lectures were uploaded before the beginning of the course, but bilingual subtitles were still in school. | Before the class began, the handout had been uploaded, but the bilingual subtitles were still being proofread. | 145 | — | 待盲评 |
| zh-en-completeness-06 | 这个工具不但能找出错词，还能说明句子的时态为什么不合适。 | This tool not only identifies the wrong words, but also explains why the current state of the sentence is not appropriate. | This tool can not only identify incorrect words but also explain why the tense of the sentence is inappropriate. | 157 | — | 待盲评 |
| zh-en-completeness-07 | 除非用户明确选择在线服务，否则本地失败后也不能自动上传原文。 | Local failure does not allow for automatic uploading of the original text unless the user explicitly selects the online service. | Unless the user explicitly selects an online service, the original text must not be uploaded automatically even after a local failure. | 166 | — | 待盲评 |
| zh-en-completeness-08 | 老师说完成练习后可以看参考答案，但没有说可以跳过听力部分。 | The teacher said that after completing the exercise, he could see the answer, but not the hearing part. | The teacher said that the students could view the reference answers after completing the exercises, but did not say that they could skip the listening section. | 150 | — | 待盲评 |
| zh-en-terminology-01 | 模型配置变化后，旧缓存必须立即失效。 | The old cache must lapse immediately after the model configuration changes. | The old cache must be invalidated immediately after the model configuration changes. | 85 | — | 待盲评 |
| zh-en-terminology-02 | 本地推理引擎只加载通过完整性校验的模型包。 | The local reasoning engine only loads a model package that has been verified through integrity. | The local inference engine loads only model packages that pass integrity verification. | 123 | — | 待盲评 |
| zh-en-terminology-03 | 语音识别完成后，转写稿应保留说话人标签和时间戳。 | When speech recognition is completed, the transliteration should retain a talking person label and a time stamp. | After speech recognition is complete, the transcript should retain speaker labels and timestamps. | 150 | — | 待盲评 |
| zh-en-terminology-04 | 术语表应当覆盖产品名称、缩写和用户指定的固定译法。 | The glossary should cover product names, abbreviations and fixed translations specified by the user. | The glossary should cover product names, abbreviations, and user-specified fixed translations. | 117 | — | 待盲评 |
| zh-en-terminology-05 | 上下文窗口过短时，长文中的指代关系容易丢失。 | When the context window is too short, the line in the long text is easily lost. | When the context window is too short, coreference relationships in long documents can easily be lost. | 138 | — | 待盲评 |
| zh-en-terminology-06 | 留出评测集不得参与微调或超参数选择。 | Leave the assessment set free to participate in fine-tuning or hyperparametric selection. | The held-out evaluation set must not be used for fine-tuning or hyperparameter selection. | 126 | — | 待盲评 |
| zh-en-terminology-07 | 光学字符识别结果需要经过版面分析才能恢复阅读顺序。 | The optical character recognition results require a copy analysis to restore the reading order. | Optical character recognition results require layout analysis to restore the reading order. | 107 | — | 待盲评 |
| zh-en-terminology-08 | 静态数据加密不能代替传输层的端到端加密。 | Static data encryption does not replace end-to-end encryption of the transmission layer. | Encryption for data at rest cannot replace end-to-end encryption at the transport layer. | 125 | — | 待盲评 |
| zh-en-academic-01 | 结果表明，上下文有助于提高术语一致性，但对推理速度有轻微影响。 | The results showed that the context contributed to improved consistency of terminology, but had a slight impact on the speed of reasoning. | The results suggest that context helps improve terminology consistency but has a slight impact on inference speed. | 167 | — | 待盲评 |
| zh-en-academic-02 | 该相关性并不足以证明训练方法导致了准确率提升。 | This relevance is not sufficient to demonstrate that the training methodology has led to an increase in the accuracy rate. | This correlation is insufficient to prove that the training method caused the improvement in accuracy. | 146 | — | 待盲评 |
| zh-en-academic-03 | 由于样本来自单一场景，这些结果未必适用于其他人群。 | Since the samples came from a single scenario, the results did not necessarily apply to other groups of people. | Because the sample came from a single setting, these findings may not apply to other populations. | 144 | — | 待盲评 |
| zh-en-academic-04 | 较宽的置信区间说明效应估计仍存在较大不确定性。 | The broader confidence-between-procedure effect is estimated to remain highly uncertain. | The wide confidence interval indicates that substantial uncertainty remains in the effect estimate. | 121 | — | 待盲评 |
| zh-en-academic-05 | 本研究的主要局限在于缺少真实使用环境下的长期观察。 | The main limitation of this study is the lack of long-term observations in a real-use environment. | The main limitation of this study is the lack of long-term observation in real-world use. | 144 | — | 待盲评 |
| zh-en-academic-06 | 现有证据与该解释一致，但不能排除其他机制。 | The available evidence is consistent with that interpretation, but other mechanisms cannot be excluded. | The available evidence is consistent with this explanation, but other mechanisms cannot be ruled out. | 122 | — | 待盲评 |
| zh-en-academic-07 | 需要通过纵向研究判断学习效果能否在干预结束后保持。 | Longitudinal studies are needed to determine whether learning results can be sustained after the intervention has ended. | A longitudinal study is needed to determine whether the learning gains persist after the intervention ends. | 151 | — | 待盲评 |
| zh-en-academic-08 | 未来研究应比较不同语言和设备条件下的性能差异。 | Future studies should compare performance differences in different languages and equipment conditions. | Future research should compare performance differences across languages and device conditions. | 92 | — | 待盲评 |
| zh-en-formatting-01 | API 请求在 45 秒后超时，错误码为 E-104。 | API requests timeout after 45 seconds with the error code E-104. | The API request timed out after 45 seconds with error code E-104. | 121 | 通过 | 待盲评 |
| zh-en-formatting-02 | 请向 /v1/models 发送 GET 请求，不要改成 POST。 | Please send the GET request to / v1/models and do not change to POST. | Send a GET request to /v1/models; do not change it to POST. | 145 | 失败 | 待盲评 |
| zh-en-formatting-03 | 安装包大小为 197.23 MiB，版本号是 v0.1.0。 | Installation package size 197.23 MiB, version number v1.0. | The installation package is 197.23 MiB and the version number is v0.1.0. | 140 | 失败 | 待盲评 |
| zh-en-formatting-04 | 请在 09:15 打开 chapter_04.docx，并阅读第 21–26 页。 | Please open Chapter_04.docx at 0915 and read pages 21-26. | Open chapter_04.docx at 09:15 and read pages 21–26. | 141 | 失败 | 待盲评 |
| zh-en-formatting-05 | 文件 model-int8.bin 的 SHA-256 必须与清单一致。 | The document model-int8.bin SHA-256 must be consistent with the list. | The SHA-256 of model-int8.bin must match the manifest. | 127 | 通过 | 待盲评 |
| zh-en-formatting-06 | GPU 占用为 0%，峰值 RAM 为 842 MB。 | GPU is 0% occupied and peak RAM is 842 MB. | GPU usage was 0%, and peak RAM was 842 MB. | 105 | 通过 | 待盲评 |
| zh-en-formatting-07 | 把 {course_title} 替换为课程名，但保留 ${price}。 | Replace {course_title} with a course name, but keep ${price}. | Replace {course_title} with the course name, but preserve ${price}. | 142 | 通过 | 待盲评 |
| zh-en-formatting-08 | 不要翻译 `model_id`、Ctrl+L 和 https://example.invalid/docs。 | Do not translate `model_id ' , Ctrl+L and https://example.invalid/docs. | Do not translate `model_id`, Ctrl+L, or https://example.invalid/docs. | 247 | 失败 | 待盲评 |
