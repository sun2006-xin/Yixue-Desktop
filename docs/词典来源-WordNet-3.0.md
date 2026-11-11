# WordNet 3.0 候选来源登记

用途：为 CET4/CET6 开放基础词目生成可追溯的英文义项、例句候选和词义关系。它目前是编辑候选来源，不是已经发布的译学词典包。

## 来源与许可

- 来源：Princeton WordNet 3.0。
- 官方来源：[WordNet 3.0 package documentation](https://wordnet.princeton.edu/documentation/wnpkgs7wn)。
- 官方许可：[WordNet License and Commercial Use](https://wordnet.princeton.edu/license-and-commercial-use)。
- 下载地址：`https://wordnetcode.princeton.edu/3.0/WordNet-3.0.tar.gz`。
- 下载包 SHA-256：`640db279c949a88f61f851dd54ebbb22d003f8b90b85267042ef85a3781d3a52`。
- 许可原文随项目保存于 [`third_party/dictionary_sources/WordNet-3.0-LICENSE.txt`](../third_party/dictionary_sources/WordNet-3.0-LICENSE.txt)。
- 许可要求：保留版权、许可和免责声明；不得使用 Princeton/Princeton University 名称为分发做广告或宣传；本项目不把 WordNet 内容重新声明为“译学自写”。

## 本批转换记录

- 工具：[`tool/build_dictionary_editorial_candidates.py`](../tool/build_dictionary_editorial_candidates.py)。
- 输入：项目内 `open-ecdict` CET4/CET6 去重基础层，共 5,759 条。
- 输出：`data/dictionary/editorial-candidates-v1.json`（本地生成，原始开放数据目录不随运行时安装包自动发布）。
- 状态：所有输出条目固定为 `draft`；中文基础释义与 WordNet 英文释义/关系分开保存。
- 结果：5,705 条匹配 WordNet；4,618 条带开放英文例句；54 条暂未匹配；1,141 条没有 WordNet 英文例句。
- 当前未完成字段：双语例句、搭配、语域/语用人工核对和人工复核。没有合法中文例句来源时，工具不生成猜测译文。

## 数据边界

WordNet 是英英词义关系数据库，不是英汉词典，也不等于牛津词典。后续需要单独接入许可清楚的双语例句来源或由译学项目逐条自写并复核；在质量闸门通过前，候选不能进入 `DictionaryCatalogIndex` 的发布查询，也不能作为“全部单词已完成”的宣传依据。
