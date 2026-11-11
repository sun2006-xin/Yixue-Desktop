# 第三方组件、模型与词典数据说明

根目录 `LICENSE` 只授权译学原创软件源码，不会把第三方依赖、模型、数据集、品牌图像或商标改为 Apache-2.0。

## Windows 下载包中的翻译运行时与模型

| 内容 | 来源/版本 | 许可与随包说明 |
| --- | --- | --- |
| CTranslate2 | 4.8.2 | MIT；完整文本见 `licenses/CTranslate2-LICENSE.txt`。 |
| SentencePiece | 0.2.2 | Apache-2.0；完整文本见 `licenses/SentencePiece-LICENSE.txt`。 |
| OPUS-MT 英译中 | Helsinki-NLP `opus-mt-en-zh` 固定版本，CTranslate2 INT8 转换 | Apache-2.0；来源、提交和转换说明见 `licenses/OPUS-MT-NOTICES.txt` 与 `licenses/OPUS-MT-en-zh-APACHE-2.0.txt`。 |
| OPUS-MT 中译英 | Helsinki-NLP `opus-mt-zh-en` 固定版本，CTranslate2 INT8 转换 | CC BY 4.0；来源与转换说明见 `licenses/OPUS-MT-NOTICES.txt`、`licenses/OPUS-MT-zh-en-CC-BY-4.0.txt`。 |

## 开放词典与例句数据

| 内容 | 来源 | 许可与边界 |
| --- | --- | --- |
| ECDICT 词典基础数据 | ECDICT | MIT；见 `licenses/ECDICT-LICENSE.txt`。 |
| Wiktionary 词义候选 | Kaikki 导出的 English Wiktionary 数据 | 按来源条目的 CC BY-SA 4.0 / GFDL 条款署名并遵守相同方式共享要求；许可文本见 `licenses/CC-BY-SA-4.0-legalcode.html`、`licenses/GNU-FDL-1.2.txt`，数据说明见 `licenses/KAIKKI-WIKTIONARY-NOTICE.md`。 |
| Tatoeba 英汉例句候选 | Tatoeba 文本语料 | CC BY 2.0 France。项目级归因：句对来自 [Tatoeba](https://tatoeba.org)，并注明 CC BY 2.0 FR；应用保留并展示句对贡献者用户名。许可文本见 `licenses/CC-BY-2.0-FR-legalcode.html`，来源说明见 `licenses/TATOEBA-NOTICE.md`。 |
| WordNet 3.0 | Princeton University | 保留版权与免责声明并遵守其许可；见 `licenses/WordNet-3.0-LICENSE.txt`。 |

这些开放数据仍可能标为候选或待审校。来源开放不等于内容已经过译学人工审核，也不等于译学对其准确性背书。

## 其他内容

- 多语种 Whisper ASR 权重不会随此 Windows 压缩包分发；应用仅在用户主动下载时获取。来源及权利边界见 `licenses/WHISPER-MULTILINGUAL-ASR-NOTICE.md`。
- Fork 或本地补丁的 Flutter 插件分别保留在 `third_party/`，其原许可证与修改说明存放在各自目录中。
- Flutter/Dart 与 Rust 的第三方依赖版本由 `app/yixue_app/pubspec.lock` 和 `Cargo.lock` 固定。Flutter 生成的 `data/NOTICES.Z` 以及本目录中的许可证清单应与 Windows 包一同保留。
- 译学品牌资源不属于 Apache-2.0 授权范围，见 [`assets/brand/README.md`](assets/brand/README.md)。
