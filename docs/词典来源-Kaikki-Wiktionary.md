# 词典来源：Kaikki/Wiktionary 英语逐词候选层

## 来源和版本

- 来源项目：[Kaikki raw data downloads](https://kaikki.org/dictionary/rawdata.html)。
- 本批使用英文版 Wiktextract 的逐词 JSONL 页面，而不是下载约 2.66GB 的英文全量压缩包。
- 官方页面所列本次数据来自 2026-09-02 的 English Wiktionary dump，Kaikki 数据抽取版本为 2026-09-09；版本变化必须重新抓取并重新生成报告。
- 每词页面格式：`https://kaikki.org/dictionary/English/meaning/{首字母}/{前两字符}/{词}.jsonl`。
- 本地缓存目录：`.tmp/dictionary-sources/kaikki-2026-09/words/`，仅用于本地重建和来源核对，不作为 Flutter 运行时自动下载目录。
- 输出层：`data/dictionary/editorial-candidates-v2.json`，该目录被 `.gitignore` 忽略；可使用 `tool/build_dictionary_kaikki_layer.py` 从基础候选重新生成。

## 许可和分发边界

Wiktionary 内容按照 [Wiktionary FAQ](https://en.wiktionary.org/wiki/Help:FAQ) 和 [CC BY-SA 说明](https://en.wiktionary.org/wiki/Wiktionary:CC-BY-SA) 使用，候选记录保留 `CC BY-SA 4.0` / `GFDL` 双许可标记。该层是独立的开放参考候选层，不能与译学自写层合并后重新声明为单一译学许可，也不能在没有署名、相同方式共享和许可证核对的情况下随安装包发布。

当前解析器只保留结构化词性、音标、词形、义项、中文翻译、关系和 `type=example` 的短例句；不下载音频，不保留引文型长文本，不把原文自动改写成译学释义。每个页面记录 URL、缓存文件、字节数和 SHA-256；页面内容发生变化时必须重新审计。

## 本批结果（2026-09-15）

- 目标词：5,759 条 CET4/CET6 开放基础词目。
- 可追溯页面：5,759/5,759；其中 `Fahrenheit` 使用大小写页面，`reservior` 保留原始请求词并通过显式 `reservoir` 别名候选关联，不能视为已经自动改正。
- 英文词性记录：12,058 条。
- 初始精确页缺少音标的词进入富语义审校补充流程；目前其中 9 条通过明确关联页获得 `candidate` 音标，3 条（`first-rate`、`sitting-room`、`videotape`）仍无可直接使用的音标候选。关联页不改变请求词条，也不代表音标已经审校。
- 有词形候选的目标词：5,659 条。
- 有英文例句候选的目标词：5,369 条。
- 有中文翻译候选的目标词：以记录/词性为统计单位为 5,918 条记录，不能直接等同于 5,918 个词。
- 与 Tatoeba 英汉句对合并后，有双语例句候选的目标词：4,251 条；1,508 条仍需补充或人工自写。
- 所有条目质量状态仍为 `draft`；未审校条目不得进入公开索引。

## 重建命令

```powershell
python tool/build_dictionary_kaikki_layer.py `
  --input data/dictionary/editorial-candidates-v1.json `
  --output data/dictionary/editorial-candidates-v2.json `
  --report-output data/dictionary/editorial-candidates-v2.report.json `
  --cache-dir .tmp/dictionary-sources/kaikki-2026-09/words `
  --workers 6

python tool/build_dictionary_rich_candidates.py
python tool/build_dictionary_review_queue.py
```

## 发布前禁止事项

1. 不把 Kaikki/Wiktionary 的英文义项或中文翻译直接标成译学自写。
2. 不把机器候选批量改成 `reviewed` 或 `published`。
3. 不复制牛津纸质版或网页的定义、例句、音频、排版或整库；纸质牛津只可作为用户个人参考资料。
4. 不把存在 Tatoeba 句对当作无需审核；必须保留作者署名、句子 ID、许可和中英文语境复核记录。
5. 不把 `reservior` 的别名候选当成已经完成的拼写修订；应由编辑决定原词保留、纠错提示和学习跳转方式。

## 运行时候选层（2026-09-15）

为让快速翻译实际读到已下载的开放候选，项目新增 `build_dictionary_runtime_candidates.py`，从富语义 v3 文件提取带稳定 ID 的 Tatoeba 英汉句对，以及词形、搭配和关系候选，生成 8 个例句分片和 8 个元数据分片。运行时仍保留 `candidate` 标记；开放来源例句在界面显示“待人工审校”，不会被覆盖报告计为 `published`。

本批运行时接入 4,251 个词的 10,333 条双语句对候选和全部 5,759 个词的元数据候选。候选层的来源、许可证和作者字段仍以 v3/来源登记为准；没有双语句对的词继续显示缺口，不使用占位译文。

运行时还接入了 Kaikki 参与的来源隔离义项候选：每词最多 24 条义项、每义项最多 8 条释义和 3 条来源例句；中文翻译候选只保留没有替换字符的文本。Kaikki 的英语释义、中文候选、语用标签和例句仍标为 `candidate`，不覆盖译学自写层，也不因进入快速翻译界面而变成可公开发布内容。

当精确页没有音标而存在明确的拼写或词形关联页时，解析器会把关联页放入 `pronunciation_alias_pages`，而不是把它伪装成精确页。富语义层进一步保存 `source_word` 和 `resolution=audited_alias_candidate`；这类记录必须单独核对当前词形是否适用。
