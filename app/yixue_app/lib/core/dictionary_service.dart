import 'dictionary_yx500_entries.dart';
import 'dictionary_cet4_entries.dart';
import 'dictionary_cet_open_entries.dart';
import 'dictionary_cet_open_rich_examples.dart';
import 'dictionary_cet_open_rich_examples_model.dart';
import 'dictionary_cet_open_rich_metadata.dart';
import 'dictionary_cet_open_rich_senses.dart';
import 'dictionary_cet_open_assistant_verified.dart';

class DictionaryEntry {
  const DictionaryEntry({
    required this.word,
    required this.ipa,
    required this.partOfSpeech,
    required this.meanings,
    required this.example,
    required this.exampleTranslation,
    this.coverageBands = const ['foundation'],
    this.source = 'yixue-basic',
    this.exampleCandidates = const [],
    this.senseCandidates = const [],
    this.partOfSpeechCandidates = const [],
    this.pronunciationCandidates = const [],
    this.learningTags = const [],
    this.frequency = const {},
    this.qualityStatus = 'published',
    this.reviewFields = const [],
    this.candidateSourceIds = const [],
    this.variants = const [],
    this.collocationCandidates = const [],
    this.relationCandidates = const {},
  });

  final String word;
  final String ipa;
  final String partOfSpeech;
  final List<String> meanings;
  final String example;
  final String exampleTranslation;
  final List<String> coverageBands;
  final String source;
  final List<OpenCetRichExampleRow> exampleCandidates;
  final List<OpenCetRichSenseRow> senseCandidates;
  final List<OpenCetRichPartOfSpeechRow> partOfSpeechCandidates;
  final List<OpenCetRichPronunciationRow> pronunciationCandidates;
  final List<String> learningTags;
  final Map<String, int> frequency;
  final String qualityStatus;
  final List<String> reviewFields;
  final List<String> candidateSourceIds;
  final List<String> variants;
  final List<String> collocationCandidates;
  final Map<String, List<String>> relationCandidates;

  bool get hasExample =>
      example.trim().isNotEmpty && exampleTranslation.trim().isNotEmpty;

  /// Whether the canonical bilingual example is published for practice.
  /// Candidate enrichments are stored separately and are never used as the
  /// exercise text by this predicate.
  bool get isApprovedSentencePracticeEntry =>
      hasExample &&
      const {
        'published',
        'published_with_candidate_enrichment',
        'published_with_assistant_enrichment',
      }.contains(qualityStatus);

  bool get hasCandidateExamples => exampleCandidates.isNotEmpty;

  bool get exampleIsOpenCandidate =>
      source == openCetDictionarySourceId && hasCandidateExamples;

  bool get hasCandidateSenses => senseCandidates.isNotEmpty;

  List<String> get sourceExampleCandidates => [
    for (final sense in senseCandidates)
      for (final example in sense.sourceExamples)
        if (example.trim().isNotEmpty) example,
  ];

  bool get hasCandidateMetadata =>
      variants.isNotEmpty ||
      collocationCandidates.isNotEmpty ||
      relationCandidates.isNotEmpty ||
      partOfSpeechCandidates.isNotEmpty ||
      pronunciationCandidates.isNotEmpty ||
      learningTags.isNotEmpty ||
      frequency.isNotEmpty;

  bool get needsEditorialEnrichment => source == openCetDictionarySourceId;
}

class LocalDictionaryService {
  const LocalDictionaryService();

