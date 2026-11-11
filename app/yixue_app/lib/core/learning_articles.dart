/// Small self-authored reading material for the offline learning workspace.
///
/// These samples are product seed content, not copied textbook or newspaper
/// material. A later content package can use the same contract after its
/// license and source metadata have been checked.
class LearningArticleParagraph {
  const LearningArticleParagraph({
    required this.text,
    required this.translation,
  });

  final String text;
  final String translation;
}

class LearningArticleQuestion {
  const LearningArticleQuestion({
    required this.id,
    required this.prompt,
    required this.choices,
    required this.correctChoiceIndex,
    required this.evidenceParagraphIndex,
    required this.explanation,
  });

  final String id;
  final String prompt;
  final List<String> choices;
  final int correctChoiceIndex;
  final int evidenceParagraphIndex;
  final String explanation;
}

class LearningArticle {
  const LearningArticle({
    required this.id,
    required this.title,
    required this.level,
    required this.description,
    required this.paragraphs,
    required this.vocabulary,
    this.questions = const [],
  });

  final String id;
  final String title;
  final String level;
  final String description;
  final List<LearningArticleParagraph> paragraphs;
  final List<String> vocabulary;
  final List<LearningArticleQuestion> questions;

  int get paragraphCount => paragraphs.length;
}

