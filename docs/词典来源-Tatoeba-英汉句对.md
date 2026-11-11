# Tatoeba 英汉句对候选来源登记

用途：为 CET4/CET6 基础词目补充自然英汉例句候选。当前只生成编辑候选，不把 Tatoeba 句子直接发布到译学官方词典。

## 来源与许可

- 官方下载页：[Tatoeba Downloads](https://tatoeba.org/en/downloads)。
- 英文详细句子：[eng_sentences_detailed.tsv.bz2](https://downloads.tatoeba.org/exports/per_language/eng/eng_sentences_detailed.tsv.bz2)。
- 中文详细句子：[cmn_sentences_detailed.tsv.bz2](https://downloads.tatoeba.org/exports/per_language/cmn/cmn_sentences_detailed.tsv.bz2)。
- 英汉链接：[eng-cmn_links.tsv.bz2](https://downloads.tatoeba.org/exports/per_language/eng/eng-cmn_links.tsv.bz2)。
- 本次快照日期：`2026-09-12`。
- Tatoeba 官方将下载的文本数据按 CC BY 2.0 France 提供，并提供项目级归因指引。当前应用切片保留句子 ID 和两侧用户名；修改日期未进入运行时文件。CC0 仅适用于 Tatoeba 规则允许的原创句子，翻译须遵守原句许可。
- 本批不下载或使用音频；音频有独立作者、许可证和归因 URL，不能随文本自动继承。

## 哈希

- `eng_sentences_detailed.tsv.bz2`: `40283f993461d457c9a2d7151f7ae50a0a6a9facb41e98911fd4714eb8d701a7`
- `cmn_sentences_detailed.tsv.bz2`: `be67aced37c6df79965abf12d8d6cd8af982027d5162d81a8cecd1957ec2428e`
- `eng-cmn_links.tsv.bz2`: `c0a1afc00b789664c1a45a12acc4d2f5300f764e54bd216096979ad9d4973b75`

## 转换结果

- 输入目标：5,759 条 `open-ecdict` CET4/CET6 去重基础词目。
- 匹配结果：4,251 条至少有一个英汉句对；1,508 条当前未找到直接英汉句对。
- 每条最多保留 3 个确定性排序的句对候选；上游候选数据保留英文/中文句子 ID、两边用户名和修改日期。当前运行时切片保留句子 ID、用户名与文本，未打包修改日期。
- Windows 预览包在 `licenses/TATOEBA-NOTICE.md` 附带来源、项目级署名和许可文本；词汇学习界面显示 Tatoeba 来源及两侧作者用户名。运行时仍标记候选、不把它计为译学原创或人工审校例句。
- 从英文句对中提取的相邻词组只登记为 `collocation_candidates`，用于编辑复核；它们是语料共现，不自动等于固定搭配或推荐用法。
- 句对不会被机器翻译改写；有句对只代表“有开放候选”，不代表译文已被译学项目人工审定。
- 当前候选仍为 `draft`，不代表编辑审核或教学质量保证。语域/语用、中文准确性和人工复核仍待逐步完成。
