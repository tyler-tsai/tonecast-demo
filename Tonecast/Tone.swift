import Foundation

enum Tone: Int, CaseIterable {
    // NOTE: rawValues are persisted in SharedDefaults (default tone, last
    // result tone, refine source tone). Never reorder existing cases — add
    // new tones at the END to keep stored values stable. The `warm` case
    // was renamed from `intimate` (purely cosmetic — rawValue 0 unchanged).
    case warm, formal, casual, tactful, plain

    var displayName: String {
        switch self {
        case .warm:     return "Warm"
        case .formal:   return "Formal"
        case .casual:   return "Casual"
        case .tactful:  return "Tactful"
        case .plain:    return "Plain"
        }
    }

    /// Factory-default tone style guide. User can override via SettingsView;
    /// the override is stored in SharedDefaults and read by `styleGuide`.
    var defaultStyleGuide: String {
        switch self {
        case .warm:
            return """
            Tone: warm, soft, emotionally present — for partners, family, close friends, or anyone you're checking in on with care. Less "messaging a romantic partner specifically", more "anyone you wouldn't keep at arm's length". Conveys closeness without forcing intimacy.
            • Punctuation MINIMAL. Heavy 「，」「。」 in Chinese reads cold and formal; let the words breathe instead. Use a single space or a line break to soften pauses. End-of-sentence periods are usually dropped.
            • Lowercase in English where natural. Contractions ("i'm", "it's", "you're") over full forms.
            • Trailing softeners like "啦" "嘛" "喔" "～" "好嗎" "好不好" are welcome when they fit naturally — but never forced. Romantic-coded particles ("～" at end of every line) only when the input clearly invites that register.
            • Keep the sender's voice; do not sound robotic or therapist-like. No emoji unless the original had them.
            """
        case .formal:
            return """
            Tone: polite, professional, clear — like an email to your boss, a client, or a formal counterparty.
            • Full sentences, proper punctuation.
            • No slang, no emoji.
            • Polite opening/closing only when the original implies one (don't invent "Dear..." if not there).
            • LANGUAGE: if an OUTPUT LANGUAGE TARGET was set at the top of the system prompt, follow it. Otherwise match the input's language profile exactly. Formal does NOT mean bilingual — never produce side-by-side or parenthetical-gloss versions regardless of which mode is active.
            """
        case .casual:
            return """
            Tone: natural, relaxed, like texting a friend or colleague.
            • Punctuation MINIMAL — friends don't text with formal commas and periods. Skip end-of-sentence periods. One comma at most.
            • Use lowercase where natural in English.
            • Contractions over formal forms ("it's" not "it is", "我覺得" not "我認為").
            • No emoji unless the original had them.
            """
        case .plain:
            return """
            Tone: NONE — pass-through mode. When this tone is selected, the dictation is delivered AS-IS from Whisper, with no GPT rewriting whatsoever. Use this for niche / specialized content where any "smart correction" hurts more than it helps: gaming chat, technical jargon, code-speak, proper nouns, in-jokes, slang the model wouldn't recognize. Trades polish for fidelity — what you said is what gets inserted.
            """
        case .tactful:
            return """
            Tone: high-EQ — warm, considerate, and emotionally aware. Like a thoughtful friend or a diplomatic colleague who knows how to say tricky things in a way that lands well. This tone is for the moments where HOW you say it matters as much as WHAT you say: pushing back, declining, raising a concern, asking for something hard, navigating tension.
            • CRITICAL: Tactful REWRITES the speaker's message — it does NOT reply to it. If the input is a question or a complaint, the output is the SAME question/complaint phrased more diplomatically. NEVER output an apology, explanation, or answer on behalf of the recipient. ("為什麼這個 bug 一直沒修" → softened as a question like "想 sync 一下進度 是不是有 blocker"; it does NOT become "我知道這個 bug 拖了一陣子...我來看一下".)
            • Acknowledge the situation, feeling, or constraint before the ask / pushback when it fits: "我理解這個有點趕"、"I get that this is frustrating"、"我知道時間很緊"。 Keep it brief — one short clause, not a paragraph.
            • Soften disagreement / refusal with a SHORT reason or alternative, never a flat "no". E.g. "我這邊不太方便，但 X 應該可以幫上忙" instead of "不行".
            • Direct enough to be clear — never vague, never passive-aggressive, never wishy-washy. Tactful is NOT the same as evasive.
            • Stay grounded — do NOT sound like a corporate apology bot, HR script, or therapy textbook. No "I hear you" / "感謝您的回饋" robot phrases.
            • Light punctuation in Chinese (similar to Warm's breathing-space style). Standard punctuation in English.
            • LANGUAGE: if an OUTPUT LANGUAGE TARGET was set at the top of the system prompt, follow it. Otherwise match the input's language profile (pure-Chinese → pure-Chinese, mixed → mixed, etc).
            """
        }
    }