  static const _entries = <String, DictionaryEntry>{
    'apple': DictionaryEntry(
      word: 'apple',
      ipa: '/ˈæpəl/',
      partOfSpeech: 'n. 名词',
      meanings: ['苹果', '苹果公司（Apple）'],
      example: 'An apple a day keeps the doctor away.',
      exampleTranslation: '一天一苹果，医生远离我。',
    ),
    'hello': DictionaryEntry(
      word: 'hello',
      ipa: '/həˈləʊ/',
      partOfSpeech: 'int. 感叹词',
      meanings: ['你好', '喂；您好（用于打招呼）'],
      example: 'Hello, nice to meet you.',
      exampleTranslation: '你好，很高兴认识你。',
    ),
    'teacher': DictionaryEntry(
      word: 'teacher',
      ipa: '/ˈtiːtʃə(r)/',
      partOfSpeech: 'n. 名词',
      meanings: ['教师；老师'],
      example: 'The teacher explained the sentence clearly.',
      exampleTranslation: '老师清楚地讲解了这个句子。',
    ),
    'technology': DictionaryEntry(
      word: 'technology',
      ipa: '/tekˈnɒlədʒi/',
      partOfSpeech: 'n. 名词',
      meanings: ['技术；工艺；科技'],
      example: 'Technology is changing the way we learn.',
      exampleTranslation: '技术正在改变我们的学习方式。',
    ),
    'translate': DictionaryEntry(
      word: 'translate',
      ipa: '/trænzˈleɪt/',
      partOfSpeech: 'v. 动词',
      meanings: ['翻译；转译', '解释；转化'],
      example: 'Please translate this sentence into Chinese.',
      exampleTranslation: '请把这个句子翻译成中文。',
    ),
    'language': DictionaryEntry(
      word: 'language',
      ipa: '/ˈlæŋɡwɪdʒ/',
      partOfSpeech: 'n. 名词',
      meanings: ['语言；语言文字', '表达方式'],
      example: 'Language helps people share ideas.',
      exampleTranslation: '语言帮助人们分享想法。',
    ),
    'learn': DictionaryEntry(
      word: 'learn',
      ipa: '/lɜːn/',
      partOfSpeech: 'v. 动词',
      meanings: ['学习；学会', '得知；获悉'],
      example: 'We learn a little more every day.',
      exampleTranslation: '我们每天都多学一点。',
    ),
    'understand': DictionaryEntry(
      word: 'understand',
      ipa: '/ˌʌndəˈstænd/',
      partOfSpeech: 'v. 动词',
      meanings: ['理解；明白', '了解；领会'],
      example: 'A clear example helps me understand the idea.',
      exampleTranslation: '一个清晰的例子帮助我理解这个想法。',
    ),
    'practice': DictionaryEntry(
      word: 'practice',
      ipa: '/ˈpræktɪs/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['练习；实践', '实行；训练'],
      example: 'Regular practice makes speaking easier.',
      exampleTranslation: '规律练习会让表达更容易。',
    ),
    'read': DictionaryEntry(
      word: 'read',
      ipa: '/riːd/',
      partOfSpeech: 'v. 动词',
      meanings: ['阅读；读懂', '朗读；读出'],
      example: 'I read one short article before breakfast.',
      exampleTranslation: '我在早餐前读一篇短文章。',
    ),
    'write': DictionaryEntry(
      word: 'write',
      ipa: '/raɪt/',
      partOfSpeech: 'v. 动词',
      meanings: ['写；书写', '撰写；记录'],
      example: 'Write the new words in your notebook.',
      exampleTranslation: '把生词写在你的笔记本里。',
    ),
    'speak': DictionaryEntry(
      word: 'speak',
      ipa: '/spiːk/',
      partOfSpeech: 'v. 动词',
      meanings: ['说；讲', '发言；表达'],
      example: 'Please speak slowly and clearly.',
      exampleTranslation: '请说得慢一些、清楚一些。',
    ),
    'listen': DictionaryEntry(
      word: 'listen',
      ipa: '/ˈlɪsən/',
      partOfSpeech: 'v. 动词',
      meanings: ['听；倾听', '听从；留心'],
      example: 'Listen to the sentence twice.',
      exampleTranslation: '把这个句子听两遍。',
    ),
    'study': DictionaryEntry(
      word: 'study',
      ipa: '/ˈstʌdi/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['学习；研究', '书房；研究课题'],
      example: 'A short study session is better than none.',
      exampleTranslation: '短时间学习也比完全不学好。',
    ),
    'sentence': DictionaryEntry(
      word: 'sentence',
      ipa: '/ˈsentəns/',
      partOfSpeech: 'n. 名词',
      meanings: ['句子', '判决；宣判'],
      example: 'Read the whole sentence before translating it.',
      exampleTranslation: '翻译前先读完整个句子。',
    ),
    'example': DictionaryEntry(
      word: 'example',
      ipa: '/ɪɡˈzɑːmpəl/',
      partOfSpeech: 'n. 名词',
      meanings: ['例子；实例', '榜样；范例'],
      example: 'This example shows how the word is used.',
      exampleTranslation: '这个例子展示了这个词的用法。',
    ),
    'meaning': DictionaryEntry(
      word: 'meaning',
      ipa: '/ˈmiːnɪŋ/',
      partOfSpeech: 'n. 名词',
      meanings: ['意思；含义', '意义；重要性'],
      example: 'Context can change the meaning of a word.',
      exampleTranslation: '语境可能改变一个词的含义。',
    ),
    'explain': DictionaryEntry(
      word: 'explain',
      ipa: '/ɪkˈspleɪn/',
      partOfSpeech: 'v. 动词',
      meanings: ['解释；说明', '阐明；说明原因'],
      example: 'Can you explain this phrase in simple English?',
      exampleTranslation: '你能用简单英语解释这个短语吗？',
    ),
    'correct': DictionaryEntry(
      word: 'correct',
      ipa: '/kəˈrekt/',
      partOfSpeech: 'adj./v. 形容词/动词',
      meanings: ['正确的；准确的', '改正；纠正'],
      example: 'The answer is correct, but the sentence needs a small change.',
      exampleTranslation: '答案是正确的，但句子需要稍作修改。',
    ),
    'important': DictionaryEntry(
      word: 'important',
      ipa: '/ɪmˈpɔːtənt/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['重要的；有价值的', '有影响力的'],
      example: 'Understanding the context is important.',
      exampleTranslation: '理解语境很重要。',
    ),
    'future': DictionaryEntry(
      word: 'future',
      ipa: '/ˈfjuːtʃə(r)/',
      partOfSpeech: 'n./adj. 名词/形容词',
      meanings: ['未来；将来', '未来的；将来的'],
      example: 'Small habits shape your future.',
      exampleTranslation: '小习惯塑造你的未来。',
    ),
    'culture': DictionaryEntry(
      word: 'culture',
      ipa: '/ˈkʌltʃə(r)/',
      partOfSpeech: 'n. 名词',
      meanings: ['文化；文明', '风俗；培育'],
      example: 'Reading opens a window into another culture.',
      exampleTranslation: '阅读打开了一扇了解另一种文化的窗。',
    ),
    'idea': DictionaryEntry(
      word: 'idea',
      ipa: '/aɪˈdɪə/',
      partOfSpeech: 'n. 名词',
      meanings: ['想法；主意', '理解；印象'],
      example: 'That is a useful idea for daily practice.',
      exampleTranslation: '那是一个适合日常练习的好主意。',
    ),
    'work': DictionaryEntry(
      word: 'work',
      ipa: '/wɜːk/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['工作；职业', '工作；奏效'],
      example: 'This method works well for short texts.',
      exampleTranslation: '这个方法很适合短文本。',
    ),
    'communicate': DictionaryEntry(
      word: 'communicate',
      ipa: '/kəˈmjuːnɪkeɪt/',
      partOfSpeech: 'v. 动词',
      meanings: ['交流；沟通', '传达；传递'],
      example: 'Words help us communicate across distance.',
      exampleTranslation: '文字帮助我们跨越距离交流。',
    ),
    'improve': DictionaryEntry(
      word: 'improve',
      ipa: '/ɪmˈpruːv/',
      partOfSpeech: 'v. 动词',
      meanings: ['改善；改进', '提高；变得更好'],
      example: 'Review the mistakes to improve your writing.',
      exampleTranslation: '复习错误来提高你的写作。',
    ),
    'remember': DictionaryEntry(
      word: 'remember',
      ipa: '/rɪˈmembə(r)/',
      partOfSpeech: 'v. 动词',
      meanings: ['记得；记住', '回想起；记起'],
      example: 'Use a sentence to remember a new word.',
      exampleTranslation: '用一个句子来记住一个新词。',
    ),
    'review': DictionaryEntry(
      word: 'review',
      ipa: '/rɪˈvjuː/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['复习；回顾', '评论；审查'],
      example: 'Review yesterday’s words before learning new ones.',
      exampleTranslation: '学习新词前先复习昨天的单词。',
    ),
    'progress': DictionaryEntry(
      word: 'progress',
      ipa: '/ˈprəʊɡres/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['进步；进展', '进步；推进'],
      example: 'Your progress is easier to see when you keep a record.',
      exampleTranslation: '坚持记录会让你的进步更容易被看见。',
    ),
    'goal': DictionaryEntry(
      word: 'goal',
      ipa: '/ɡəʊl/',
      partOfSpeech: 'n. 名词',
      meanings: ['目标；目的', '进球；得分'],
      example: 'Set one clear goal for today.',
      exampleTranslation: '为今天设定一个清晰的目标。',
    ),
    'ability': DictionaryEntry(
      word: 'ability',
      ipa: '/əˈbɪləti/',
      partOfSpeech: 'n. 名词',
      meanings: ['能力；本领', '才能；资质'],
      example: 'Practice can improve your ability to communicate.',
      exampleTranslation: '练习可以提高你的沟通能力。',
    ),
    'achieve': DictionaryEntry(
      word: 'achieve',
      ipa: '/əˈtʃiːv/',
      partOfSpeech: 'v. 动词',
      meanings: ['实现；达到', '取得（成绩）'],
      example: 'Small steps help us achieve a larger goal.',
      exampleTranslation: '小步前进能帮助我们实现更大的目标。',
    ),
    'advice': DictionaryEntry(
      word: 'advice',
      ipa: '/ədˈvaɪs/',
      partOfSpeech: 'n. 名词',
      meanings: ['建议；忠告', '意见；指导'],
      example: 'Her advice helped me choose a better method.',
      exampleTranslation: '她的建议帮助我选择了更好的方法。',
    ),
    'affect': DictionaryEntry(
      word: 'affect',
      ipa: '/əˈfekt/',
      partOfSpeech: 'v. 动词',
      meanings: ['影响；使发生变化', '感染（疾病）'],
      example: 'A lack of sleep can affect your attention.',
      exampleTranslation: '睡眠不足会影响你的注意力。',
    ),
    'approach': DictionaryEntry(
      word: 'approach',
      ipa: '/əˈprəʊtʃ/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['方法；途径', '接近；着手处理'],
      example: 'This approach makes difficult ideas easier to understand.',
      exampleTranslation: '这种方法让难懂的想法更容易理解。',
    ),
    'avoid': DictionaryEntry(
      word: 'avoid',
      ipa: '/əˈvɔɪd/',
      partOfSpeech: 'v. 动词',
      meanings: ['避免；防止', '避开；回避'],
      example: 'Check the context to avoid a wrong translation.',
      exampleTranslation: '检查语境可以避免错误翻译。',
    ),
    'available': DictionaryEntry(
      word: 'available',
      ipa: '/əˈveɪləbəl/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['可获得的；可用的', '有空的；可联系的'],
      example: 'The reference materials are available offline.',
      exampleTranslation: '参考资料可以离线使用。',
    ),
    'benefit': DictionaryEntry(
      word: 'benefit',
      ipa: '/ˈbenɪfɪt/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['益处；好处', '受益；使受益'],
      example: 'Reading every day has a long-term benefit.',
      exampleTranslation: '每天阅读会带来长期的好处。',
    ),
    'challenge': DictionaryEntry(
      word: 'challenge',
      ipa: '/ˈtʃælɪndʒ/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['挑战；难题', '向……提出挑战'],
      example: 'Understanding a new accent can be a challenge.',
      exampleTranslation: '听懂一种新的口音可能是一项挑战。',
    ),
    'compare': DictionaryEntry(
      word: 'compare',
      ipa: '/kəmˈpeə(r)/',
      partOfSpeech: 'v. 动词',
      meanings: ['比较；对照', '把……比作'],
      example: 'Compare the original sentence with the translation.',
      exampleTranslation: '把原句和译文进行对照。',
    ),
    'consider': DictionaryEntry(
      word: 'consider',
      ipa: '/kənˈsɪdə(r)/',
      partOfSpeech: 'v. 动词',
      meanings: ['考虑；斟酌', '认为；把……看作'],
      example: 'Consider the audience before choosing your tone.',
      exampleTranslation: '选择语气前要考虑读者。',
    ),
    'context': DictionaryEntry(
      word: 'context',
      ipa: '/ˈkɒntekst/',
      partOfSpeech: 'n. 名词',
      meanings: ['语境；上下文', '背景；环境'],
      example: 'The same word may have a different meaning in context.',
      exampleTranslation: '同一个词在不同语境中可能有不同的含义。',
    ),
    'decide': DictionaryEntry(
      word: 'decide',
      ipa: '/dɪˈsaɪd/',
      partOfSpeech: 'v. 动词',
      meanings: ['决定；作出决定', '裁决；判定'],
      example: 'Decide which words you want to review tonight.',
      exampleTranslation: '决定今晚要复习哪些单词。',
    ),
    'describe': DictionaryEntry(
      word: 'describe',
      ipa: '/dɪˈskraɪb/',
      partOfSpeech: 'v. 动词',
      meanings: ['描述；形容', '描写；叙述'],
      example: 'Use simple words to describe the main idea.',
      exampleTranslation: '用简单的词描述主要观点。',
    ),
    'develop': DictionaryEntry(
      word: 'develop',
      ipa: '/dɪˈveləp/',
      partOfSpeech: 'v. 动词',
      meanings: ['发展；开发', '养成；形成'],
      example: 'Daily reading helps develop a sense of language.',
      exampleTranslation: '每天阅读有助于培养语感。',
    ),
    'effort': DictionaryEntry(
      word: 'effort',
      ipa: '/ˈefət/',
      partOfSpeech: 'n. 名词',
      meanings: ['努力；尝试', '努力的成果'],
      example: 'Your effort matters even when progress is slow.',
      exampleTranslation: '即使进步缓慢，你的努力也很重要。',
    ),
    'environment': DictionaryEntry(
      word: 'environment',
      ipa: '/ɪnˈvaɪərənmənt/',
      partOfSpeech: 'n. 名词',
      meanings: ['环境；周围状况', '自然环境'],
      example: 'A quiet environment helps me focus on reading.',
      exampleTranslation: '安静的环境有助于我专心阅读。',
    ),
    'evidence': DictionaryEntry(
      word: 'evidence',
      ipa: '/ˈevɪdəns/',
      partOfSpeech: 'n. 名词',
      meanings: ['证据；证明', '迹象；证据材料'],
      example: 'The conclusion is supported by the evidence.',
      exampleTranslation: '这个结论有证据支持。',
    ),
    'experience': DictionaryEntry(
      word: 'experience',
      ipa: '/ɪkˈspɪəriəns/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['经历；经验', '体验；遭遇'],
      example: 'Every conversation is a chance to gain experience.',
      exampleTranslation: '每次交流都是积累经验的机会。',
    ),
    'focus': DictionaryEntry(
      word: 'focus',
      ipa: '/ˈfəʊkəs/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['重点；焦点', '集中注意力；聚焦'],
      example: 'Focus on one pronunciation problem at a time.',
      exampleTranslation: '一次专注解决一个发音问题。',
    ),
    'habit': DictionaryEntry(
      word: 'habit',
      ipa: '/ˈhæbɪt/',
      partOfSpeech: 'n. 名词',
      meanings: ['习惯；习性', '习惯性的做法'],
      example: 'A small daily habit can lead to lasting progress.',
      exampleTranslation: '每天一个小习惯可以带来持久的进步。',
    ),
    'issue': DictionaryEntry(
      word: 'issue',
      ipa: '/ˈɪʃuː/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['问题；议题', '发布；发出'],
      example: 'The main issue is the unclear sentence structure.',
      exampleTranslation: '主要问题是句子结构不清晰。',
    ),
    'method': DictionaryEntry(
      word: 'method',
      ipa: '/ˈmeθəd/',
      partOfSpeech: 'n. 名词',
      meanings: ['方法；办法', '条理；秩序'],
      example: 'Choose a study method that fits your schedule.',
      exampleTranslation: '选择适合你时间安排的学习方法。',
    ),
    'opportunity': DictionaryEntry(
      word: 'opportunity',
      ipa: '/ˌɒpəˈtjuːnəti/',
      partOfSpeech: 'n. 名词',
      meanings: ['机会；时机', '机遇；发展机会'],
      example:
          'This course gives learners an opportunity to practise speaking.',
      exampleTranslation: '这门课程给学习者提供了练习口语的机会。',
    ),
    'possible': DictionaryEntry(
      word: 'possible',
      ipa: '/ˈpɒsəbəl/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['可能的', '可接受的；合理的'],
      example: 'Keep the translation as clear and natural as possible.',
      exampleTranslation: '让译文尽可能清晰自然。',
    ),
    'require': DictionaryEntry(
      word: 'require',
      ipa: '/rɪˈkwaɪə(r)/',
      partOfSpeech: 'v. 动词',
      meanings: ['需要；要求', '规定；命令'],
      example: 'Good writing requires clear thinking.',
      exampleTranslation: '好的写作需要清晰的思考。',
    ),
    'response': DictionaryEntry(
      word: 'response',
      ipa: '/rɪˈspɒns/',
      partOfSpeech: 'n. 名词',
      meanings: ['回答；回应', '反应；响应'],
      example: 'The response should address the question directly.',
      exampleTranslation: '回答应该直接回应这个问题。',
    ),
    'result': DictionaryEntry(
      word: 'result',
      ipa: '/rɪˈzʌlt/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['结果；成果', '导致；产生'],
      example: 'Regular review usually leads to better results.',
      exampleTranslation: '规律复习通常会带来更好的结果。',
    ),
    'solution': DictionaryEntry(
      word: 'solution',
      ipa: '/səˈluːʃn/',
      partOfSpeech: 'n. 名词',
      meanings: ['解决办法；方案', '解答；答案'],
      example: 'A dictionary is one useful solution for learning new words.',
      exampleTranslation: '词典是学习新单词的一种有用办法。',
    ),
    'value': DictionaryEntry(
      word: 'value',
      ipa: '/ˈvæljuː/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['价值；重要性', '重视；珍视'],
      example: 'We value accuracy as well as natural language.',
      exampleTranslation: '我们既重视准确性，也重视自然的语言表达。',
    ),
    'accept': DictionaryEntry(
      word: 'accept',
      ipa: '/əkˈsept/',
      partOfSpeech: 'v. 动词',
      meanings: ['接受；同意', '承认；认可'],
      example: 'Accept corrections as part of the learning process.',
      exampleTranslation: '把改正错误看作学习过程的一部分。',
    ),
    'access': DictionaryEntry(
      word: 'access',
      ipa: '/ˈækses/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['机会；使用权', '访问；获取'],
      example: 'Students can access the dictionary offline.',
      exampleTranslation: '学生可以离线使用这本词典。',
    ),
    'account': DictionaryEntry(
      word: 'account',
      ipa: '/əˈkaʊnt/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['账户；账号', '说明；解释'],
      example: 'The report gives a clear account of the experiment.',
      exampleTranslation: '这份报告清楚地说明了实验情况。',
    ),
    'accurate': DictionaryEntry(
      word: 'accurate',
      ipa: '/ˈækjərət/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['准确的；精确的', '正确无误的'],
      example: 'An accurate translation preserves the intended meaning.',
      exampleTranslation: '准确的翻译会保留原本想表达的意思。',
    ),
    'adapt': DictionaryEntry(
      word: 'adapt',
      ipa: '/əˈdæpt/',
      partOfSpeech: 'v. 动词',
      meanings: ['适应；适合', '改编；改写'],
      example: 'Adapt your study plan when your schedule changes.',
      exampleTranslation: '日程改变时要调整学习计划。',
    ),
    'additional': DictionaryEntry(
      word: 'additional',
      ipa: '/əˈdɪʃənəl/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['额外的；附加的', '另外的；补充的'],
      example: 'The notes contain additional examples for review.',
      exampleTranslation: '这些笔记包含供复习的额外例句。',
    ),
    'advantage': DictionaryEntry(
      word: 'advantage',
      ipa: '/ədˈvɑːntɪdʒ/',
      partOfSpeech: 'n. 名词',
      meanings: ['优势；有利条件', '好处；益处'],
      example: 'Reading aloud gives learners an advantage in pronunciation.',
      exampleTranslation: '朗读能让学习者在发音方面占据优势。',
    ),
    'analysis': DictionaryEntry(
      word: 'analysis',
      ipa: '/əˈnæləsɪs/',
      partOfSpeech: 'n. 名词',
      meanings: ['分析；解析', '分析结果；分析报告'],
      example: 'The analysis focuses on how the phrase is used.',
      exampleTranslation: '分析重点讨论这个短语的用法。',
    ),
    'apply': DictionaryEntry(
      word: 'apply',
      ipa: '/əˈplaɪ/',
      partOfSpeech: 'v. 动词',
      meanings: ['应用；运用', '申请；请求'],
      example: 'Apply the new word in a sentence of your own.',
      exampleTranslation: '把这个新词用在你自己写的句子里。',
    ),
    'argue': DictionaryEntry(
      word: 'argue',
      ipa: '/ˈɑːɡjuː/',
      partOfSpeech: 'v. 动词',
      meanings: ['争论；争辩', '论证；主张'],
      example: 'The author argues that practice matters more than speed.',
      exampleTranslation: '作者论证说，练习比速度更重要。',
    ),
    'attention': DictionaryEntry(
      word: 'attention',
      ipa: '/əˈtenʃən/',
      partOfSpeech: 'n. 名词',
      meanings: ['注意；关注', '立正；特别照顾'],
      example: 'Pay attention to the word’s ending when you listen.',
      exampleTranslation: '听的时候要注意这个词的词尾。',
    ),
    'cause': DictionaryEntry(
      word: 'cause',
      ipa: '/kɔːz/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['原因；起因', '导致；引起'],
      example: 'The context can explain the cause of the confusion.',
      exampleTranslation: '语境可以解释产生困惑的原因。',
    ),
    'certain': DictionaryEntry(
      word: 'certain',
      ipa: '/ˈsɜːtn/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['确定的；确信的', '某个；某些'],
      example: 'In certain contexts, the same word changes its tone.',
      exampleTranslation: '在某些语境中，同一个词的语气会发生变化。',
    ),
    'common': DictionaryEntry(
      word: 'common',
      ipa: '/ˈkɒmən/',
      partOfSpeech: 'adj./n. 形容词/名词',
      meanings: ['常见的；普遍的', '共同的；共有的'],
      example: 'This is a common expression in everyday conversation.',
      exampleTranslation: '这是日常对话中常见的表达。',
    ),
    'complete': DictionaryEntry(
      word: 'complete',
      ipa: '/kəmˈpliːt/',
      partOfSpeech: 'adj./v. 形容词/动词',
      meanings: ['完整的；全部的', '完成；结束'],
      example: 'Read the complete paragraph before choosing a meaning.',
      exampleTranslation: '选择词义前先读完整的一段。',
    ),
    'create': DictionaryEntry(
      word: 'create',
      ipa: '/kriˈeɪt/',
      partOfSpeech: 'v. 动词',
      meanings: ['创造；创作', '创建；引起'],
      example: 'Create a short example to make the word memorable.',
      exampleTranslation: '写一个简短的例子，让这个词更容易记住。',
    ),
    'decision': DictionaryEntry(
      word: 'decision',
      ipa: '/dɪˈsɪʒən/',
      partOfSpeech: 'n. 名词',
      meanings: ['决定；决心', '裁决；判断'],
      example: 'The final decision should consider the whole sentence.',
      exampleTranslation: '最终决定应该考虑整个句子。',
    ),
    'detail': DictionaryEntry(
      word: 'detail',
      ipa: '/ˈdiːteɪl/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['细节；详情', '详述；详细说明'],
      example: 'The translation keeps the important technical details.',
      exampleTranslation: '译文保留了重要的技术细节。',
    ),
    'difference': DictionaryEntry(
      word: 'difference',
      ipa: '/ˈdɪfrəns/',
      partOfSpeech: 'n. 名词',
      meanings: ['差异；不同', '影响；区别'],
      example: 'Context makes a difference to the meaning of a phrase.',
      exampleTranslation: '语境会影响一个短语的含义。',
    ),
    'difficult': DictionaryEntry(
      word: 'difficult',
      ipa: '/ˈdɪfɪkəlt/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['困难的；费力的', '难以理解的；难以相处的'],
      example:
          'A difficult sentence becomes clearer when it is divided into parts.',
      exampleTranslation: '把难句分成几部分后，它会更清楚。',
    ),
    'discuss': DictionaryEntry(
      word: 'discuss',
      ipa: '/dɪˈskʌs/',
      partOfSpeech: 'v. 动词',
      meanings: ['讨论；商讨', '论述；谈论'],
      example: 'The lesson discusses several ways to remember vocabulary.',
      exampleTranslation: '这节课讨论了几种记忆词汇的方法。',
    ),
    'effect': DictionaryEntry(
      word: 'effect',
      ipa: '/ɪˈfekt/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['影响；效果', '实现；使发生'],
      example: 'Regular review has a positive effect on memory.',
      exampleTranslation: '规律复习对记忆有积极影响。',
    ),
    'effective': DictionaryEntry(
      word: 'effective',
      ipa: '/ɪˈfektɪv/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['有效的；起作用的', '生效的；实际的'],
      example: 'Short, focused sessions can be an effective study method.',
      exampleTranslation: '短而专注的学习时段可以是一种有效的学习方法。',
    ),
    'general': DictionaryEntry(
      word: 'general',
      ipa: '/ˈdʒenərəl/',
      partOfSpeech: 'adj./n. 形容词/名词',
      meanings: ['一般的；普遍的', '总体的；大致的'],
      example: 'The introduction gives a general idea of the article.',
      exampleTranslation: '引言概括了文章的大意。',
    ),
    'include': DictionaryEntry(
      word: 'include',
      ipa: '/ɪnˈkluːd/',
      partOfSpeech: 'v. 动词',
      meanings: ['包括；包含', '把……列为一部分'],
      example: 'The note should include the meaning and one example.',
      exampleTranslation: '笔记应该包括词义和一个例子。',
    ),
    'increase': DictionaryEntry(
      word: 'increase',
      ipa: '/ɪnˈkriːs/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['增加；增长', '提高；增强'],
      example: 'Daily reading can increase your vocabulary over time.',
      exampleTranslation: '每天阅读会逐渐扩大你的词汇量。',
    ),
    'individual': DictionaryEntry(
      word: 'individual',
      ipa: '/ˌɪndɪˈvɪdʒuəl/',
      partOfSpeech: 'adj./n. 形容词/名词',
      meanings: ['个人的；个别的', '个人；个体'],
      example: 'Each learner needs an individual review plan.',
      exampleTranslation: '每位学习者都需要个人化的复习计划。',
    ),
    'influence': DictionaryEntry(
      word: 'influence',
      ipa: '/ˈɪnfluəns/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['影响；作用', '影响；左右'],
      example: 'The speaker’s accent can influence how a sentence sounds.',
      exampleTranslation: '说话者的口音会影响句子的听感。',
    ),
    'knowledge': DictionaryEntry(
      word: 'knowledge',
      ipa: '/ˈnɒlɪdʒ/',
      partOfSpeech: 'n. 名词',
      meanings: ['知识；学问', '了解；知晓'],
      example: 'Practice turns vocabulary knowledge into usable language.',
      exampleTranslation: '练习能把词汇知识转化为可使用的语言。',
    ),
    'material': DictionaryEntry(
      word: 'material',
      ipa: '/məˈtɪəriəl/',
      partOfSpeech: 'n./adj. 名词/形容词',
      meanings: ['材料；资料', '物质的；重要的'],
      example: 'Choose reading material that matches your current level.',
      exampleTranslation: '选择符合当前水平的阅读材料。',
    ),
    'natural': DictionaryEntry(
      word: 'natural',
      ipa: '/ˈnætʃərəl/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['自然的；天然的', '自然的；不做作的'],
      example: 'The best translation sounds natural in the target language.',
      exampleTranslation: '好的译文在目标语言中读起来很自然。',
    ),
    'notice': DictionaryEntry(
      word: 'notice',
      ipa: '/ˈnəʊtɪs/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['注意；察觉', '通知；告示'],
      example: 'Notice how the verb changes after this subject.',
      exampleTranslation: '注意这个主语之后动词是怎样变化的。',
    ),
    'offer': DictionaryEntry(
      word: 'offer',
      ipa: '/ˈɒfə(r)/',
      partOfSpeech: 'v./n. 动词/名词',
      meanings: ['提供；主动提出', '提议；报价'],
      example: 'The dictionary offers several meanings for the word.',
      exampleTranslation: '这本词典为这个词提供了几种含义。',
    ),
    'opinion': DictionaryEntry(
      word: 'opinion',
      ipa: '/əˈpɪnjən/',
      partOfSpeech: 'n. 名词',
      meanings: ['看法；意见', '评价；鉴定'],
      example: 'Explain the evidence before giving your opinion.',
      exampleTranslation: '发表看法前先解释证据。',
    ),
    'organize': DictionaryEntry(
      word: 'organize',
      ipa: '/ˈɔːɡənaɪz/',
      partOfSpeech: 'v. 动词',
      meanings: ['组织；安排', '整理；规划'],
      example: 'Organize new words by topic to review them efficiently.',
      exampleTranslation: '按主题整理生词，以便高效复习。',
    ),
    'patient': DictionaryEntry(
      word: 'patient',
      ipa: '/ˈpeɪʃnt/',
      partOfSpeech: 'adj./n. 形容词/名词',
      meanings: ['耐心的；能忍耐的', '病人；患者'],
      example: 'Be patient with yourself when a new structure feels difficult.',
      exampleTranslation: '遇到难的新结构时，要对自己耐心一些。',
    ),
    'perform': DictionaryEntry(
      word: 'perform',
      ipa: '/pəˈfɔːm/',
      partOfSpeech: 'v. 动词',
      meanings: ['执行；履行', '表演；演出'],
      example: 'The program can perform a word-level lookup instantly.',
      exampleTranslation: '这个程序可以立即执行单词级查询。',
    ),
    'prepare': DictionaryEntry(
      word: 'prepare',
      ipa: '/prɪˈpeə(r)/',
      partOfSpeech: 'v. 动词',
      meanings: ['准备；预备', '使适合；为……作准备'],
      example: 'Prepare a few sentences before the speaking practice.',
      exampleTranslation: '口语练习前准备几个句子。',
    ),
    'pressure': DictionaryEntry(
      word: 'pressure',
      ipa: '/ˈpreʃə(r)/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['压力；压迫', '对……施加压力'],
      example: 'Too much pressure can make it harder to remember words.',
      exampleTranslation: '压力过大会让记单词变得更困难。',
    ),
    'prevent': DictionaryEntry(
      word: 'prevent',
      ipa: '/prɪˈvent/',
      partOfSpeech: 'v. 动词',
      meanings: ['防止；预防', '阻止；妨碍'],
      example: 'A clear source record helps prevent accidental misuse.',
      exampleTranslation: '清晰的来源记录有助于防止意外误用。',
    ),
    'process': DictionaryEntry(
      word: 'process',
      ipa: '/ˈprəʊses/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['过程；进程', '处理；加工'],
      example: 'Learning is a process that improves through regular review.',
      exampleTranslation: '学习是一个通过规律复习不断改善的过程。',
    ),
    'purpose': DictionaryEntry(
      word: 'purpose',
      ipa: '/ˈpɜːpəs/',
      partOfSpeech: 'n. 名词',
      meanings: ['目的；意图', '用途；作用'],
      example: 'The purpose of this example is to show the usual pattern.',
      exampleTranslation: '这个例子的目的是展示常见句型。',
    ),
    'quality': DictionaryEntry(
      word: 'quality',
      ipa: '/ˈkwɒləti/',
      partOfSpeech: 'n./adj. 名词/形容词',
      meanings: ['质量；品质', '优质的；高质量的'],
      example: 'Quality examples are more useful than a long word list.',
      exampleTranslation: '高质量的例句比很长的单词表更有用。',
    ),
    'realize': DictionaryEntry(
      word: 'realize',
      ipa: '/ˈriːəlaɪz/',
      partOfSpeech: 'v. 动词',
      meanings: ['意识到；认识到', '实现；使成为现实'],
      example: 'You may realize the difference after reading both versions.',
      exampleTranslation: '读完两个版本后，你可能会意识到其中的差异。',
    ),
    'reduce': DictionaryEntry(
      word: 'reduce',
      ipa: '/rɪˈdjuːs/',
      partOfSpeech: 'v. 动词',
      meanings: ['减少；降低', '简化；使变成'],
      example: 'Short notes reduce the time needed for later review.',
      exampleTranslation: '简短的笔记能减少以后复习所需的时间。',
    ),
    'relate': DictionaryEntry(
      word: 'relate',
      ipa: '/rɪˈleɪt/',
      partOfSpeech: 'v. 动词',
      meanings: ['联系；关联', '讲述；叙述'],
      example: 'Relate a new word to a familiar situation.',
      exampleTranslation: '把一个新词和熟悉的情境联系起来。',
    ),
    'remain': DictionaryEntry(
      word: 'remain',
      ipa: '/rɪˈmeɪn/',
      partOfSpeech: 'v./n. 动词/名词',
      meanings: ['仍然是；保持', '剩余部分；遗迹'],
      example:
          'Remain focused on the meaning rather than translating every word.',
      exampleTranslation: '要专注于整体含义，而不是逐词翻译。',
    ),
    'research': DictionaryEntry(
      word: 'research',
      ipa: '/rɪˈsɜːtʃ/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['研究；调查', '研究；探究'],
      example: 'The students research the topic before writing a report.',
      exampleTranslation: '学生在写报告前研究这个主题。',
    ),
    'resource': DictionaryEntry(
      word: 'resource',
      ipa: '/rɪˈzɔːs/',
      partOfSpeech: 'n. 名词',
      meanings: ['资源；资料', '办法；应变能力'],
      example: 'A good dictionary is a valuable resource for learners.',
      exampleTranslation: '一本好的词典是学习者宝贵的资源。',
    ),
    'specific': DictionaryEntry(
      word: 'specific',
      ipa: '/spəˈsɪfɪk/',
      partOfSpeech: 'adj./n. 形容词/名词',
      meanings: ['具体的；明确的', '特定的；特殊的'],
      example: 'Give a specific example instead of a general statement.',
      exampleTranslation: '给出具体例子，而不是笼统的陈述。',
    ),
    'support': DictionaryEntry(
      word: 'support',
      ipa: '/səˈpɔːt/',
      partOfSpeech: 'v./n. 动词/名词',
      meanings: ['支持；支撑', '支持；帮助'],
      example: 'The example supports the meaning shown above.',
      exampleTranslation: '这个例子支持上面列出的词义。',
    ),
    'society': DictionaryEntry(
      word: 'society',
      ipa: '/səˈsaɪəti/',
      partOfSpeech: 'n. 名词',
      meanings: ['社会；社会群体', '社团；协会'],
      example: 'Language changes as society changes.',
      exampleTranslation: '语言会随着社会变化而变化。',
    ),
    'suggest': DictionaryEntry(
      word: 'suggest',
      ipa: '/səˈdʒest/',
      partOfSpeech: 'v. 动词',
      meanings: ['建议；提议', '暗示；表明'],
      example: 'The evidence suggests that the phrase is informal.',
      exampleTranslation: '证据表明这个短语比较口语化。',
    ),
    'term': DictionaryEntry(
      word: 'term',
      ipa: '/tɜːm/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['术语；词语', '学期；期限'],
      example: 'The article introduces the term in its first paragraph.',
      exampleTranslation: '文章在第一段介绍了这个术语。',
    ),
    'theory': DictionaryEntry(
      word: 'theory',
      ipa: '/ˈθɪəri/',
      partOfSpeech: 'n. 名词',
      meanings: ['理论；学说', '看法；推测'],
      example: 'The theory is easier to understand with a simple example.',
      exampleTranslation: '有一个简单的例子，理论会更容易理解。',
    ),
    'topic': DictionaryEntry(
      word: 'topic',
      ipa: '/ˈtɒpɪk/',
      partOfSpeech: 'n. 名词',
      meanings: ['话题；主题', '题目；论题'],
      example: 'Choose a familiar topic for your first speaking task.',
      exampleTranslation: '第一次口语任务选择一个熟悉的话题。',
    ),
    'traditional': DictionaryEntry(
      word: 'traditional',
      ipa: '/trəˈdɪʃənəl/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['传统的；惯例的', '守旧的；依照传统的'],
      example: 'The article compares traditional learning with digital tools.',
      exampleTranslation: '文章比较了传统学习和数字工具。',
    ),
    'various': DictionaryEntry(
      word: 'various',
      ipa: '/ˈveəriəs/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['各种各样的；不同的', '许多的；多个的'],
      example: 'The dictionary gives various examples for common meanings.',
      exampleTranslation: '这本词典为常见词义提供了各种例子。',
    ),
    'whether': DictionaryEntry(
      word: 'whether',
      ipa: '/ˈweðə(r)/',
      partOfSpeech: 'conj. 连词',
      meanings: ['是否；是不是', '不论；无论'],
      example: 'Decide whether the sentence needs a formal tone.',
      exampleTranslation: '判断这个句子是否需要正式语气。',
    ),
    'significant': DictionaryEntry(
      word: 'significant',
      ipa: '/sɪɡˈnɪfɪkənt/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['重要的；有意义的', '显著的；明显的'],
      example: 'A significant improvement often comes from small daily habits.',
      exampleTranslation: '显著的进步往往来自每天的小习惯。',
    ),
    'acknowledge': DictionaryEntry(
      word: 'acknowledge',
      ipa: '/əkˈnɒlɪdʒ/',
      partOfSpeech: 'v. 动词',
      meanings: ['承认；认可', '告知收到；感谢'],
      example:
          'A good explanation acknowledges more than one possible meaning.',
      exampleTranslation: '好的解释会承认不止一种可能的含义。',
    ),
    'acquire': DictionaryEntry(
      word: 'acquire',
      ipa: '/əˈkwaɪə(r)/',
      partOfSpeech: 'v. 动词',
      meanings: ['获得；取得', '学到；养成'],
      example: 'Readers acquire new vocabulary through repeated exposure.',
      exampleTranslation: '读者通过反复接触来获得新的词汇。',
    ),
    'alternative': DictionaryEntry(
      word: 'alternative',
      ipa: '/ɔːlˈtɜːnətɪv/',
      partOfSpeech: 'n./adj. 名词/形容词',
      meanings: ['替代方案；选择', '可替代的；非传统的'],
      example: 'The note offers an alternative way to remember the phrase.',
      exampleTranslation: '这份笔记提供了另一种记忆这个短语的方法。',
    ),
    'appropriate': DictionaryEntry(
      word: 'appropriate',
      ipa: '/əˈprəʊpriət/',
      partOfSpeech: 'adj./v. 形容词/动词',
      meanings: ['合适的；恰当的', '拨出；挪用'],
      example: 'Choose an appropriate tone for the intended reader.',
      exampleTranslation: '为目标读者选择恰当的语气。',
    ),
    'aspect': DictionaryEntry(
      word: 'aspect',
      ipa: '/ˈæspekt/',
      partOfSpeech: 'n. 名词',
      meanings: ['方面；层面', '外观；样子'],
      example: 'Pronunciation is one important aspect of speaking practice.',
      exampleTranslation: '发音是口语练习的一个重要方面。',
    ),
    'assume': DictionaryEntry(
      word: 'assume',
      ipa: '/əˈsjuːm/',
      partOfSpeech: 'v. 动词',
      meanings: ['假定；假设', '认为；承担'],
      example: 'Do not assume that a familiar word has only one meaning.',
      exampleTranslation: '不要以为熟悉的词只有一个含义。',
    ),
    'assess': DictionaryEntry(
      word: 'assess',
      ipa: '/əˈses/',
      partOfSpeech: 'v. 动词',
      meanings: ['评估；评价', '估算；核定'],
      example: 'Use a short quiz to assess your understanding of the text.',
      exampleTranslation: '用一个小测验评估你对文章的理解。',
    ),
    'aware': DictionaryEntry(
      word: 'aware',
      ipa: '/əˈweə(r)/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['意识到的；知道的', '察觉的；有……意识的'],
      example: 'Be aware that the same phrase may sound formal in one context.',
      exampleTranslation: '要意识到同一个短语在某种语境中可能听起来很正式。',
    ),
    'complex': DictionaryEntry(
      word: 'complex',
      ipa: '/ˈkɒmpleks/',
      partOfSpeech: 'adj./n. 形容词/名词',
      meanings: ['复杂的；难懂的', '综合体；情结'],
      example: 'Break a complex sentence into smaller units.',
      exampleTranslation: '把复杂的句子拆成更小的单元。',
    ),
    'concept': DictionaryEntry(
      word: 'concept',
      ipa: '/ˈkɒnsept/',
      partOfSpeech: 'n. 名词',
      meanings: ['概念；观念', '想法；计划'],
      example: 'The example makes the abstract concept easier to understand.',
      exampleTranslation: '这个例子让抽象概念更容易理解。',
    ),
    'conduct': DictionaryEntry(
      word: 'conduct',
      ipa: '/kənˈdʌkt/',
      partOfSpeech: 'v./n. 动词/名词',
      meanings: ['进行；实施', '行为；举止'],
      example: 'The team conducts a careful review of every new entry.',
      exampleTranslation: '团队会仔细审核每一条新词条。',
    ),
    'conflict': DictionaryEntry(
      word: 'conflict',
      ipa: '/ˈkɒnflɪkt/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['冲突；矛盾', '冲突；抵触'],
      example: 'Two meanings may conflict unless the context is clear.',
      exampleTranslation: '如果语境不清晰，两种含义可能会互相冲突。',
    ),
    'contribute': DictionaryEntry(
      word: 'contribute',
      ipa: '/kənˈtrɪbjuːt/',
      partOfSpeech: 'v. 动词',
      meanings: ['贡献；捐献', '促成；投稿'],
      example:
          'Each example contributes to a clearer understanding of the word.',
      exampleTranslation: '每个例子都有助于更清楚地理解这个词。',
    ),
    'data': DictionaryEntry(
      word: 'data',
      ipa: '/ˈdeɪtə/',
      partOfSpeech: 'n. 名词',
      meanings: ['数据；资料', '信息；资料集'],
      example: 'The learning record stores data locally for later review.',
      exampleTranslation: '学习记录会把数据保存在本地，方便以后复习。',
    ),
    'define': DictionaryEntry(
      word: 'define',
      ipa: '/dɪˈfaɪn/',
      partOfSpeech: 'v. 动词',
      meanings: ['给……下定义；解释', '界定；确定'],
      example: 'The first paragraph defines the key term.',
      exampleTranslation: '第一段解释了这个关键术语。',
    ),
    'demonstrate': DictionaryEntry(
      word: 'demonstrate',
      ipa: '/ˈdemənstreɪt/',
      partOfSpeech: 'v. 动词',
      meanings: ['证明；论证', '演示；展示'],
      example: 'The example demonstrates how the grammar works.',
      exampleTranslation: '这个例子展示了语法是如何运作的。',
    ),
    'determine': DictionaryEntry(
      word: 'determine',
      ipa: '/dɪˈtɜːmɪn/',
      partOfSpeech: 'v. 动词',
      meanings: ['决定；确定', '查明；测定'],
      example: 'Context helps determine which meaning is intended.',
      exampleTranslation: '语境有助于确定原本想表达哪一种含义。',
    ),
    'distribute': DictionaryEntry(
      word: 'distribute',
      ipa: '/dɪˈstrɪbjuːt/',
      partOfSpeech: 'v. 动词',
      meanings: ['分发；分配', '分布；散布'],
      example: 'Distribute the new words across several short study sessions.',
      exampleTranslation: '把生词分配到几次短学习中。',
    ),
    'economy': DictionaryEntry(
      word: 'economy',
      ipa: '/ɪˈkɒnəmi/',
      partOfSpeech: 'n. 名词',
      meanings: ['经济；经济体', '节约；经济性'],
      example: 'The article explains how changes affect the local economy.',
      exampleTranslation: '这篇文章解释了变化如何影响当地经济。',
    ),
    'establish': DictionaryEntry(
      word: 'establish',
      ipa: '/ɪˈstæblɪʃ/',
      partOfSpeech: 'v. 动词',
      meanings: ['建立；创立', '确定；证实'],
      example: 'Establish a regular review time that you can keep.',
      exampleTranslation: '建立一个你能坚持的固定复习时间。',
    ),
    'estimate': DictionaryEntry(
      word: 'estimate',
      ipa: '/ˈestɪmət/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['估计；估算', '估价；评价'],
      example: 'The app estimates the time needed for today’s review.',
      exampleTranslation: '应用会估算今天复习所需的时间。',
    ),
    'factor': DictionaryEntry(
      word: 'factor',
      ipa: '/ˈfæktə(r)/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['因素；要素', '把……因素包括在内'],
      example: 'Motivation is an important factor in long-term learning.',
      exampleTranslation: '动力是长期学习中的一个重要因素。',
    ),
    'feature': DictionaryEntry(
      word: 'feature',
      ipa: '/ˈfiːtʃə(r)/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['特征；特点', '以……为特色；起重要作用'],
      example:
          'The learning card features pronunciation and example sentences.',
      exampleTranslation: '学习卡包含发音和例句功能。',
    ),
    'function': DictionaryEntry(
      word: 'function',
      ipa: '/ˈfʌŋkʃən/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['功能；作用', '运转；正常工作'],
      example: 'The search function finds a word by its common variant.',
      exampleTranslation: '搜索功能可以通过常见变体找到词条。',
    ),
    'identify': DictionaryEntry(
      word: 'identify',
      ipa: '/aɪˈdentɪfaɪ/',
      partOfSpeech: 'v. 动词',
      meanings: ['识别；确认', '发现；找出'],
      example:
          'Try to identify the main idea before translating the paragraph.',
      exampleTranslation: '翻译段落前先尝试找出主旨。',
    ),
    'impact': DictionaryEntry(
      word: 'impact',
      ipa: '/ˈɪmpækt/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['影响；作用', '影响；冲击'],
      example: 'Regular listening has a strong impact on pronunciation.',
      exampleTranslation: '规律听力练习会显著影响发音。',
    ),
    'indicate': DictionaryEntry(
      word: 'indicate',
      ipa: '/ˈɪndɪkeɪt/',
      partOfSpeech: 'v. 动词',
      meanings: ['表明；显示', '指出；暗示'],
      example: 'The result may indicate that the sentence needs more context.',
      exampleTranslation: '这个结果可能表明句子需要更多语境。',
    ),
    'interpret': DictionaryEntry(
      word: 'interpret',
      ipa: '/ɪnˈtɜːprət/',
      partOfSpeech: 'v. 动词',
      meanings: ['解释；说明', '口译；理解'],
      example: 'Readers interpret a sentence by combining words and context.',
      exampleTranslation: '读者结合词语和语境来理解句子。',
    ),
    'involve': DictionaryEntry(
      word: 'involve',
      ipa: '/ɪnˈvɒlv/',
      partOfSpeech: 'v. 动词',
      meanings: ['包含；涉及', '使参与；牵涉'],
      example: 'Effective learning involves reading, listening, and review.',
      exampleTranslation: '有效学习包括阅读、听力和复习。',
    ),
    'maintain': DictionaryEntry(
      word: 'maintain',
      ipa: '/meɪnˈteɪn/',
      partOfSpeech: 'v. 动词',
      meanings: ['维持；保持', '维护；坚持认为'],
      example: 'Maintain a steady pace instead of studying everything at once.',
      exampleTranslation: '保持稳定节奏，不要一次学完所有内容。',
    ),
    'major': DictionaryEntry(
      word: 'major',
      ipa: '/ˈmeɪdʒə(r)/',
      partOfSpeech: 'adj./n./v. 形容词/名词/动词',
      meanings: ['主要的；重大的', '专业；主修'],
      example: 'The article presents one major reason for the change.',
      exampleTranslation: '文章提出了这一变化的一个主要原因。',
    ),
    'occur': DictionaryEntry(
      word: 'occur',
      ipa: '/əˈkɜː(r)/',
      partOfSpeech: 'v. 动词',
      meanings: ['发生；出现', '想到；想起'],
      example:
          'Errors often occur when a phrase is translated without context.',
      exampleTranslation: '脱离语境翻译短语时经常会出现错误。',
    ),
    'participate': DictionaryEntry(
      word: 'participate',
      ipa: '/pɑːˈtɪsɪpeɪt/',
      partOfSpeech: 'v. 动词',
      meanings: ['参加；参与', '分享；分担'],
      example: 'Participate in a short conversation every day.',
      exampleTranslation: '每天参加一次简短的对话练习。',
    ),
    'period': DictionaryEntry(
      word: 'period',
      ipa: '/ˈpɪəriəd/',
      partOfSpeech: 'n. 名词',
      meanings: ['时期；阶段', '一段时间；句号'],
      example: 'Set a short study period and take a clear break afterward.',
      exampleTranslation: '安排一段短学习时间，之后明确休息。',
    ),
    'policy': DictionaryEntry(
      word: 'policy',
      ipa: '/ˈpɒləsi/',
      partOfSpeech: 'n. 名词',
      meanings: ['政策；方针', '原则；策略'],
      example: 'The privacy policy explains where local data is stored.',
      exampleTranslation: '隐私政策说明了本地数据保存在哪里。',
    ),
    'predict': DictionaryEntry(
      word: 'predict',
      ipa: '/prɪˈdɪkt/',
      partOfSpeech: 'v. 动词',
      meanings: ['预测；预言', '预示；预料'],
      example: 'The title may help you predict the topic of the article.',
      exampleTranslation: '标题可能有助于你预测文章的主题。',
    ),
    'principle': DictionaryEntry(
      word: 'principle',
      ipa: '/ˈprɪnsəpəl/',
      partOfSpeech: 'n. 名词',
      meanings: ['原则；原理', '道德准则；信念'],
      example: 'The main principle is to learn meaning through context.',
      exampleTranslation: '核心原则是通过语境学习含义。',
    ),
    'promote': DictionaryEntry(
      word: 'promote',
      ipa: '/prəˈməʊt/',
      partOfSpeech: 'v. 动词',
      meanings: ['促进；推动', '晋升；推广'],
      example: 'Reading and speaking together promote active vocabulary use.',
      exampleTranslation: '阅读和口语结合能促进词汇的主动使用。',
    ),
    'provide': DictionaryEntry(
      word: 'provide',
      ipa: '/prəˈvaɪd/',
      partOfSpeech: 'v. 动词',
      meanings: ['提供；供应', '规定；准备'],
      example: 'The entry provides a natural example for the main meaning.',
      exampleTranslation: '词条为主要词义提供了一个自然例句。',
    ),
    'publish': DictionaryEntry(
      word: 'publish',
      ipa: '/ˈpʌblɪʃ/',
      partOfSpeech: 'v. 动词',
      meanings: ['出版；发表', '公布；刊登'],
      example:
          'Only reviewed entries can be published in the official package.',
      exampleTranslation: '只有经过审核的词条才能发布到官方词包中。',
    ),
    'range': DictionaryEntry(
      word: 'range',
      ipa: '/reɪndʒ/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['范围；区间', '排列；包括'],
      example: 'The course covers a wide range of reading topics.',
      exampleTranslation: '这门课程涵盖广泛的阅读主题。',
    ),
    'recommend': DictionaryEntry(
      word: 'recommend',
      ipa: '/ˌrekəˈmend/',
      partOfSpeech: 'v. 动词',
      meanings: ['推荐；建议', '使受欢迎；劝告'],
      example: 'Teachers recommend reviewing a word in several contexts.',
      exampleTranslation: '老师建议在不同语境中复习一个词。',
    ),
    'reflect': DictionaryEntry(
      word: 'reflect',
      ipa: '/rɪˈflekt/',
      partOfSpeech: 'v. 动词',
      meanings: ['反映；体现', '反思；认真思考'],
      example: 'Your notes should reflect what you actually understood.',
      exampleTranslation: '你的笔记应该反映你真正理解的内容。',
    ),
    'relevant': DictionaryEntry(
      word: 'relevant',
      ipa: '/ˈreləvənt/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['相关的；切题的', '有用的；适当的'],
      example: 'Keep only relevant examples in a short study note.',
      exampleTranslation: '简短学习笔记只保留相关例句。',
    ),
    'respond': DictionaryEntry(
      word: 'respond',
      ipa: '/rɪˈspɒnd/',
      partOfSpeech: 'v. 动词',
      meanings: ['回答；回应', '作出反应；响应'],
      example:
          'Try to respond in English before checking the suggested answer.',
      exampleTranslation: '查看参考答案前先尝试用英语回答。',
    ),
    'role': DictionaryEntry(
      word: 'role',
      ipa: '/rəʊl/',
      partOfSpeech: 'n. 名词',
      meanings: ['作用；职责', '角色；人物'],
      example: 'Context plays an important role in translation.',
      exampleTranslation: '语境在翻译中起着重要作用。',
    ),
    'select': DictionaryEntry(
      word: 'select',
      ipa: '/sɪˈlekt/',
      partOfSpeech: 'v./adj. 动词/形容词',
      meanings: ['选择；挑选', '精选的；优等的'],
      example: 'Select a few words that you can use today.',
      exampleTranslation: '选择几个今天能用到的单词。',
    ),
    'similar': DictionaryEntry(
      word: 'similar',
      ipa: '/ˈsɪmələ(r)/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['相似的；类似的', '相仿的；相像的'],
      example: 'Compare similar words to notice their differences.',
      exampleTranslation: '比较相似的词，注意它们的不同。',
    ),
    'source': DictionaryEntry(
      word: 'source',
      ipa: '/sɔːs/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['来源；出处', '从……获得；寻找来源'],
      example: 'Every published entry records its source and license.',
      exampleTranslation: '每条已发布词条都会记录来源和许可证。',
    ),
    'structure': DictionaryEntry(
      word: 'structure',
      ipa: '/ˈstrʌktʃə(r)/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['结构；构造', '组织；安排'],
      example: 'Understanding the sentence structure prevents confusion.',
      exampleTranslation: '理解句子结构可以避免困惑。',
    ),
    'strategy': DictionaryEntry(
      word: 'strategy',
      ipa: '/ˈstrætədʒi/',
      partOfSpeech: 'n. 名词',
      meanings: ['策略；方法', '战略；行动计划'],
      example: 'Choose a review strategy that matches your goal.',
      exampleTranslation: '选择符合目标的复习策略。',
    ),
    'subject': DictionaryEntry(
      word: 'subject',
      ipa: '/ˈsʌbdʒɪkt/',
      partOfSpeech: 'n./adj./v. 名词/形容词/动词',
      meanings: ['主题；话题', '学科；主语；使遭受'],
      example: 'The subject of the article is easy to identify from the title.',
      exampleTranslation: '从标题很容易确定文章的主题。',
    ),
    'target': DictionaryEntry(
      word: 'target',
      ipa: '/ˈtɑːɡɪt/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['目标；对象', '把……作为目标；面向'],
      example: 'Set a realistic target for the number of words you review.',
      exampleTranslation: '为复习词数设定一个现实的目标。',
    ),
    'task': DictionaryEntry(
      word: 'task',
      ipa: '/tɑːsk/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['任务；工作', '派给……任务；使过度劳累'],
      example: 'Finish one small task before starting the next lesson.',
      exampleTranslation: '开始下一课前先完成一个小任务。',
    ),
    'tend': DictionaryEntry(
      word: 'tend',
      ipa: '/tend/',
      partOfSpeech: 'v. 动词',
      meanings: ['往往会；倾向于', '照料；护理'],
      example: 'Learners tend to remember words that they use often.',
      exampleTranslation: '学习者往往更容易记住经常使用的单词。',
    ),
    'text': DictionaryEntry(
      word: 'text',
      ipa: '/tekst/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['文本；文章', '发短信；用文字表达'],
      example: 'Read the text once for its main idea before checking details.',
      exampleTranslation: '先通读文本了解主旨，再查看细节。',
    ),
    'transfer': DictionaryEntry(
      word: 'transfer',
      ipa: '/trænsˈfɜː(r)/',
      partOfSpeech: 'v./n. 动词/名词',
      meanings: ['转移；转让', '转学；换乘；转录'],
      example: 'Transfer a useful phrase from the article to your notebook.',
      exampleTranslation: '把文章中的实用短语抄到笔记本里。',
    ),
    'trend': DictionaryEntry(
      word: 'trend',
      ipa: '/trend/',
      partOfSpeech: 'n./v. 名词/动词',
      meanings: ['趋势；倾向', '趋向；倾向于'],
      example: 'The chart shows a clear trend in daily reading time.',
      exampleTranslation: '图表显示了每日阅读时间的明显趋势。',
    ),
    'vary': DictionaryEntry(
      word: 'vary',
      ipa: '/ˈveəri/',
      partOfSpeech: 'v. 动词',
      meanings: ['变化；不同', '改变；使多样化'],
      example: 'The meaning may vary according to the context.',
      exampleTranslation: '词义可能会根据语境而变化。',
    ),
    'version': DictionaryEntry(
      word: 'version',
      ipa: '/ˈvɜːʃn/',
      partOfSpeech: 'n. 名词',
      meanings: ['版本；译本', '说法；形式'],
      example: 'Read the original and translated versions side by side.',
      exampleTranslation: '把原文和译文并排阅读。',
    ),
  };

