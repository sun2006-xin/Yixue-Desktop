# ECDICT 原始快照来源登记

用途：为 CET4/CET6 基础词目补充词形变化、考试/频率标签和原始英文释义候选。中文基础词目仍以项目已登记的 `open-ecdict` 行为主，所有字段保持来源分离。

- 官方仓库：[skywind3000/ECDICT](https://github.com/skywind3000/ECDICT)。
- 原始文件：[ecdict.csv](https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv)。
- 本次快照：`master`，下载日期 `2026-09-15`。
- 文件 SHA-256：`1a6947e04785db63613a92e14903cdae7954f7e84860b10e68e5c7bb3f9c3cf`。
- 许可：[ECDICT LICENSE](https://github.com/skywind3000/ECDICT/blob/master/LICENSE)，原文副本见 [`third_party/dictionary_sources/ECDICT-LICENSE.txt`](../third_party/dictionary_sources/ECDICT-LICENSE.txt)。

## 使用字段与边界

- 使用 `exchange` 补充动词时态、名词复数、形容词比较级/最高级等变体。
- 使用 `tag`、`bnc`、`frq` 作为学习排序和筛选候选，不把它们当作官方考试范围证明。
- 使用 `definition` 作为英文释义候选；它不是牛津内容，也不自动进入已发布中文义项。
- `detail` 和 `audio` 本批不进入输出；音频另需逐条许可审查。
- 所有由此生成的条目仍为 `draft`，需经过中文义项、语境、例句、搭配和人工复核闸门。