    /// Resolved style guide — user override if set, otherwise factory default.
    var styleGuide: String {
        SharedDefaults.customStyleGuide(for: self) ?? defaultStyleGuide
    }

    /// Factory-default GPT temperature for the rewrite + refine pipelines.
    /// 0.4 is empirically a good middle ground: enough variation for natural
    /// tone shifting, restrained enough to not hallucinate beyond intent.
    static let defaultTemperature: Double = 0.4

    /// Resolved temperature — user override if set, otherwise factory default.
    /// Used by ToneRewriter.rewrite and ToneRewriter.refine to control how
    /// much the model is allowed to deviate from the input wording.
    var temperature: Double {
        SharedDefaults.customTemperature(for: self) ?? Self.defaultTemperature
    }

    /// How aggressively the rewriter is allowed to transform the input.
    /// Derived from the temperature slider so a single control surfaces
    /// both API-level sampling AND prompt-level rewrite intensity.
    ///
    /// `verbatim` injects a strict directive at the TOP of the system prompt
    /// telling the model to bypass almost all rewrite rules (no list
    /// conversion, no smart formatting, no tone-style transformations) and
    /// keep the speaker's words as close to verbatim as possible — only
    /// removing obvious vocal filler.
    enum FaithfulnessLevel: String {
        case verbatim       // T ≤ 0.15: only filler removed
        case conservative   // T 0.15 - 0.40: light tone-shifting
        case balanced       // T 0.40 - 0.70: default
        case expressive     // T > 0.70: encourage variation
    }

    var faithfulnessLevel: FaithfulnessLevel {
        // Plain tone is intrinsically verbatim — the temperature slider is
        // ignored for this tone (and the keyboard skips GPT entirely when
        // possible, see RecordingService.processAudio).
        if self == .plain { return .verbatim }
        let t = temperature
        if t <= 0.15 { return .verbatim }
        if t <= 0.40 { return .conservative }
        if t <= 0.70 { return .balanced }
        return .expressive
    }

    /// Short 繁中 description of what this tone is meant to feel like.
    /// Shown in the editor so a Chinese-reading user knows what the
    /// English style guide is trying to express.
    var chineseDescription: String {
        switch self {
        case .warm:
            return "溫暖、貼近，適合伴侶、家人、好朋友，或任何你想用比較近的距離講話的對象。中文盡量少標點留呼吸感；可以用「啦」「嘛」「好嗎」軟化語尾，但不勉強。比 Intimate 涵蓋更廣 — 不一定要是浪漫關係。"
        case .formal:
            return "禮貌、清楚、像寫 email 給主管或客戶。完整句、正常標點，沒有 slang 或 emoji。原文沒有的問候語不會自己加。"
        case .casual:
            return "自然、放鬆，像對朋友或同事傳訊息。標點極少，英文小寫，「我覺得」「等等」這種口語都會留下來。"
        case .tactful:
            return "高情商版本 — 體貼、有同理心的措辭，懂得在直接和柔軟之間拿捏。適合處理敏感對話、回絕、提出不同意見、跟人協調這類需要 EQ 的場景。會先承接對方的處境再切重點，而不是直接 push back。"
        case .plain:
            return "直通模式 — 完全不經過 GPT 改寫，Whisper 講什麼就插入什麼。適合遊戲術語、技術詞、專有名詞、行話、術語、模型不認識的 slang 或縮寫 — 任何「智能修正」反而會曲解原意的場景。例如「25 星一起打」「Monster Hunter 25 ★ co-op」「打 boss 拉仇恨」這種。沒有 latency cost（不打 API），最快最忠實，但也沒有任何潤色。"
        }
    }