  /// The next self-authored expansion slice is kept separate from the
  /// starter words so each editorial batch can be audited and replaced
  /// without rewriting the runtime lookup code.
  static const _expansionEntries = <String, DictionaryEntry>{
    'academic': DictionaryEntry(
      word: 'academic',
      ipa: '/ˌækəˈdemɪk/',
      partOfSpeech: 'adj. 形容词；n. 名词',
      meanings: ['学术的；学业的', '学者；学术人员'],
      example: 'Academic writing requires clear evidence.',
      exampleTranslation: '学术写作需要清晰的证据。',
      coverageBands: ['cet4'],
    ),
    'adequate': DictionaryEntry(
      word: 'adequate',
      ipa: '/ˈædɪkwət/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['足够的；适当的', '合格的；能满足需要的'],
      example: 'The report provides adequate detail for a first review.',
      exampleTranslation: '这份报告提供了足够的细节，适合进行第一次审阅。',
      coverageBands: ['cet4'],
    ),
    'annual': DictionaryEntry(
      word: 'annual',
      ipa: '/ˈænjuəl/',
      partOfSpeech: 'adj. 形容词；n. 名词',
      meanings: ['每年的；年度的', '年刊；年鉴'],
      example: 'The team publishes an annual review of its progress.',
      exampleTranslation: '团队每年都会发布一份进展报告。',
      coverageBands: ['cet4'],
    ),
    'appreciate': DictionaryEntry(
      word: 'appreciate',
      ipa: '/əˈpriːʃieɪt/',
      partOfSpeech: 'v. 动词',
      meanings: ['欣赏；重视', '理解；意识到'],
      example: 'Readers appreciate examples that clarify an abstract idea.',
      exampleTranslation: '读者很重视能够阐明抽象观点的例子。',
      coverageBands: ['cet4'],
    ),
    'approve': DictionaryEntry(
      word: 'approve',
      ipa: '/əˈpruːv/',
      partOfSpeech: 'v. 动词',
      meanings: ['批准；通过', '赞成；认可'],
      example: 'The committee approved the plan after a careful review.',
      exampleTranslation: '委员会仔细审查后批准了这项计划。',
      coverageBands: ['cet4'],
    ),
    'arise': DictionaryEntry(
      word: 'arise',
      ipa: '/əˈraɪz/',
      partOfSpeech: 'v. 动词',
      meanings: ['出现；发生', '由……引起；产生'],
      example: 'Questions often arise when a term is used without context.',
      exampleTranslation: '一个术语脱离语境使用时，常常会产生疑问。',
      coverageBands: ['cet4'],
    ),
    'assign': DictionaryEntry(
      word: 'assign',
      ipa: '/əˈsaɪn/',
      partOfSpeech: 'v. 动词',
      meanings: ['分配；布置', '指派；指定'],
      example: 'The teacher assigned a short translation exercise.',
      exampleTranslation: '老师布置了一道简短的翻译练习。',
      coverageBands: ['cet4'],
    ),
    'attitude': DictionaryEntry(
      word: 'attitude',
      ipa: '/ˈætɪtjuːd/',
      partOfSpeech: 'n. 名词',
      meanings: ['态度；看法', '姿态；心态'],
      example: 'A patient attitude makes language practice more effective.',
      exampleTranslation: '耐心的态度会让语言练习更有效。',
      coverageBands: ['cet4'],
    ),
    'audience': DictionaryEntry(
      word: 'audience',
      ipa: '/ˈɔːdiəns/',
      partOfSpeech: 'n. 名词',
      meanings: ['观众；听众', '读者群；受众'],
      example: 'The speaker adjusted the explanation for a wider audience.',
      exampleTranslation: '演讲者调整了解释，以适应更广泛的听众。',
      coverageBands: ['cet4'],
    ),
    'capacity': DictionaryEntry(
      word: 'capacity',
      ipa: '/kəˈpæsəti/',
      partOfSpeech: 'n. 名词',
      meanings: ['能力；才能', '容量；容纳量'],
      example: 'The library has the capacity to support quiet group study.',
      exampleTranslation: '这座图书馆有能力支持安静的小组学习。',
      coverageBands: ['cet4'],
    ),
    'circumstance': DictionaryEntry(
      word: 'circumstance',
      ipa: '/ˈsɜːkəmstæns/',
      partOfSpeech: 'n. 名词',
      meanings: ['情况；情形', '环境；境况'],
      example: 'The best choice may change with the circumstances.',
      exampleTranslation: '最佳选择可能会随情况而改变。',
      coverageBands: ['cet4'],
    ),
    'climate': DictionaryEntry(
      word: 'climate',
      ipa: '/ˈklaɪmət/',
      partOfSpeech: 'n. 名词',
      meanings: ['气候', '氛围；形势'],
      example: 'A changing climate affects agriculture and water supplies.',
      exampleTranslation: '气候变化会影响农业和水资源供应。',
      coverageBands: ['cet4'],
    ),
    'colleague': DictionaryEntry(
      word: 'colleague',
      ipa: '/ˈkɒliːɡ/',
      partOfSpeech: 'n. 名词',
      meanings: ['同事；同僚', '同行；同业人员'],
      example: 'A colleague helped me check the technical terms.',
      exampleTranslation: '一位同事帮我核对了专业术语。',
      coverageBands: ['cet4'],
    ),
    'compete': DictionaryEntry(
      word: 'compete',
      ipa: '/kəmˈpiːt/',
      partOfSpeech: 'v. 动词',
      meanings: ['竞争；比赛', '争夺；抗衡'],
      example: 'Small teams can compete by offering careful service.',
      exampleTranslation: '小团队可以通过提供细致的服务来参与竞争。',
      coverageBands: ['cet4'],
    ),
    'component': DictionaryEntry(
      word: 'component',
      ipa: '/kəmˈpəʊnənt/',
      partOfSpeech: 'n. 名词',
      meanings: ['组成部分；部件', '成分；要素'],
      example: 'Each component of the lesson has a clear purpose.',
      exampleTranslation: '这节课的每个组成部分都有明确的目的。',
      coverageBands: ['cet4'],
    ),
    'concentrate': DictionaryEntry(
      word: 'concentrate',
      ipa: '/ˈkɒnsəntreɪt/',
      partOfSpeech: 'v. 动词；n. 名词',
      meanings: ['集中注意力；专心', '浓缩物；浓缩液'],
      example: 'Turn off notifications so you can concentrate on reading.',
      exampleTranslation: '关掉通知，这样你就能专心阅读。',
      coverageBands: ['cet4'],
    ),
    'consequence': DictionaryEntry(
      word: 'consequence',
      ipa: '/ˈkɒnsɪkwəns/',
      partOfSpeech: 'n. 名词',
      meanings: ['后果；结果', '重要性'],
      example: 'Every design decision has a consequence for the reader.',
      exampleTranslation: '每个设计决定都会对读者产生影响。',
      coverageBands: ['cet4'],
    ),
    'consist': DictionaryEntry(
      word: 'consist',
      ipa: '/kənˈsɪst/',
      partOfSpeech: 'v. 动词',
      meanings: ['由……组成', '在于；存在于'],
      example: 'The course consists of short lessons and weekly reviews.',
      exampleTranslation: '这门课程由短课和每周复习组成。',
      coverageBands: ['cet4'],
    ),
    'consume': DictionaryEntry(
      word: 'consume',
      ipa: '/kənˈsjuːm/',
      partOfSpeech: 'v. 动词',
      meanings: ['消耗；消费', '吃；喝；耗尽'],
      example: 'Large files consume more storage than plain text.',
      exampleTranslation: '大文件比纯文本消耗更多存储空间。',
      coverageBands: ['cet4'],
    ),
    'contemporary': DictionaryEntry(
      word: 'contemporary',
      ipa: '/kənˈtempərəri/',
      partOfSpeech: 'adj. 形容词；n. 名词',
      meanings: ['当代的；现代的', '同时代的人；同代事物'],
      example:
          'The article compares contemporary research with older theories.',
      exampleTranslation: '这篇文章将当代研究与较早的理论进行了比较。',
      coverageBands: ['cet4'],
    ),
    'cooperate': DictionaryEntry(
      word: 'cooperate',
      ipa: '/kəʊˈɒpəreɪt/',
      partOfSpeech: 'v. 动词',
      meanings: ['合作；协作', '配合；协助'],
      example: 'The two departments cooperate on language resources.',
      exampleTranslation: '两个部门共同建设语言资源。',
      coverageBands: ['cet4'],
    ),
    'decline': DictionaryEntry(
      word: 'decline',
      ipa: '/dɪˈklaɪn/',
      partOfSpeech: 'v. 动词；n. 名词',
      meanings: ['下降；减少', '婉拒；谢绝'],
      example: 'Reading speed may decline when the text becomes unfamiliar.',
      exampleTranslation: '遇到不熟悉的文本时，阅读速度可能会下降。',
      coverageBands: ['cet4'],
    ),
    'emerge': DictionaryEntry(
      word: 'emerge',
      ipa: '/ɪˈmɜːdʒ/',
      partOfSpeech: 'v. 动词',
      meanings: ['出现；浮现', '显露；形成'],
      example: 'A clearer pattern emerged after the data was organized.',
      exampleTranslation: '数据整理后，一个更清晰的模式浮现出来。',
      coverageBands: ['cet4'],
    ),
    'enable': DictionaryEntry(
      word: 'enable',
      ipa: '/ɪˈneɪbl/',
      partOfSpeech: 'v. 动词',
      meanings: ['使能够；使可行', '启用；使生效'],
      example:
          'The note feature enables learners to record their own examples.',
      exampleTranslation: '笔记功能让学习者可以记录自己的例句。',
      coverageBands: ['cet4'],
    ),
    'encounter': DictionaryEntry(
      word: 'encounter',
      ipa: '/ɪnˈkaʊntə(r)/',
      partOfSpeech: 'v. 动词；n. 名词',
      meanings: ['遇到；遭遇', '偶然碰见；经历'],
      example: 'You may encounter unfamiliar phrases in a research paper.',
      exampleTranslation: '你可能会在研究论文中遇到不熟悉的短语。',
      coverageBands: ['cet4'],
    ),
    'enhance': DictionaryEntry(
      word: 'enhance',
      ipa: '/ɪnˈhɑːns/',
      partOfSpeech: 'v. 动词',
      meanings: ['增强；提高', '改善；美化'],
      example: 'Examples enhance the usefulness of a dictionary entry.',
      exampleTranslation: '例句能增强词典词条的实用性。',
      coverageBands: ['cet4'],
    ),
    'ensure': DictionaryEntry(
      word: 'ensure',
      ipa: '/ɪnˈʃʊə(r)/',
      partOfSpeech: 'v. 动词',
      meanings: ['确保；保证', '使安全；使稳固'],
      example: 'A final review helps ensure that the meaning is accurate.',
      exampleTranslation: '最后复核有助于确保词义准确。',
      coverageBands: ['cet4'],
    ),
    'equivalent': DictionaryEntry(
      word: 'equivalent',
      ipa: '/ɪˈkwɪvələnt/',
      partOfSpeech: 'adj. 形容词；n. 名词',
      meanings: ['等价的；相等的', '对应物；等值物'],
      example: 'There is no exact equivalent for every cultural expression.',
      exampleTranslation: '并非每个文化表达都有完全对应的说法。',
      coverageBands: ['cet4'],
    ),
    'evolve': DictionaryEntry(
      word: 'evolve',
      ipa: '/ɪˈvɒlv/',
      partOfSpeech: 'v. 动词',
      meanings: ['发展；演变', '逐步形成；进化'],
      example: 'A useful study routine can evolve through daily practice.',
      exampleTranslation: '有效的学习习惯可以在每日练习中逐步形成。',
      coverageBands: ['cet4'],
    ),
    'generate': DictionaryEntry(
      word: 'generate',
      ipa: '/ˈdʒenəreɪt/',
      partOfSpeech: 'v. 动词',
      meanings: ['产生；生成', '引起；造成'],
      example: 'The discussion generated several useful questions.',
      exampleTranslation: '这场讨论产生了几个有用的问题。',
      coverageBands: ['cet4'],
    ),
    'abandon': DictionaryEntry(
      word: 'abandon',
      ipa: '/əˈbændən/',
      partOfSpeech: 'v. 动词；n. 名词',
      meanings: ['放弃；抛弃', '放任；纵情'],
      example: 'Do not abandon a reading plan after one difficult article.',
      exampleTranslation: '不要因为一篇文章很难就放弃阅读计划。',
      coverageBands: ['cet6'],
    ),
    'absolute': DictionaryEntry(
      word: 'absolute',
      ipa: '/ˈæbsəluːt/',
      partOfSpeech: 'adj. 形容词；n. 名词',
      meanings: ['绝对的；完全的', '绝对事物；绝对真理'],
      example: 'The claim should not be treated as an absolute truth.',
      exampleTranslation: '不应把这个观点当作绝对真理。',
      coverageBands: ['cet6'],
    ),
    'abstract': DictionaryEntry(
      word: 'abstract',
      ipa: '/ˈæbstrækt/',
      partOfSpeech: 'adj. 形容词；n. 名词；v. 动词',
      meanings: ['抽象的；理论的', '摘要；提取'],
      example: 'The abstract summarizes the question, method, and result.',
      exampleTranslation: '摘要概述了问题、方法和结果。',
      coverageBands: ['cet6'],
    ),
    'abundant': DictionaryEntry(
      word: 'abundant',
      ipa: '/əˈbʌndənt/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['丰富的；充足的', '大量存在的'],
      example: 'The archive contains abundant material for language study.',
      exampleTranslation: '这个资料库包含丰富的语言学习材料。',
      coverageBands: ['cet6'],
    ),
    'advocate': DictionaryEntry(
      word: 'advocate',
      ipa: '/ˈædvəkeɪt/',
      partOfSpeech: 'v. 动词；n. 名词',
      meanings: ['提倡；主张', '倡导者；拥护者'],
      example: 'Many teachers advocate regular review rather than cramming.',
      exampleTranslation: '许多老师提倡规律复习，而不是临时突击。',
      coverageBands: ['cet6'],
    ),
    'apparent': DictionaryEntry(
      word: 'apparent',
      ipa: '/əˈpærənt/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['明显的；显而易见的', '表面上的；貌似的'],
      example:
          'The apparent contradiction disappears after the term is defined.',
      exampleTranslation: '定义术语后，这个表面上的矛盾就消失了。',
      coverageBands: ['cet6'],
    ),
    'attribute': DictionaryEntry(
      word: 'attribute',
      ipa: '/əˈtrɪbjuːt/',
      partOfSpeech: 'v. 动词；n. 名词',
      meanings: ['把……归因于', '特征；属性'],
      example: 'The study attributes the change to improved access to books.',
      exampleTranslation: '这项研究把变化归因于图书获取更加方便。',
      coverageBands: ['cet6'],
    ),
    'behalf': DictionaryEntry(
      word: 'behalf',
      ipa: '/bɪˈhɑːf/',
      partOfSpeech: 'n. 名词',
      meanings: ['代表；为了……的利益', '替……发言'],
      example: 'I am writing on behalf of the study group.',
      exampleTranslation: '我谨代表学习小组写这封信。',
      coverageBands: ['cet6'],
    ),
    'collapse': DictionaryEntry(
      word: 'collapse',
      ipa: '/kəˈlæps/',
      partOfSpeech: 'v. 动词；n. 名词',
      meanings: ['倒塌；崩溃', '失败；突然减弱'],
      example: 'The argument may collapse if its main evidence is removed.',
      exampleTranslation: '如果删去主要证据，这个论证可能会失效。',
      coverageBands: ['cet6'],
    ),
    'comprehensive': DictionaryEntry(
      word: 'comprehensive',
      ipa: '/ˌkɒmprɪˈhensɪv/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['全面的；综合的', '详尽的；广泛的'],
      example: 'The guide gives a comprehensive view of the reading process.',
      exampleTranslation: '这份指南全面介绍了阅读过程。',
      coverageBands: ['cet6'],
    ),
    'convert': DictionaryEntry(
      word: 'convert',
      ipa: '/kənˈvɜːt/',
      partOfSpeech: 'v. 动词；n. 名词',
      meanings: ['转换；转变', '使改变信仰或观点；改信者'],
      example: 'The tool can convert a saved note into a review card.',
      exampleTranslation: '这个工具可以把保存的笔记转换成复习卡片。',
      coverageBands: ['cet6'],
    ),
    'derive': DictionaryEntry(
      word: 'derive',
      ipa: '/dɪˈraɪv/',
      partOfSpeech: 'v. 动词',
      meanings: ['获得；取得', '源自；推导出'],
      example:
          'The conclusion is derived from several independent observations.',
      exampleTranslation: '这个结论由几项相互独立的观察推导而来。',
      coverageBands: ['cet6'],
    ),
    'emphasize': DictionaryEntry(
      word: 'emphasize',
      ipa: '/ˈemfəsaɪz/',
      partOfSpeech: 'v. 动词',
      meanings: ['强调；着重', '使突出；重视'],
      example: 'The teacher emphasized the difference between two usages.',
      exampleTranslation: '老师强调了两种用法之间的区别。',
      coverageBands: ['cet6'],
    ),
    'expose': DictionaryEntry(
      word: 'expose',
      ipa: '/ɪkˈspəʊz/',
      partOfSpeech: 'v. 动词',
      meanings: ['暴露；揭露', '使接触；使体验'],
      example:
          'Reading widely exposes learners to different styles of English.',
      exampleTranslation: '广泛阅读能让学习者接触不同的英语文体。',
      coverageBands: ['cet6'],
    ),
    'flexible': DictionaryEntry(
      word: 'flexible',
      ipa: '/ˈfleksəbl/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['灵活的；可变通的', '柔韧的；有弹性的'],
      example: 'A flexible plan can adapt to a busy working day.',
      exampleTranslation: '灵活的计划可以适应忙碌的工作日。',
      coverageBands: ['cet6'],
    ),
    'furthermore': DictionaryEntry(
      word: 'furthermore',
      ipa: '/ˌfɜːðəˈmɔː(r)/',
      partOfSpeech: 'adv. 副词',
      meanings: ['此外；而且', '进一步说'],
      example: 'The method is simple; furthermore, it works offline.',
      exampleTranslation: '这个方法很简单；此外，它还可以离线运行。',
      coverageBands: ['cet6'],
    ),
    'integrate': DictionaryEntry(
      word: 'integrate',
      ipa: '/ˈɪntɪɡreɪt/',
      partOfSpeech: 'v. 动词',
      meanings: ['整合；使融入', '使成为一体；使结合'],
      example:
          'The lesson integrates listening, speaking, and writing practice.',
      exampleTranslation: '这节课把听、说、写练习整合在一起。',
      coverageBands: ['cet6'],
    ),
    'mutual': DictionaryEntry(
      word: 'mutual',
      ipa: '/ˈmjuːtʃuəl/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['相互的；共同的', '彼此的；共有的'],
      example: 'Trust grows through mutual respect and clear communication.',
      exampleTranslation: '信任通过相互尊重和清晰沟通逐步建立。',
      coverageBands: ['cet6'],
    ),
    'obtain': DictionaryEntry(
      word: 'obtain',
      ipa: '/əbˈteɪn/',
      partOfSpeech: 'v. 动词',
      meanings: ['获得；取得', '得到；存在'],
      example: 'Students can obtain a copy of the reading notes locally.',
      exampleTranslation: '学生可以在本地获取一份阅读笔记。',
      coverageBands: ['cet6'],
    ),
    'overall': DictionaryEntry(
      word: 'overall',
      ipa: '/ˌəʊvərˈɔːl/',
      partOfSpeech: 'adj. 形容词；adv. 副词；n. 名词',
      meanings: ['总体的；全面的', '总的来说；总体上'],
      example: 'Overall, the revised explanation is easier to follow.',
      exampleTranslation: '总的来说，修改后的解释更容易理解。',
      coverageBands: ['cet6'],
    ),
    'hypothesis': DictionaryEntry(
      word: 'hypothesis',
      ipa: '/haɪˈpɒθəsɪs/',
      partOfSpeech: 'n. 名词',
      meanings: ['假设；假说', '推测；假定'],
      example: 'The experiment was designed to test a clear hypothesis.',
      exampleTranslation: '这项实验旨在检验一个明确的假设。',
      coverageBands: ['graduate'],
    ),
    'sustainable': DictionaryEntry(
      word: 'sustainable',
      ipa: '/səˈsteɪnəbl/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['可持续的', '能长期维持的；不破坏环境的'],
      example: 'A sustainable study routine leaves time for rest.',
      exampleTranslation: '可持续的学习安排会留出休息时间。',
      coverageBands: ['cet6'],
    ),
    'arbitrary': DictionaryEntry(
      word: 'arbitrary',
      ipa: '/ˈɑːbɪtrəri/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['任意的；武断的', '随意决定的；无充分理由的'],
      example: 'The cutoff should not be an arbitrary number.',
      exampleTranslation: '这个界限不应是一个武断的数字。',
      coverageBands: ['graduate'],
    ),
    'coherent': DictionaryEntry(
      word: 'coherent',
      ipa: '/kəʊˈhɪərənt/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['连贯的；条理清楚的', '一致的；协调的'],
      example: 'A coherent paragraph connects each sentence to one main idea.',
      exampleTranslation: '连贯的段落会把每个句子都和一个中心观点联系起来。',
      coverageBands: ['graduate'],
    ),
    'constrain': DictionaryEntry(
      word: 'constrain',
      ipa: '/kənˈstreɪn/',
      partOfSpeech: 'v. 动词',
      meanings: ['限制；约束', '迫使；使受拘束'],
      example: 'Limited time can constrain the depth of a first review.',
      exampleTranslation: '时间有限可能会限制第一次复核的深度。',
      coverageBands: ['graduate'],
    ),
    'empirical': DictionaryEntry(
      word: 'empirical',
      ipa: '/ɪmˈpɪrɪkl/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['以观察或实验为依据的', '经验主义的；实证的'],
      example: 'The claim needs empirical support before it can be accepted.',
      exampleTranslation: '这个观点在被接受前需要实证支持。',
      coverageBands: ['graduate'],
    ),
    'facilitate': DictionaryEntry(
      word: 'facilitate',
      ipa: '/fəˈsɪlɪteɪt/',
      partOfSpeech: 'v. 动词',
      meanings: ['促进；使便利', '帮助；使容易'],
      example:
          'Short examples facilitate the understanding of difficult terms.',
      exampleTranslation: '简短的例子有助于理解困难术语。',
      coverageBands: ['graduate'],
    ),
    'implicit': DictionaryEntry(
      word: 'implicit',
      ipa: '/ɪmˈplɪsɪt/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['含蓄的；不直接表达的', '内含的；不言明的'],
      example:
          'The translation should preserve both explicit and implicit meaning.',
      exampleTranslation: '翻译应保留明确含义和隐含含义。',
      coverageBands: ['graduate'],
    ),
    'mitigate': DictionaryEntry(
      word: 'mitigate',
      ipa: '/ˈmɪtɪɡeɪt/',
      partOfSpeech: 'v. 动词',
      meanings: ['减轻；缓和', '缓解不利影响'],
      example: 'Clear headings can mitigate the difficulty of a long article.',
      exampleTranslation: '清晰的标题可以减轻长篇文章的阅读难度。',
      coverageBands: ['graduate'],
    ),
    'rigorous': DictionaryEntry(
      word: 'rigorous',
      ipa: '/ˈrɪɡərəs/',
      partOfSpeech: 'adj. 形容词',
      meanings: ['严谨的；严格的', '缜密的；细致的'],
      example:
          'A rigorous dictionary review checks meaning, usage, and source.',
      exampleTranslation: '严谨的词典审查会核对词义、用法和来源。',
      coverageBands: ['graduate'],
    ),
  };

