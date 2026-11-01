export interface TranslationLine { id: string; text: string }

const translationTerms = /翻译|译文|字幕|原文|上下文|translat|subtitles?|context|翻訳|訳す|訳して|文脈/is
const commentaryRules: Array<{ output: RegExp; source: RegExp[] }> = [
  { output: /(?:用户|使用者|user).{0,18}(?:提供|补充|给出|provided|supplied).{0,24}(?:信息|资讯|内容|上下文|information|context|details)/is,
    source: [/用户|使用者|ユーザー|利用者|\buser\b/i, /信息|资讯|内容|上下文|information|context|details|情報|補足/i] },
  { output: /(?:我|我们).{0,8}(?:将|会|可以).{0,8}(?:根据|结合|参考|利用|使用).{0,10}(?:这些|上述|以上|额外|提供的).{0,6}(?:信息|资料|内容)|\bI (?:will|can).{0,12}(?:use|consider|take into account).{0,20}(?:information|context)\b/is,
    source: [/information|details|context|data|资料|信息|内容|情報|資料/i] },
  { output: /(?:用户|user).{0,18}(?:想要|要求|希望|需要|requests?|wants?).{0,24}(?:翻译|translat)/is,
    source: [/用户|ユーザー|利用者|\buser\b/i, translationTerms] },
  { output: /(?:我|我们|助手).{0,8}(?:将|会|需要|可以|来|先|现在).{0,32}(?:翻译|译成|译为|译文|逐句|逐条|字幕|原文|上下文)|\bI\s+(?:will|need to|should)\s+(?:translate|provide a translation|analy[sz]e)\b/is,
    source: [translationTerms] },
  { output: /(?:^|[\n。！？.!?])\s*(?:好的[，,。！!\s]*)?(?:(?:以下|下面|这里是|这是).{0,12}(?:译文|中文翻译|翻译结果|字幕翻译)|翻译如下|(?:译文|翻译(?:结果)?|中文翻译)\s*[:：])|(?:^|\n)\s*(?:here (?:is|are)|the following is).{0,15}(?:translation|translated text)/is,
    source: [translationTerms] },
  { output: /(?:根据|结合|从).{0,12}(?:上下文|用户.{0,8}信息).{0,20}(?:我|我们|可以看出|可知|这句话)|(?:这段|该段|这句|该句).{0,8}(?:文本|字幕|原文).{0,20}(?:意思是|可以译为|应译为)/is,
    source: [/上下文|原文|字幕|文本|句子|context|text|sentence|subtitle|文脈|テキスト|翻訳/i] },
  { output: /作为(?:一个|一名)?\s*(?:AI|人工智能|语言模型|翻译助手)|\bas an? (?:AI|language model)\b/is,
    source: [/\bAI\b|artificial intelligence|language model|人工智能|语言模型|人工知能|言語モデル|翻译助手/i] },
  { output: /(?:请|需要).{0,10}(?:提供|补充|给出).{0,20}(?:原文|文本|待翻译|上下文)|(?:无法|不能).{0,12}(?:翻译|提供.{0,8}译文)|(?:缺少|缺乏).{0,12}(?:上下文|原文|文本)/is,
    source: [/翻译|译文|字幕|原文|上下文|translat|subtitles?|context|翻訳|訳す|訳して|文脈|text|文本|テキスト/i] },
  { output: /<\s*\/?\s*(?:think|analysis|reasoning)\b|(?:^|\n)\s*(?:analysis|reasoning|思考过程|推理过程)\s*[:：]/is,
    source: [/<\s*\/?\s*(?:think|analysis|reasoning)\b|(?:analysis|reasoning|思考过程|推理过程)\s*[:：]/i] }
]

/** Commentary is not a subtitle; preserve literal dialogue on these topics. */
export function isUsableTranslation(translation: string, source: string): boolean {
  return translation.trim().length > 0 && !commentaryRules.some(rule =>
    rule.output.test(translation) && !rule.source.every(pattern => pattern.test(source)))
}

export function translationSchema(lines: TranslationLine[]): object {
  return { type: 'object', properties: { translations: {
    type: 'object', properties: Object.fromEntries(lines.map(line => [line.id, { type: 'string', minLength: 1 }])),
    required: lines.map(line => line.id), additionalProperties: false
  } }, required: ['translations'], additionalProperties: false }
}

export function parseTranslations(content: string, lines: TranslationLine[]): Record<string, string> {
  let translations: Record<string, unknown>
  try { translations = JSON.parse(content)?.translations } catch { return {} }
  if (!translations || typeof translations !== 'object' || Array.isArray(translations)) return {}
  return Object.fromEntries(lines.flatMap(line => {
    const value = translations[line.id]
    return typeof value === 'string' && isUsableTranslation(value, line.text) ? [[line.id, value.trim()]] : []
  }))
}