    /// Three Chinese sample (input → output) pairs showing what the
    /// resolved style guide actually produces. Helps the user calibrate
    /// expectations before editing the prompt.
    var chineseSamples: [(input: String, output: String)] {
        switch self {
        case .warm:
            return [
                ("我今天有點累，等等回家可以陪我嗎", "今天有點累 等等回家陪陪我好嗎"),
                ("記得到家傳訊息給我我會擔心", "到家了傳一下訊息 不然我會擔心"),
                ("我蠻想你的", "好想你喔"),
            ]
        case .formal:
            return [
                ("can you send me the report by friday", "請您於本週五前將報告寄送給我。"),
                ("明天的會議改到下午", "明天的會議已調整至下午舉行。"),
                ("這份合約我看完了沒問題", "本份合約已審閱完畢，並無問題。"),
            ]
        case .casual:
            return [
                ("我等下會晚到大約十分鐘", "我會晚個十分鐘到"),
                ("can you send me the report by friday", "禮拜五前把報告寄給我吧"),
                ("這件事我覺得我們應該再討論一下", "這件事我覺得我們再聊一下"),
            ]
        case .tactful:
            return [
                ("我不想做這個案子", "這個案子我評估之後可能沒辦法接 想跟你聊聊是不是有其他方式能幫上"),
                ("這個方案不行", "這方案我有點擔心 主要是 X 那邊可能撐不住 想聽聽你的想法"),
                ("你忘了寄那個檔案", "上次說的那個檔案我這邊還沒收到 你方便再傳一次嗎"),
            ]
        case .plain:
            return [
                ("25 星可以一起打嗎", "25 星可以一起打嗎"),
                ("等等開團缺一個輔助", "等等開團缺一個輔助"),
                ("這個 PR 的 CI 紅了 幫看一下", "這個 PR 的 CI 紅了 幫看一下"),
            ]
        }
    }
}

/// Quick-action transformations applied to already-inserted text via the
/// keyboard's refine chips (no new recording). Lives here in Tone.swift so
/// both the main app (where the GPT call happens) and the keyboard
/// extension (which fires the request) can reference the same type.
enum RefineAction: String {
    case shorter
    case longer
    case polish
    case tone   // param: target Tone rawValue as a string
}

enum TranslateMode: Int, CaseIterable {
    case off, toEN, toZH

    var displayName: String {
        switch self {
        case .off:  return "No translate"
        case .toEN: return "→ EN"
        case .toZH: return "→ 中"
        }
    }

    var instruction: String? {
        switch self {
        case .off:  return nil
        case .toEN:
            return """
            Output language: ENGLISH ONLY. The output MUST be entirely in natural English regardless of what language the speaker used. Translate the speaker's intent + tone into English — including any Chinese, mixed Chinese+English, or other-language input. Do NOT keep any non-English text in the output: no parenthetical 中文 gloss, no side-by-side, no bilingual version. A pure-Chinese input still produces a pure-English output. The tone setting (Warm / Formal / Casual / Tactful) still applies — translate the tone's characteristic moves (Tactful's acknowledge-then-soften, Warm's lowercase + softeners, Formal's full sentences, etc), not just the literal words.
            """
        case .toZH:
            return """
            Output language: 繁體中文 ONLY (Traditional Chinese, Taiwanese style). The output MUST be entirely in 繁體中文 regardless of what language the speaker used. Translate the speaker's intent + tone into 繁體中文 — including any English or mixed-language input. NEVER output Simplified Chinese (简体字). NEVER keep any English in the output: no parenthetical English gloss, no side-by-side, no bilingual version. A pure-English input still produces a pure-繁中 output. The tone setting (Warm / Formal / Casual / Tactful) still applies — translate the tone's characteristic moves, not just the literal words.
            """
        }
    }
}