  static final _allEntries = _buildAllEntries();
  static final _variantEntries = _buildVariantEntries();

  static Map<String, DictionaryEntry> _buildAllEntries() {
    final result = <String, DictionaryEntry>{};

    void add(DictionaryEntry entry) {
      final key = entry.word.trim().toLowerCase();
      final previous = result[key];
      if (previous == null) {
        result[key] = entry;
        return;
      }

      // Later project-authored rows keep their richer fields, but an entry
      // must retain every verified coverage label gathered from the source
      // layers it supersedes.
      final coverageBands = <String>{
        ...previous.coverageBands,
        ...entry.coverageBands,
      };
      final hasCandidateEnrichment =
          previous.qualityStatus == 'candidate' ||
          previous.reviewFields.isNotEmpty ||
          previous.senseCandidates.isNotEmpty ||
          previous.exampleCandidates.isNotEmpty;
      final hasAssistantVerifiedEnrichment = previous.qualityStatus.startsWith(
        'assistant_verified',
      );
      final qualityStatus =
          entry.qualityStatus == 'published' && hasAssistantVerifiedEnrichment
          ? 'published_with_assistant_enrichment'
          : entry.qualityStatus == 'published' && hasCandidateEnrichment
          ? 'published_with_candidate_enrichment'
          : entry.qualityStatus != 'candidate'
          ? entry.qualityStatus
          : previous.qualityStatus;
      result[key] = DictionaryEntry(
        word: entry.word,
        ipa: entry.ipa,
        partOfSpeech: entry.partOfSpeech,
        meanings: entry.meanings,
        example: entry.example,
        exampleTranslation: entry.exampleTranslation,
        coverageBands: List.unmodifiable(coverageBands),
        source: entry.source,
        exampleCandidates: entry.exampleCandidates.isNotEmpty
            ? entry.exampleCandidates
            : previous.exampleCandidates,
        senseCandidates: entry.senseCandidates.isNotEmpty
            ? entry.senseCandidates
            : previous.senseCandidates,
        partOfSpeechCandidates: entry.partOfSpeechCandidates.isNotEmpty
            ? entry.partOfSpeechCandidates
            : previous.partOfSpeechCandidates,
        pronunciationCandidates: entry.pronunciationCandidates.isNotEmpty
            ? entry.pronunciationCandidates
            : previous.pronunciationCandidates,
        learningTags: entry.learningTags.isNotEmpty
            ? entry.learningTags
            : previous.learningTags,
        frequency: entry.frequency.isNotEmpty
            ? entry.frequency
            : previous.frequency,
        qualityStatus: qualityStatus,
        reviewFields: entry.reviewFields.isNotEmpty
            ? entry.reviewFields
            : previous.reviewFields,
        candidateSourceIds: entry.candidateSourceIds.isNotEmpty
            ? entry.candidateSourceIds
            : previous.candidateSourceIds,
        variants: entry.variants.isNotEmpty
            ? entry.variants
            : previous.variants,
        collocationCandidates: entry.collocationCandidates.isNotEmpty
            ? entry.collocationCandidates
            : previous.collocationCandidates,
        relationCandidates: entry.relationCandidates.isNotEmpty
            ? entry.relationCandidates
            : previous.relationCandidates,
      );
    }

    for (final row in yxOpenCetDictionaryRows) {
      final candidateExamples =
          yxOpenCetRichExampleRows[row.word] ?? const <OpenCetRichExampleRow>[];
      final candidateSenses =
          yxOpenCetRichSenseRows[row.word] ?? const <OpenCetRichSenseRow>[];
      final candidateMetadata = yxOpenCetRichMetadataRows[row.word];
      final assistantReview = yxOpenCetAssistantReviewRows[row.word];
      final firstCandidate = candidateExamples.isEmpty
          ? null
          : candidateExamples.first;
      add(
        DictionaryEntry(
          word: row.word,
          ipa: row.ipa,
          partOfSpeech: row.partOfSpeech,
          meanings: row.meanings,
          example: firstCandidate?.englishText ?? '',
          exampleTranslation: firstCandidate?.chineseText ?? '',
          coverageBands: row.coverageBands,
          source: openCetDictionarySourceId,
          exampleCandidates: candidateExamples,
          senseCandidates: candidateSenses,
          partOfSpeechCandidates:
              candidateMetadata?.partOfSpeechCandidates ??
              const <OpenCetRichPartOfSpeechRow>[],
          pronunciationCandidates:
              candidateMetadata?.pronunciationCandidates ??
              const <OpenCetRichPronunciationRow>[],
          learningTags: candidateMetadata?.learningTags ?? const <String>[],
          frequency: candidateMetadata?.frequency ?? const <String, int>{},
          qualityStatus:
              assistantReview?.qualityStatus ??
              candidateMetadata?.qualityStatus ??
              'candidate',
          reviewFields:
              assistantReview?.remainingFlags ??
              candidateMetadata?.reviewFields ??
              const <String>[],
          candidateSourceIds:
              assistantReview?.sourceIds ??
              candidateMetadata?.sourceIds ??
              const <String>[],
          variants: candidateMetadata?.variants ?? const <String>[],
          collocationCandidates:
              candidateMetadata?.collocations ?? const <String>[],
          relationCandidates:
              candidateMetadata?.relations ?? const <String, List<String>>{},
        ),
      );
    }
    for (final entry in _entries.values) {
      add(entry);
    }
    for (final entry in _expansionEntries.values) {
      add(entry);
    }
    for (final row in yx500DictionaryRows) {
      add(
        DictionaryEntry(
          word: row.word,
          ipa: row.ipa,
          partOfSpeech: row.partOfSpeech,
          meanings: row.meanings,
          example: row.example,
          exampleTranslation: row.exampleTranslation,
          coverageBands: row.coverageBands,
        ),
      );
    }
    for (final row in yxCet4DictionaryRows) {
      add(
        DictionaryEntry(
          word: row.word,
          ipa: row.ipa,
          partOfSpeech: row.partOfSpeech,
          meanings: row.meanings,
          example: row.example,
          exampleTranslation: row.exampleTranslation,
          coverageBands: const ['foundation', 'cet4'],
        ),
      );
    }
    return Map.unmodifiable(result);
  }