const builtInLearningArticles = <LearningArticle>[
  LearningArticle(
    id: 'habit-and-progress',
    title: 'A Small Habit',
    level: '基础与日常',
    description: '用一个小习惯说明持续学习为什么有效。',
    paragraphs: [
      LearningArticleParagraph(
        text: 'A small habit can change the way we learn.',
        translation: '一个小习惯可以改变我们的学习方式。',
      ),
      LearningArticleParagraph(
        text: 'Read one short sentence, speak it clearly, and write one note.',
        translation: '读一个短句，把它清楚地说出来，再写下一条笔记。',
      ),
      LearningArticleParagraph(
        text: 'Small steps become real progress when we repeat them every day.',
        translation: '当我们每天重复这些小步骤时，它们就会变成真正的进步。',
      ),
      LearningArticleParagraph(
        text: 'When a task feels difficult, a clear routine gives our attention a place to begin.',
        translation: '当一项任务感觉困难时，清晰的日常安排能让注意力找到开始的地方。',
      ),
      LearningArticleParagraph(
        text: 'The habit does not need to be perfect; it only needs to be easy to return to.',
        translation: '这个习惯不必完美，只需要让我们能够轻松地重新回到学习中。',
      ),
    ],
    vocabulary: [
      'small',
      'habit',
      'change',
      'learn',
      'sentence',
      'speak',
      'write',
      'note',
      'progress',
      'repeat',
      'every',
      'day',
    ],
    questions: [
      LearningArticleQuestion(
        id: 'main-idea',
        prompt: '这篇短文最想表达什么？',
        choices: [
          '学习必须一次完成很多困难任务。',
          '只要写笔记，阅读和练习就不重要。',
          '容易坚持的小步骤能带来持续进步。',
          '学习习惯必须完美才会有效。',
        ],
        correctChoiceIndex: 2,
        evidenceParagraphIndex: 2,
        explanation: '第 3 段说明，每天重复的小步骤会变成真正的进步。',
      ),
      LearningArticleQuestion(
        id: 'difficult-task',
        prompt: '当一项任务感觉困难时，清晰的日常安排有什么作用？',
        choices: [
          '让注意力找到一个可以开始的地方。',
          '保证这项任务马上变得简单。',
          '提醒学习者先把任务完全放下。',
          '让学习者每天更换新的学习目标。',
        ],
        correctChoiceIndex: 0,
        evidenceParagraphIndex: 3,
        explanation: '第 4 段把 routine 描写成注意力开始行动的落脚点。',
      ),
    ],
  ),
  LearningArticle(
    id: 'language-and-ideas',
    title: 'Language Opens a Door',
    level: '高中与六级',
    description: '通过语言、文化和想法的关系练习阅读与表达。',
    paragraphs: [
      LearningArticleParagraph(
        text: 'Learning a new language opens a door to new cultures and ideas.',
        translation: '学习一门新语言，会打开通往新文化和新思想的大门。',
      ),
      LearningArticleParagraph(
        text: 'A clear translation keeps the meaning while respecting the context.',
        translation: '清晰的翻译既保留含义，也尊重语境。',
      ),
      LearningArticleParagraph(
        text: 'The goal is not to replace one voice, but to help more people understand it.',
        translation: '目标不是替代一种声音，而是帮助更多人理解它。',
      ),
      LearningArticleParagraph(
        text: 'Readers notice more when they compare a familiar expression with its cultural context.',
        translation: '当读者把熟悉的表达与它的文化语境进行比较时，往往能发现更多细节。',
      ),
      LearningArticleParagraph(
        text: 'A patient learner keeps the original idea visible while searching for a natural sentence.',
        translation: '有耐心的学习者会保留原意，同时寻找自然的表达方式。',
      ),
    ],
    vocabulary: [
      'language',
      'open',
      'culture',
      'idea',
      'clear',
      'translation',
      'meaning',
      'context',
      'goal',
      'replace',
      'understand',
    ],
    questions: [
      LearningArticleQuestion(
        id: 'translation-context',
        prompt: '根据短文，清晰的翻译需要同时照顾什么？',
        choices: ['句子长度和使用的字体。', '原意和具体语境。', '译者的个人经历和偏好。', '尽可能多的生词。'],
        correctChoiceIndex: 1,
        evidenceParagraphIndex: 1,
        explanation: '第 2 段明确指出，翻译既要保留含义，也要尊重语境。',
      ),
      LearningArticleQuestion(
        id: 'language-goal',
        prompt: '短文怎样描述学习语言的目标？',
        choices: [
          '用新的声音取代原来的声音。',
          '只记住每种文化的事实。',
          '帮助更多人理解另一种声音和想法。',
          '把所有表达都翻译成相同句式。',
        ],
        correctChoiceIndex: 2,
        evidenceParagraphIndex: 2,
        explanation: '第 3 段说，目标是帮助更多人理解，而不是替代原有声音。',
      ),
    ],
  ),
  LearningArticle(
    id: 'evidence-and-clarity',
    title: 'Clear Ideas Need Evidence',
    level: '考研与学术',
    description: '用短篇学术语境练习术语、句子和段落理解。',
    paragraphs: [
      LearningArticleParagraph(
        text: 'Academic writing is clearer when each important claim has evidence.',
        translation: '当每一个重要论断都有证据时，学术写作会更加清晰。',
      ),
      LearningArticleParagraph(
        text: 'Good readers compare the source, the explanation, and the conclusion.',
        translation: '好的读者会比较来源、解释和结论。',
      ),
      LearningArticleParagraph(
        text: 'Careful notes help us return to a difficult idea without losing the context.',
        translation: '仔细的笔记能帮助我们在不丢失语境的情况下重新理解困难的想法。',
      ),
      LearningArticleParagraph(
        text: 'Evidence can be a number, an observation, or a clearly described source.',
        translation: '证据可以是一个数字、一项观察，或一个描述清楚的来源。',
      ),
      LearningArticleParagraph(
        text: 'Learning to question a conclusion is also a way to learn how an argument is built.',
        translation: '学会质疑一个结论，也是学习论证如何建立起来的一种方式。',
      ),
    ],
    vocabulary: [
      'academic',
      'writing',
      'clear',
      'important',
      'claim',
      'evidence',
      'reader',
      'source',
      'explanation',
      'conclusion',
      'careful',
      'difficult',
      'context',
    ],
    questions: [
      LearningArticleQuestion(
        id: 'clear-claim',
        prompt: '什么会让重要论断更清晰可信？',
        choices: ['更长的句子。', '更多的形容词。', '支持论断的证据。', '重复同一个结论。'],
        correctChoiceIndex: 2,
        evidenceParagraphIndex: 0,
        explanation: '第 1 段把清晰的学术写作与论断对应的证据联系起来。',
      ),
      LearningArticleQuestion(
        id: 'evidence-types',
        prompt: '短文列举了哪些证据形式？',
        choices: ['数字、观察或描述清楚的来源。', '观点、标题或个人喜好。', '故事、比喻或修辞问题。', '摘要、翻译或结论。'],
        correctChoiceIndex: 0,
        evidenceParagraphIndex: 3,
        explanation: '第 4 段列举了数字、观察和描述清楚的来源。',
      ),
    ],
  ),
  LearningArticle(
    id: 'a-better-conversation',
    title: 'A Better Conversation',
    level: '基础与日常',
    description: '练习倾听、复述和礼貌表达不同意见。',
    paragraphs: [
      LearningArticleParagraph(
        text: 'A good conversation begins with attention, not clever words.',
        translation: '一次好的交谈始于专注，而不是巧妙的措辞。',
      ),
      LearningArticleParagraph(
        text: 'When a friend shares a problem, listen until the main point is clear.',
        translation: '朋友分享烦恼时，先听到问题的重点变得清楚。',
      ),
      LearningArticleParagraph(
        text: 'You can then repeat the idea in your own words and ask whether you understood it.',
        translation: '然后，你可以用自己的话复述，并询问自己是否理解正确。',
      ),
      LearningArticleParagraph(
        text: 'If you disagree, name the idea you question and explain why without attacking the person.',
        translation: '如果你不同意，可以指出你质疑的观点并说明理由，而不攻击对方。',
      ),
      LearningArticleParagraph(
        text: 'This simple routine gives both people room to think and keeps trust in the conversation.',
        translation: '这个简单的做法给双方留下思考空间，也能让交谈保持信任。',
      ),
    ],
    vocabulary: [
      'attention',
      'conversation',
      'share',
      'problem',
      'repeat',
      'understand',
      'disagree',
      'explain',
      'trust',
    ],
    questions: [
      LearningArticleQuestion(
        id: 'conversation-first-step',
        prompt: '短文认为，一次好的交谈首先需要什么？',
        choices: ['提前准备很多巧妙的话。', '专注地听对方表达。', '马上给出解决办法。', '避免询问对方的问题。'],
        correctChoiceIndex: 1,
        evidenceParagraphIndex: 0,
        explanation: '第 1 段把专注放在巧妙措辞之前。',
      ),
      LearningArticleQuestion(
        id: 'conversation-disagreement',
        prompt: '表达不同意见时，怎样做更合适？',
        choices: ['批评对方的性格。', '只重复自己的结论。', '指出所质疑的观点并说明理由。', '马上结束交谈。'],
        correctChoiceIndex: 2,
        evidenceParagraphIndex: 3,
        explanation: '第 4 段建议讨论观点和理由，同时避免攻击个人。',
      ),
    ],
  ),
  LearningArticle(
    id: 'learning-from-mistakes',
    title: 'Learning From Mistakes',
    level: '高中与四级',
    description: '用复盘流程把错误变成可行动的学习线索。',
    paragraphs: [
      LearningArticleParagraph(
        text: 'Many learners treat a mistake as proof that they are not good at a subject.',
        translation: '许多学习者把一次错误当成自己不擅长某门学科的证据。',
      ),
      LearningArticleParagraph(
        text: 'A mistake is more useful when we ask what information it gives us.',
        translation: '如果我们追问错误提供了什么信息，它就会更有用。',
      ),
      LearningArticleParagraph(
        text: 'Compare your answer with the explanation and find the exact step where your reasoning changed direction.',
        translation: '把自己的答案和解释进行比较，找出推理方向发生变化的具体步骤。',
      ),
      LearningArticleParagraph(
        text: 'Write one short note about the pattern, then try a new question that uses the same idea.',
        translation: '把这个规律简短记下来，再做一道使用相同思路的新题。',
      ),
      LearningArticleParagraph(
        text: 'Progress does not mean never being wrong; it means using feedback to make the next attempt better.',
        translation: '进步并不意味着从不犯错，而是利用反馈让下一次尝试做得更好。',
      ),
    ],
    vocabulary: [
      'mistake',
      'proof',
      'useful',
      'information',
      'compare',
      'reasoning',
      'pattern',
      'feedback',
      'attempt',
    ],
    questions: [
      LearningArticleQuestion(
        id: 'mistake-as-information',
        prompt: '短文建议怎样看待错误？',
        choices: ['把它当作停止学习的理由。', '把它当成寻找信息的机会。', '只记住正确答案，不看过程。', '立即更换学习主题。'],
        correctChoiceIndex: 1,
        evidenceParagraphIndex: 1,
        explanation: '第 2 段指出，追问错误提供的信息能让错误变得有用。',
      ),
      LearningArticleQuestion(
        id: 'mistake-next-attempt',
        prompt: '复盘错误后，短文建议接下来做什么？',
        choices: ['尝试一道运用相同思路的新题。', '只背下原题的选项。', '等到完全不紧张再学习。', '删除记录并忘掉错误。'],
        correctChoiceIndex: 0,
        evidenceParagraphIndex: 3,
        explanation: '第 4 段建议记录规律后，再用新题检验是否学会。',
      ),
    ],
  ),
  LearningArticle(
    id: 'small-data-better-decisions',
    title: 'Small Data, Better Decisions',
    level: '四级与六级',
    description: '学习区分观察、解释和结论，避免让数据替我们过度推断。',
    paragraphs: [
      LearningArticleParagraph(
        text: 'A team wants to know whether a new study plan helps learners remember more words.',
        translation: '一个团队想知道新的学习计划是否能帮助学习者记住更多单词。',
      ),
      LearningArticleParagraph(
        text: 'It records how many words a small group remembers before and after one week of practice.',
        translation: '团队记录一小组学习者在一周练习前后记住的单词数量。',
      ),
      LearningArticleParagraph(
        text: 'The result is an observation, but it does not yet explain why the scores changed.',
        translation: '这个结果是一项观察，但它还不能解释分数为什么发生变化。',
      ),
      LearningArticleParagraph(
        text: 'Perhaps the plan helped, or perhaps learners also slept more or studied with a friend.',
        translation: '也许计划确实有帮助，也可能学习者同时睡得更多，或和朋友一起学习。',
      ),
      LearningArticleParagraph(
        text: 'Careful decisions keep these possibilities separate and ask for more evidence before making a broad claim.',
        translation: '谨慎的判断会把这些可能性区分开，并在做出广泛结论前要求更多证据。',
      ),
    ],
    vocabulary: [
      'team',
      'record',
      'group',
      'result',
      'observation',
      'explain',
      'possibility',
      'evidence',
      'claim',
    ],
    questions: [
      LearningArticleQuestion(
        id: 'data-observation',
        prompt: '一周前后记住单词数量的变化，首先属于什么？',
        choices: ['已经证明的原因。', '一项观察结果。', '对所有学习者的结论。', '对睡眠影响的测量。'],
        correctChoiceIndex: 1,
        evidenceParagraphIndex: 2,
        explanation: '第 3 段明确说，这个结果是一项观察，还不能解释原因。',
      ),
      LearningArticleQuestion(
        id: 'data-caution',
        prompt: '短文为什么提醒团队先不要做广泛结论？',
        choices: ['样本中可能同时存在其他影响因素。', '团队忘记记录学习计划。', '词汇数量不能被记录。', '所有结果都会自动说明原因。'],
        correctChoiceIndex: 0,
        evidenceParagraphIndex: 3,
        explanation: '第 4 段列出睡眠和同伴学习等其他可能因素。',
      ),
    ],
  ),
  LearningArticle(
    id: 'cooler-streets',
    title: 'How Streets Stay Cool',
    level: '六级与学术阅读',
    description: '从树荫、材料和出行方式理解城市热量与公共空间。',
    paragraphs: [
      LearningArticleParagraph(
        text: 'On a hot afternoon, a shaded street can feel cooler than a wide road covered in dark pavement.',
        translation: '在炎热的午后，有树荫的街道可能比铺着深色路面的宽阔道路更凉爽。',
      ),
      LearningArticleParagraph(
        text: 'Trees block some direct sunlight, while leaves release water that cools nearby air.',
        translation: '树木会遮挡一部分直射阳光，叶片释放的水分也会冷却附近空气。',
      ),
      LearningArticleParagraph(
        text: 'Dark surfaces absorb heat during the day and slowly return it after sunset.',
        translation: '深色表面会在白天吸收热量，并在日落后缓慢释放热量。',
      ),
      LearningArticleParagraph(
        text: 'Cities can combine trees, lighter materials, and shaded places where people can rest.',
        translation: '城市可以结合种树、使用较浅色的材料，并设置供人休息的遮阴空间。',
      ),
      LearningArticleParagraph(
        text: 'No single change solves every heat problem, so local measurements help planners choose what works on each street.',
        translation: '没有一种改变能解决所有高温问题，因此本地测量能帮助规划者为每条街道选择有效做法。',
      ),
    ],
    vocabulary: [
      'shade',
      'pavement',
      'direct',
      'release',
      'absorb',
      'surface',
      'combine',
      'measurement',
      'planner',
    ],
    questions: [
      LearningArticleQuestion(
        id: 'street-trees',
        prompt: '树木通过哪两种方式帮助周边降温？',
        choices: ['遮挡阳光并释放水分。', '吸收所有空气并制造阴影。', '反射夜间灯光并加热路面。', '减少道路长度并改变风向。'],
        correctChoiceIndex: 0,
        evidenceParagraphIndex: 1,
        explanation: '第 2 段提到遮挡直射阳光和释放水分两种作用。',
      ),
      LearningArticleQuestion(
        id: 'street-local-measurements',
        prompt: '规划者为什么需要本地测量？',
        choices: ['每条街都面临完全相同的条件。', '它能帮助判断哪种办法适合具体街道。', '它可以代替树木和遮阴设施。', '它能证明单一方案解决所有问题。'],
        correctChoiceIndex: 1,
        evidenceParagraphIndex: 4,
        explanation: '第 5 段建议用本地数据帮助选择适合每条街道的做法。',
      ),
    ],
  ),
  LearningArticle(
    id: 'using-ai-with-judgment',
    title: 'Using AI With Judgment',
    level: '六级与考研',
    description: '练习核对机器生成内容的来源、范围与不确定性。',
    paragraphs: [
      LearningArticleParagraph(
        text: 'An AI tool can summarize a long report quickly, but a fluent answer is not automatically a reliable one.',
        translation: 'AI 工具可以快速概括长篇报告，但流畅的回答并不自动等于可靠。',
      ),
      LearningArticleParagraph(
        text: 'A reader should compare the summary with the original and check whether important limits were kept.',
        translation: '读者应把摘要与原文比较，并检查重要限制条件是否得到保留。',
      ),
      LearningArticleParagraph(
        text: 'If a claim affects a decision, find the source passage and verify the numbers or definitions it uses.',
        translation: '如果某个说法会影响判断，就应找到来源段落，核对其中使用的数字或定义。',
      ),
      LearningArticleParagraph(
        text: 'When evidence is missing, mark the gap instead of filling it with a confident guess.',
        translation: '缺少证据时，应标出这个缺口，而不是用自信的猜测把它填上。',
      ),
      LearningArticleParagraph(
        text: 'Used this way, AI can save time while people remain responsible for checking meaning and consequences.',
        translation: '以这种方式使用时，AI 可以节省时间，而人仍需负责核对含义和后果。',
      ),
    ],
    vocabulary: [
      'summarize',
      'fluent',
      'reliable',
      'compare',
      'limit',
      'source',
      'verify',
      'evidence',
      'consequence',
    ],
    questions: [
      LearningArticleQuestion(
        id: 'ai-summary-check',
        prompt: '使用 AI 摘要后，读者首先应做什么？',
        choices: ['把流畅程度当作准确性证明。', '与原文比较并核对限制条件。', '删除原文，只保存摘要。', '忽略影响结论的数字。'],
        correctChoiceIndex: 1,
        evidenceParagraphIndex: 1,
        explanation: '第 2 段要求将摘要与原文比较，并检查限制是否保留。',
      ),
      LearningArticleQuestion(
        id: 'ai-evidence-gap',
        prompt: '当证据缺失时，短文建议怎样处理？',
        choices: ['标出缺口，不用猜测补齐。', '让工具生成更多肯定语句。', '把不确定内容写成事实。', '只保留最方便的数字。'],
        correctChoiceIndex: 0,
        evidenceParagraphIndex: 3,
        explanation: '第 4 段建议明确标记证据缺口，不用自信猜测填补。',
      ),
    ],
  ),
];