  static Map<String, DictionaryEntry> _buildVariantEntries() {
    final result = <String, DictionaryEntry>{};
    final ambiguous = <String>{};
    final englishWord = RegExp(r"^[a-z]+(?:['-][a-z]+)*$");

    for (final entry in _allEntries.values) {
      for (final rawVariant in entry.variants) {
        final variant = rawVariant.trim().toLowerCase();
        if (variant.isEmpty ||
            !englishWord.hasMatch(variant) ||
            _allEntries.containsKey(variant)) {
          continue;
        }

        final previous = result[variant];
        if (previous == null) {
          result[variant] = entry;
        } else if (previous.word.toLowerCase() != entry.word.toLowerCase()) {
          // Never guess when candidate metadata maps one surface form to
          // multiple headwords. Exact headwords are resolved before this map.
          ambiguous.add(variant);
        }
      }
    }

    for (final variant in ambiguous) {
      result.remove(variant);
    }
    return Map.unmodifiable(result);
  }

  /// All bundled entries available to the learning panel.
  ///
  /// The returned list cannot be mutated by a page. Each entry keeps its
  /// source marker so the open base layer is not confused with the authored
  /// quality slice.
  List<DictionaryEntry> get entries => List.unmodifiable(_allEntries.values);

  DictionaryEntry? lookup(String word) {
    final key = word.trim().toLowerCase();
    return _allEntries[key] ?? _variantEntries[key];
  }

  static const _chineseToEnglish = <String, String>{
    '苹果': 'apple',
    '你好': 'hello',
    '老师': 'teacher',
    '技术': 'technology',
    '翻译': 'translate',
    '语言': 'language',
    '学习': 'learn',
    '理解': 'understand',
    '练习': 'practice',
    '阅读': 'read',
    '写作': 'write',
    '表达': 'speak',
    '倾听': 'listen',
    '研究': 'study',
    '句子': 'sentence',
    '例子': 'example',
    '含义': 'meaning',
    '解释': 'explain',
    '正确': 'correct',
    '重要': 'important',
    '未来': 'future',
    '文化': 'culture',
    '想法': 'idea',
    '工作': 'work',
    '沟通': 'communicate',
    '改进': 'improve',
    '记住': 'remember',
    '复习': 'review',
    '进步': 'progress',
    '目标': 'goal',
    '能力': 'ability',
    '实现': 'achieve',
    '建议': 'advice',
    '影响': 'affect',
    '方法': 'approach',
    '避免': 'avoid',
    '可用': 'available',
    '好处': 'benefit',
    '挑战': 'challenge',
    '比较': 'compare',
    '考虑': 'consider',
    '语境': 'context',
    '描述': 'describe',
    '发展': 'develop',
    '努力': 'effort',
    '环境': 'environment',
    '证据': 'evidence',
    '经验': 'experience',
    '重点': 'focus',
    '习惯': 'habit',
    '问题': 'issue',
    '办法': 'method',
    '机会': 'opportunity',
    '可能': 'possible',
    '需要': 'require',
    '回应': 'response',
    '结果': 'result',
    '方案': 'solution',
    '价值': 'value',
    '接受': 'accept',
    '访问': 'access',
    '账户': 'account',
    '准确': 'accurate',
    '适应': 'adapt',
    '额外': 'additional',
    '优势': 'advantage',
    '分析': 'analysis',
    '应用': 'apply',
    '论证': 'argue',
    '注意': 'attention',
    '原因': 'cause',
    '确定': 'certain',
    '常见': 'common',
    '完整': 'complete',
    '创造': 'create',
    '决定': 'decide',
    '决策': 'decision',
    '细节': 'detail',
    '差异': 'difference',
    '困难': 'difficult',
    '讨论': 'discuss',
    '效果': 'effect',
    '有效': 'effective',
    '一般': 'general',
    '包括': 'include',
    '增加': 'increase',
    '个人': 'individual',
    '作用': 'influence',
    '知识': 'knowledge',
    '资料': 'material',
    '自然': 'natural',
    '察觉': 'notice',
    '提供': 'offer',
    '意见': 'opinion',
    '整理': 'organize',
    '耐心': 'patient',
    '执行': 'perform',
    '准备': 'prepare',
    '压力': 'pressure',
    '防止': 'prevent',
    '过程': 'process',
    '目的': 'purpose',
    '质量': 'quality',
    '意识到': 'realize',
    '减少': 'reduce',
    '联系': 'relate',
    '保持': 'remain',
    '资源': 'resource',
    '具体': 'specific',
    '支持': 'support',
    '社会': 'society',
    '科研': 'research',
    '提议': 'suggest',
    '术语': 'term',
    '理论': 'theory',
    '主题': 'topic',
    '传统': 'traditional',
    '各种': 'various',
    '是否': 'whether',
    '显著': 'significant',
    '承认': 'acknowledge',
    '获得': 'acquire',
    '替代': 'alternative',
    '合适': 'appropriate',
    '方面': 'aspect',
    '假定': 'assume',
    '评估': 'assess',
    '意识': 'aware',
    '复杂': 'complex',
    '概念': 'concept',
    '进行': 'conduct',
    '冲突': 'conflict',
    '贡献': 'contribute',
    '数据': 'data',
    '定义': 'define',
    '证明': 'demonstrate',
    '判定': 'determine',
    '分发': 'distribute',
    '经济': 'economy',
    '建立': 'establish',
    '估计': 'estimate',
    '因素': 'factor',
    '特征': 'feature',
    '功能': 'function',
    '识别': 'identify',
    '冲击': 'impact',
    '表明': 'indicate',
    '口译': 'interpret',
    '涉及': 'involve',
    '维持': 'maintain',
    '主要': 'major',
    '发生': 'occur',
    '参加': 'participate',
    '时期': 'period',
    '政策': 'policy',
    '预测': 'predict',
    '原理': 'principle',
    '促进': 'promote',
    '供给': 'provide',
    '出版': 'publish',
    '范围': 'range',
    '推荐': 'recommend',
    '反映': 'reflect',
    '相关': 'relevant',
    '答复': 'respond',
    '角色': 'role',
    '选择': 'select',
    '相似': 'similar',
    '来源': 'source',
    '结构': 'structure',
    '策略': 'strategy',
    '主语': 'subject',
    '指标': 'target',
    '任务': 'task',
    '倾向': 'tend',
    '文本': 'text',
    '转移': 'transfer',
    '趋势': 'trend',
    '变化': 'vary',
    '版本': 'version',
    '学术': 'academic',
    '足够': 'adequate',
    '年度': 'annual',
    '欣赏': 'appreciate',
    '批准': 'approve',
    '出现': 'arise',
    '分配': 'assign',
    '态度': 'attitude',
    '受众': 'audience',
    '容量': 'capacity',
    '情形': 'circumstance',
    '气候': 'climate',
    '同事': 'colleague',
    '竞争': 'compete',
    '组成部分': 'component',
    '集中注意': 'concentrate',
    '后果': 'consequence',
    '由组成': 'consist',
    '消耗': 'consume',
    '当代': 'contemporary',
    '合作': 'cooperate',
    '下降': 'decline',
    '浮现': 'emerge',
    '使能够': 'enable',
    '遭遇': 'encounter',
    '增强': 'enhance',
    '确保': 'ensure',
    '等价': 'equivalent',
    '演变': 'evolve',
    '产生': 'generate',
    '放弃': 'abandon',
    '绝对': 'absolute',
    '抽象': 'abstract',
    '丰富': 'abundant',
    '倡导': 'advocate',
    '明显': 'apparent',
    '归因': 'attribute',
    '代表': 'behalf',
    '崩溃': 'collapse',
    '全面': 'comprehensive',
    '转换': 'convert',
    '推导': 'derive',
    '强调': 'emphasize',
    '暴露': 'expose',
    '灵活': 'flexible',
    '此外': 'furthermore',
    '整合': 'integrate',
    '相互': 'mutual',
    '获取': 'obtain',
    '总体': 'overall',
    '假设': 'hypothesis',
    '可持续': 'sustainable',
    '任意': 'arbitrary',
    '连贯': 'coherent',
    '约束': 'constrain',
    '实证': 'empirical',
    '便利': 'facilitate',
    '隐含': 'implicit',
    '缓解': 'mitigate',
    '严谨': 'rigorous',
  };

  /// Looks up an exact Chinese single-word entry from the bundled seed data.
  ///
  /// This deliberately stays small and exact: it is a safe word-level
  /// fallback, not a sentence translator or an attempt to replace an
  /// authorized dictionary package.
  DictionaryEntry? lookupChinese(String text) {
    final query = text.trim();
    if (query.isEmpty) return null;
    final english = _chineseToEnglish[query];
    if (english != null) return _allEntries[english];
    for (final entry in _allEntries.values) {
      if (_chineseMeaningTerms(entry.meanings).contains(query)) return entry;
    }
    return null;
  }
}

/// Selects the most useful dictionary result for a single-word lookup.
///
/// Database results can include fuzzy substring matches. A word lookup should
/// never show an unrelated substring result as though it were an exact hit.
DictionaryEntry? bestDictionaryEntryForTerm(
  String query,
  Iterable<DictionaryEntry> candidates,
) {
  final entries = candidates.toList(growable: false);
  if (entries.isEmpty) return null;
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return null;

  for (final entry in entries) {
    if (entry.word.trim().toLowerCase() == normalized) return entry;
  }
  for (final entry in entries) {
    if (_chineseMeaningTerms(entry.meanings).contains(query.trim())) {
      return entry;
    }
  }
  return null;
}

Set<String> _chineseMeaningTerms(Iterable<String> meanings) {
  final terms = <String>{};
  for (final meaning in meanings) {
    for (final rawTerm in meaning.split(RegExp(r'[；;，,、/|]'))) {
      final term = rawTerm.trim();
      if (term.isEmpty) continue;
      terms.add(term);
      final annotation = RegExp(r'[（(][^（）()]*[）)]').firstMatch(term);
      if (annotation != null && annotation.start > 0) {
        final baseMeaning = term.substring(0, annotation.start).trim();
        if (baseMeaning.isNotEmpty) terms.add(baseMeaning);
      }
    }
  }
  return terms;
}

/// Returns the single English word at a caret or in a selected range.
///
/// A phrase, a non-English selection, or an invalid offset is deliberately
/// ignored so the learning panel cannot show a dictionary result for the
/// wrong piece of text.
String? englishWordAtSelection(String text, int start, int end) {
  if (start < 0 || end < 0 || start > text.length || end > text.length) {
    return null;
  }
  final left = start < end ? start : end;
  final right = start < end ? end : start;
  if (left != right) {
    final selected = text.substring(left, right).trim();
    return _isDictionaryWord(selected)
        ? _normalizeDictionaryWord(selected)
        : null;
  }
  if (text.isEmpty) return null;

  var cursor = left;
  if (cursor == text.length) cursor -= 1;
  if (!_isEnglishWordCharacter(text[cursor]) && cursor > 0) {
    cursor -= 1;
  }
  if (!_isEnglishWordCharacter(text[cursor])) return null;

  var wordStart = cursor;
  while (wordStart > 0 && _isEnglishWordCharacter(text[wordStart - 1])) {
    wordStart -= 1;
  }
  var wordEnd = cursor + 1;
  while (wordEnd < text.length && _isEnglishWordCharacter(text[wordEnd])) {
    wordEnd += 1;
  }
  final candidate = text.substring(wordStart, wordEnd);
  return _isDictionaryWord(candidate)
      ? _normalizeDictionaryWord(candidate)
      : null;
}

/// Returns one English word or one compact Chinese dictionary term at a
/// selection/caret. Chinese is accepted only as a short Han-only term; a
/// tokenizer is not available here, so full sentences stay out of this path.
String? dictionaryTermAtSelection(String text, int start, int end) {
  if (start < 0 || end < 0 || start > text.length || end > text.length) {
    return null;
  }
  final left = start < end ? start : end;
  final right = start < end ? end : start;
  if (left != right) {
    final selected = text.substring(left, right).trim();
    final english = englishWordAtSelection(selected, 0, selected.length);
    if (english != null) return english;
    return _isCompactChineseDictionaryTerm(selected) ? selected : null;
  }

  final english = englishWordAtSelection(text, start, end);
  if (english != null) return english;
  if (text.isEmpty) return null;

  var cursor = left;
  if (cursor == text.length) cursor -= 1;
  if (!_isChineseWordCharacter(text[cursor]) && cursor > 0) cursor -= 1;
  if (!_isChineseWordCharacter(text[cursor])) return null;

  var wordStart = cursor;
  while (wordStart > 0 && _isChineseWordCharacter(text[wordStart - 1])) {
    wordStart -= 1;
  }
  var wordEnd = cursor + 1;
  while (wordEnd < text.length && _isChineseWordCharacter(text[wordEnd])) {
    wordEnd += 1;
  }
  final candidate = text.substring(wordStart, wordEnd);
  return _isCompactChineseDictionaryTerm(candidate) ? candidate : null;
}

/// Confirms that a dictionary term appears as a whole word in English OCR, or
/// as an exact substring in Chinese OCR, before forwarding it to the host.
bool dictionaryTermAppearsInText(String term, String text) {
  final normalized = dictionaryTermAtInput(term);
  if (normalized == null) return false;
  final english = englishWordAtSelection(normalized, 0, normalized.length);
  if (english == null) return text.contains(normalized);
  final expected = english.toLowerCase();
  return RegExp(r"[A-Za-z]+(?:['’\-][A-Za-z]+)*")
      .allMatches(text)
      .any(
        (match) =>
            _normalizeDictionaryWord(match.group(0)!).toLowerCase() == expected,
      );
}

/// Returns one exact English word or Chinese dictionary headword from a
/// dedicated lookup field. Chinese headwords cannot be segmented reliably
/// without a tokenizer, so Chinese queries are accepted only when the whole
/// input is a compact Han-character term; sentence translation remains a
/// separate flow.
String? dictionaryTermAtInput(String text) {
  final value = text.trim();
  if (value.isEmpty) return null;
  final english = englishWordAtSelection(value, 0, value.length);
  if (english != null) return english;
  return _isCompactChineseDictionaryTerm(value) ? value : null;
}

String _normalizeDictionaryWord(String value) => value.replaceAll('’', "'");

bool _isChineseWordCharacter(String value) =>
    RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]').hasMatch(value);

bool _isCompactChineseDictionaryTerm(String value) =>
    value.length <= 6 &&
    RegExp(r'^[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]+$').hasMatch(value);

bool _isEnglishWordCharacter(String character) =>
    RegExp(r"[A-Za-z'’\-]").hasMatch(character);

bool _isDictionaryWord(String value) =>
    // Single-letter headwords such as "a" and "I" are valid dictionary
    // entries and can also be selected from subtitles or OCR text.
    value.isNotEmpty &&
    value.length <= 32 &&
    RegExp(r"^[A-Za-z]+(?:['’\-][A-Za-z]+)*$").hasMatch(value);
