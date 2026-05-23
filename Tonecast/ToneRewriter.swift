import Foundation

struct ToneRewriter {
    /// Where + how to make GPT calls. All three methods on this struct
    /// (rewrite / editSelectedText / refine) hit `/v1/chat/completions`,
    /// so they share a single endpoint + headers + signer config.
    /// `Authorization: Bearer` is gone — App Attest assertions (added
    /// by `requestSigner` at send time) are the only credential.
    struct Config {
        let endpoint: URL
        let extraHeaders: [String: String]
        let requestSigner: any RequestSigner

        init(endpoint: URL,
             extraHeaders: [String: String] = [:],
             requestSigner: any RequestSigner = NoopRequestSigner()) {
            self.endpoint = endpoint
            self.extraHeaders = extraHeaders
            self.requestSigner = requestSigner
        }
    }

    let config: Config

    init(config: Config) {
        self.config = config
    }

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in config.extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Sign + dispatch in one place — the App Attest assertion is bound
    /// to (method, path), which makeRequest() has already fixed, so we
    /// can sign before body bytes are written.
    private func send(_ request: inout URLRequest) async throws -> (Data, URLResponse) {
        try? await config.requestSigner.sign(&request)
        return try await NetworkSession.shared.data(for: request)
    }

    func rewrite(_ text: String, tone: Tone, translate: TranslateMode) async throws -> String {
        var request = makeRequest()

        let systemPrompt = Self.buildSystemPrompt(tone: tone, translate: translate)

        // Few-shot examples sent as prior user/assistant turns. They teach
        // the model the pattern "input dictation → rewritten output,
        // NEVER an answer to a question". Cheaper + more reliable than
        // verbose system rules.
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
        ]
        messages.append(contentsOf: Self.fewShotExamples(tone: tone, translate: translate))
        messages.append(["role": "user", "content": text])

        // gpt-4.1-mini: stronger instruction-following than gpt-4o-mini at
        // ~same price/latency — directly helps our many universal rules
        // (繁中 lock, never answer questions, list-format detection) hit
        // more consistently.
        // Temperature is per-tone — user can dial down for tighter fidelity
        // or up for more variation, via TonePromptEditorView.
        let body: [String: Any] = [
            "model": "gpt-4.1-mini",
            "messages": messages,
            "temperature": tone.temperature,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(&request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let raw = String(data: data, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "Tonecast.GPT", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "GPT API \((response as? HTTPURLResponse)?.statusCode ?? -1): \(raw)"])
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? text
    }

    // MARK: - Speak to Edit

    /// Apply a voice command (transcribed from a recording) to a piece of
    /// selected text. The user already had text in mind and is asking us
    /// to revise/edit/rephrase/shorten/translate THIS specific text.
    func editSelectedText(_ originalText: String, withCommand command: String) async throws -> String {
        var request = makeRequest()

        let systemPrompt = """
        You are a text-editing assistant. The user has SELECTED a piece of text and dictated a voice COMMAND describing how to edit it. Your only job is to apply the command and return the revised text.

        Rules (always apply):
        1. Output ONLY the revised text. No preamble. No explanation. No quotes.
        2. Apply EXACTLY what the command asks — nothing more, nothing less.
        3. Preserve the language(s) of the original UNLESS the command explicitly asks to translate.
        4. When the output contains Chinese, ALWAYS use 繁體中文 (Traditional Chinese). Never 简体字.
        5. Don't add new content/info that isn't implied by the original or the command.
        6. If the command is ambiguous, apply the most literal interpretation.

        Examples:
        SELECTED: "today's meeting at 3 pm"   COMMAND: "make it more polite"   → "Could we hold today's meeting at 3 PM?"
        SELECTED: "i think this plan has issues"   COMMAND: "shorter"   → "this plan has issues"
        SELECTED: "明天會議改下午"   COMMAND: "翻成英文"   → "tomorrow's meeting is moved to the afternoon"
        SELECTED: "the report by friday."   COMMAND: "拿掉句點"   → "the report by friday"
        """

        let userPrompt = "SELECTED: \(originalText)\n\nCOMMAND: \(command)"

        // gpt-4.1-nano: fastest + cheapest in the 4.1 family. Speak-to-Edit
        // is a tightly bounded task (selected text + one command → revised
        // text) — nano handles it well and cuts latency vs mini, which
        // matters because the user is staring at the keyboard waiting for
        // the replacement to appear.
        let body: [String: Any] = [
            "model": "gpt-4.1-nano",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "temperature": 0.3,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(&request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let raw = String(data: data, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "Tonecast.GPT.Edit", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "GPT edit API \((response as? HTTPURLResponse)?.statusCode ?? -1): \(raw)"])
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? originalText
    }

    // MARK: - Quick-action refine

    /// Transform an already-inserted piece of text without re-recording.
    /// Powers the keyboard's quick-action chips (Shorter / Longer / Polish /
    /// Switch tone). Cheaper + faster than a fresh recording because Whisper
    /// is bypassed entirely — input is text we already have.
    func refine(text: String,
                action: RefineAction,
                param: String?,
                currentTone: Tone,
                translate: TranslateMode) async throws -> String {
        var request = makeRequest()

        let actionInstruction: String
        switch action {
        case .shorter:
            // Per-tap target is aggressive: cut ~35–45% on each pass. The
            // model can be conservative here ("but I need to preserve
            // meaning!"), so we explicitly push back against that and
            // tell it the user will tap Undo if it went too far. Also:
            // iterative — tap again to compress further.
            actionInstruction = """
            COMPRESS the text aggressively. Cut 35–45% of characters per pass — target ~55–65% of the original length. Strip filler ("嗯"/"那個"/"like"/"you know"), hedging ("kind of"/"有點"/"我覺得"/"基本上"), throat-clearing openers ("想跟你說"/"i just wanted to mention"), redundant clauses, and any phrasing that restates the same idea. Restructure if a single tighter sentence can replace two — do NOT just delete words mechanically. Preserve every concrete fact (names, numbers, dates, actions). Do NOT preserve filler "for safety" — the user has Undo and will tap again if they want more. If the input is already extremely compact (< 10 characters), make at most a tiny cleanup. Preserve tone and language.
            """
        case .longer:
            // Iterative model: ONE tap = ONE layer of softening / context.
            // 150% was too much per tap — a 30-char sentence became 60.
            actionInstruction = """
            Add ONE layer of natural softening — a connective phrase, a polite opener, or a brief clarifier. Target ~110–125% of the original length. NEVER invent new factual content; only elaborate on what's already implied. Avoid adding fluff like "I just wanted to say" or "我想跟你說一下" unless it genuinely fits the speaker's intent. Preserve tone and language.
            """
        case .polish:
            actionInstruction = """
            Polish the text — improve word choice, flow, rhythm, and clarity while keeping the same meaning, tone, and length (within ±10%). Fix awkward phrasing. Do NOT add or remove content.
            """
        case .tone:
            let targetTone = Tone(rawValue: Int(param ?? "") ?? 2) ?? .casual
            actionInstruction = """
            Rewrite the text in \(targetTone.displayName) tone. Apply this style guide to the rewrite:

            \(targetTone.styleGuide)

            Preserve the language(s) of the original. Do NOT add new information.
            """
        }

        // Tone context: for Shorter / Longer / Polish, the model MUST keep
        // the text in its current tone — which means knowing what that tone
        // requires. For Tone-switch the target tone is supplied inline in
        // actionInstruction, so injecting the source tone would conflict.
        let toneContext: String
        switch action {
        case .shorter, .longer, .polish:
            toneContext = """

            ── CURRENT TONE: \(currentTone.displayName) ──
            The text is already in \(currentTone.displayName) tone. The transformation MUST preserve this tone's voice, patterns, and characteristic moves. Apply these tone rules as constraints on the output:

            \(currentTone.styleGuide)

            CRITICAL examples of preserving tone under length transforms:
            • If Tactful: do NOT cut the "acknowledge context before the ask" preamble when shortening — that empathy beat is the WHOLE POINT of Tactful.
            • If Warm: do NOT add formal punctuation back in when shortening.
            • If Formal: do NOT introduce slang or contractions when shortening.
            • If Casual: do NOT add formal openers when lengthening.
            """
        case .tone:
            toneContext = ""
        }

        let systemPrompt = """
        You are a text-refinement assistant. The user has a piece of text and wants you to apply a specific transformation to it.

        Rules (always apply):
        1. Output ONLY the transformed text. No preamble, no explanation, no surrounding quotes.
        2. Apply EXACTLY what the action below says — nothing more.
        3. Preserve the language(s) of the original. If it mixes 中文 and English, the output must also mix them. Translation does NOT happen here.
        4. When the output contains Chinese, ALWAYS use 繁體中文. Never 简体字.
        5. Do NOT invent new factual content.
        \(toneContext)
        Action: \(actionInstruction)
        """

        // For shorter/longer/polish: use the source tone's temperature so
        // refinements respect the user's per-tone creativity preference.
        // For tone-switch: use the TARGET tone's temperature instead.
        let effectiveTemp: Double = {
            switch action {
            case .tone:
                let target = Tone(rawValue: Int(param ?? "") ?? 2) ?? .casual
                return target.temperature
            case .shorter, .longer, .polish:
                return currentTone.temperature
            }
        }()
        let body: [String: Any] = [
            "model": "gpt-4.1-mini",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            "temperature": effectiveTemp,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(&request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let raw = String(data: data, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "Tonecast.GPT.Refine", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "GPT refine API \((response as? HTTPURLResponse)?.statusCode ?? -1): \(raw)"])
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? text
    }

    // MARK: - Prompt construction

    /// Layered prompt:
    ///   1. Universal rules (locked — fixes the "GPT answers questions"
    ///      bug, enforces 繁體中文 for Chinese output, etc.)
    ///   2. Tone style guide (user can override per tone in SettingsView)
    ///   3. Translation instruction (when translate ≠ off)
    private static func buildSystemPrompt(tone: Tone, translate: TranslateMode) -> String {
        // VERBATIM MODE — when the user's creativity slider for this tone is
        // near 0, they've signaled "minimum changes". Inject a directive at
        // the TOP of the prompt that bypasses most rewrite rules, leaving
        // only filler removal. Stronger than API temperature alone, which
        // only controls token sampling (not rewrite intensity).
        let verbatimHeader: String
        if tone.faithfulnessLevel == .verbatim {
            verbatimHeader = """
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            ⚙ VERBATIM MODE (user set Creativity to minimum for this tone)
            The speaker wants the output to be ALMOST IDENTICAL to what they said. Treat this turn as a clean-transcript pass, NOT a tone rewrite.

            DO:
              • Remove ONLY obvious vocal filler (one or two words max each): "嗯", "啊", "那個", "um", "uh", "you know", "like" (only when filler), "我覺得" (only when filler). Keep all substantive words.
              • Apply rule 1 (questions stay as questions).
              • Apply rule 7 (繁體中文 for Chinese output).
              • Apply OUTPUT LANGUAGE TARGET if one is set below.
              • Apply rule 11 (output only the text — no preamble, no explanation, no quotes).

            DO NOT:
              • Apply rule 8 (no list conversion — keep prose as prose).
              • Apply rule 9 (no email/URL collapsing — keep "user at example dot com" as spoken).
              • Apply rule 10 (no number/currency/time normalization — keep "五百塊" as spoken, not "$500").
              • Apply the TONE STYLE GUIDE below in any way — no punctuation changes, no lowercase, no contractions, no trailing softeners, no "acknowledge the situation" prefix.
              • Restructure sentences for flow.
              • Substitute synonyms or "polish" phrasing.

            The output should read like a typed transcript of what the speaker said, with filler removed. NOTHING ELSE.
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            """
        } else {
            verbatimHeader = ""
        }

        // OUTPUT LANGUAGE TARGET goes at the TOP of the prompt when translate
        // is enabled (right after verbatim header if both apply). Putting it
        // first (before any rules about "preserve language") gives the model
        // the strongest possible anchor — when this is set, rule 6 below
        // explicitly defers to it.
        let topOverride: String
        if let translateInstruction = translate.instruction {
            topOverride = """
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            ⚑ OUTPUT LANGUAGE TARGET (MUST follow, takes precedence over all rules below):
            \(translateInstruction)
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            """
        } else {
            topOverride = ""
        }

        // Rule 6 wording is CONDITIONAL on whether an OUTPUT LANGUAGE TARGET
        // is in play. With a target set, rule 6 explicitly defers. Without,
        // rule 6 enforces strict language preservation as before.
        let rule6: String
        if translate.instruction != nil {
            rule6 = "6. The OUTPUT LANGUAGE TARGET at the top of this prompt determines the output language. Rule 6 (preserve speaker's language) is SUSPENDED for this turn — follow the target instead. Still: never output a bilingual / side-by-side / parenthetical-gloss version; produce a single clean output in the target language only."
        } else {
            rule6 = "6. PRESERVE THE LANGUAGE(S) the speaker used. If the input is pure Chinese, the output is pure Chinese — NOT Chinese followed by an English version, NOT Chinese with a parenthetical English gloss like \"中文 (English)\". If the input is pure English, the output is pure English with no Chinese alongside. If the speaker mixed Chinese and English (\"明天那個 meeting 改到下午\"), the rewritten output MUST mix the same two languages — do NOT translate one into the other. The output language profile must MATCH the input language profile exactly. CRITICAL: never output a bilingual / side-by-side version, even under Formal tone — \"professional\" does NOT mean \"give both languages\"."
        }

        var prompt = verbatimHeader + topOverride + """
        You are a voice-keyboard tone-rewriting assistant. The user dictated a message via speech-to-text; your only job is to rewrite that dictation in the specified tone — NEVER respond to it.

        ── CRITICAL RULES (always apply, do not break these) ──
        1. NEVER answer questions. If the dictation is "where did you go today", output the question rewritten in tone — DO NOT provide an answer.
        2. NEVER add new information or content the speaker didn't say.
        3. NEVER add greeting/closing phrases the speaker didn't dictate.
        4. Preserve the speaker's original intent and meaning exactly.
        5. Remove obvious filler words ("um", "uh", "you know", "嗯", "那個") and self-corrections — keep only the speaker's final intended phrasing (e.g. "meet at 3, actually make it 4" → "meet at 4").
        \(rule6)
        7. When the output contains Chinese, ALWAYS use 繁體中文 (Traditional Chinese, Taiwanese style). NEVER 简体字 / Simplified Chinese.
        8. IF THE CONTENT IS A LIST (multiple discrete items the speaker is enumerating — e.g. shopping items, meeting topics, action items, steps), output it as a NUMBERED list with "1. ", "2. ", "3. " markers, one item per line. This applies BOTH when the speaker spoke ordinals ("第一/first/1.") AND when they just listed items separated by commas / "還有" / "and" / pauses without any ordinal marker. Examples that should become numbered lists:
           • "要買蘋果、蠟燭跟皮鞭" → enumeration → numbered
           • "第一點 ABC 第二點 BCP 第三點 GGG" → explicit ordinals → numbered
           • "會議重點包括時程更新、預算審查、風險評估" → enumeration → numbered
           CRITICALLY: when the speaker used ordinal phrases ("第一點" / "first" / "第一個"), STRIP that phrase from each item — the "1." marker already conveys order. Keep an optional short intro sentence on its own line if the speaker provided one (e.g. "要買："), otherwise just output the numbered items. Single-item content is NOT a list — write it as prose.
        9. SMART FORMATTING — when the speaker dictates an email / URL / handle, output it in canonical form:
           • "X at Y dot com" / "X at Y dot org" → "X@Y.com" / "X@Y.org" (collapse "at" → "@", "dot" → ".", remove spaces; keep the local-part exactly as said).
             - "user at example dot com" → "user@example.com"
             - "support at gmail dot com" → "support@gmail.com"
           • "X dot com slash Y" / spelled-out URLs → "X.com/Y" (collapse "dot"/"slash"/"dash"/"underscore" to their symbols).
             - "github dot com slash your dash org" → "github.com/your-org"
           • "@ X" / "at X" (Twitter/IG-style handle when context implies a handle) → "@X".
           Do NOT do this when the speaker is clearly NOT dictating an address (e.g. "at three o'clock" stays as "at 3 o'clock" — see rule 10).
        10. NUMBER / CURRENCY / TIME / PERCENT — normalize spoken numerics to written form:
           • Currency: "five hundred dollars" → "$500"; "三百塊" → "300 元" (keep the currency word the speaker used, just digitize the amount).
           • Percent: "fifty percent" / "五十趴" / "百分之五十" → "50%".
           • Time of day: "three pm" / "下午三點" → "3pm" / "下午 3 點"; "ten thirty" → "10:30".
           • Standalone numbers ≥ 10 dictated as words: write as digits ("twenty three" → "23", "一千兩百" → "1,200"). Numbers under 10 in casual prose can stay as words if natural ("我有兩個" stays as "兩個", not "2 個").
           • Decimals: "three point one four" → "3.14".
           • Phone numbers: "九 一 八 五 五 五 零 一 零 零" → "918-555-0100" (group as 3-3-4 for US-style 10-digit numbers, otherwise leave grouped as spoken).
        11. Output ONLY the rewritten text. No preamble. No explanation. No surrounding quotes. No "Here is the rewritten version:" framing.

        ── TONE STYLE ──
        \(tone.styleGuide)
        """

        // OUTPUT LANGUAGE TARGET is already at the TOP of the prompt (see
        // topOverride above), where it can't be missed. No need to repeat
        // it here at the bottom — that would weaken its primacy.

        return prompt
    }

    /// Few-shot examples per (tone, translate) combination — anchors the
    /// "rewrite, don't answer" behaviour and shows the desired punctuation
    /// density for each tone.
    private static func fewShotExamples(tone: Tone, translate: TranslateMode) -> [[String: Any]] {
        let pairs: [(String, String)]

        switch (tone, translate) {
        case (.casual, .off):
            pairs = [
                // Question stays a question (NOT answered)
                ("嗯，那個，明天的會議是不是可以改到下午", "明天會議可以改到下午嗎"),
                // English casual — minimal punctuation, lowercase
                ("uh you know let me know when you arrive at the office, ok", "let me know when you get to the office"),
                // Chinese casual — minimal commas/periods
                ("我覺得這個方案有一點點小問題", "這方案有點問題"),
                // Mixed language — preserved (NOT translated)
                ("嗯那個明天的 sync up meeting 可以改到下午嗎", "明天 sync up 可以改到下午嗎"),
                // Self-correction — keep final intended phrasing
                ("會議在三點 ahh 不對是四點", "會議改四點"),
                // NUMBERED list — ordinal markers like 第一點 / 第二點 trigger
                // "1. " "2. " format AND get stripped from the items themselves
                ("第一點 ABC，第二點 BCP，第三點 GGG",
                 "1. ABC\n2. BCP\n3. GGG"),
                // NUMBERED list — no ordinals, plain enumeration still gets numbered
                ("等等要買，雞蛋牛奶還有麵包",
                 "等等要買：\n1. 雞蛋\n2. 牛奶\n3. 麵包"),
                // NUMBERED list — shopping-list style, intro + comma-separated items
                ("我要出去超市買一些東西，要買蘋果蠟燭跟皮鞭",
                 "要去超市買：\n1. 蘋果\n2. 蠟燭\n3. 皮鞭"),
                // EMAIL formatting — "at" → @, "dot" → .
                ("可以寄給 user at example dot com 嗎",
                 "可以寄給 user@example.com 嗎"),
                // URL formatting — "dot" → ., "slash" → /, "dash" → -
                ("repo 在 github dot com slash your dash org slash tonecast",
                 "repo 在 github.com/your-org/tonecast"),
                // NUMBER + CURRENCY normalization
                ("這個方案大概要花五百塊", "這方案大概要五百塊"),  // 中文「五百塊」自然保留
                ("the budget is five thousand dollars", "the budget is $5,000"),
                // PERCENT
                ("conversion rate 大概是百分之十二", "conversion 大概 12%"),
                // TIME of day
                ("我們約下午三點半在咖啡廳", "我們約下午 3:30 在咖啡廳"),
                ("see you at three pm", "see you at 3pm"),
            ]
        case (.formal, .off):
            pairs = [
                ("嗯明天會議可以改到下午嗎", "請問明天的會議是否可以改至下午舉行？"),
                ("uh can you send me the report by friday", "Could you please send me the report by Friday?"),
                // Mixed language preserved
                ("可以幫我 review 一下這個 PR 嗎", "可以幫我 review 一下這個 PR 嗎？"),
                // Pure Chinese Formal — output MUST stay pure Chinese, no English appended
                ("這份合約我已經看過了沒問題可以簽",
                 "本份合約已審閱完畢，並無問題，可以簽署。"),
                // Longer pure-Chinese Formal — anchors against the "add English version" temptation
                ("跟你說一下這禮拜進度，主要是把 onboarding 流程重做了，然後也跟客戶確認了下個月的時程",
                 "向您報告本週進度：主要重新調整了 onboarding 流程，並與客戶確認了下個月的時程安排。"),
                // NUMBERED list — formal, full-sentence items, ordinal phrases stripped
                ("本週的目標，首先是完成 sprint 規劃，再來是 release notes 寫好，最後 demo 給 stakeholder",
                 "本週目標如下：\n1. 完成 sprint 規劃\n2. 撰寫 release notes\n3. 向 stakeholder 進行 demo"),
                // NUMBERED list — no ordinals, but enumeration still numbered for clarity
                ("會議重點包括時程更新, 預算審查, 風險評估",
                 "會議重點如下：\n1. 時程更新\n2. 預算審查\n3. 風險評估"),
            ]
        case (.warm, .off):
            pairs = [
                // Soft, breathing space — no commas, no period
                ("我今天有點累，等等回家可以陪我嗎", "今天有點累 等等回家陪陪我好嗎"),
                ("uh just let me know when you're home safe", "just text me when you're home safe"),
                // Trailing softener, no period
                ("我蠻想你的", "好想你喔"),
                // Mixed language preserved, soft trailing tone
                ("等等下班回家路上 buy me a coffee 好嗎", "等等下班 buy me a coffee 好不好"),
                // NUMBERED list — even in warm tone, lists stay numbered for readability
                ("等等要買的，雞蛋牛奶，還有麵包",
                 "等等要買：\n1. 雞蛋\n2. 牛奶\n3. 麵包"),
            ]
        case (.casual, .toEN):
            pairs = [
                ("明天的會議改到下午", "tomorrow's meeting got moved to the afternoon"),
            ]
        case (.formal, .toEN):
            pairs = [
                ("明天的會議改到下午", "Tomorrow's meeting has been moved to the afternoon."),
            ]
        case (.warm, .toEN):
            pairs = [
                ("我今天有點累，等等回家可以陪我嗎", "I'm a bit tired today — could you keep me company when you get home"),
            ]
        case (.casual, .toZH):
            pairs = [
                ("can you send me the report by friday", "禮拜五前把報告寄給我吧"),
            ]
        case (.formal, .toZH):
            pairs = [
                ("can you send me the report by friday", "請您於本週五前將報告寄送給我。"),
            ]
        case (.warm, .toZH):
            pairs = [
                ("text me when you're home safe", "到家了傳訊息給我"),
            ]
        case (.tactful, .off):
            pairs = [
                // Decline politely with a brief reason — STATEMENT rephrase
                ("我不想做這個案子",
                 "這個案子我評估之後可能沒辦法接 想跟你聊聊是不是有別的方式能幫上忙"),
                // Push back on a plan softly — STATEMENT rephrase
                ("這個方案不行",
                 "這方案我有點擔心 主要是 X 那邊可能撐不住 想聽聽你的想法"),
                // Chase a missing file — STATEMENT/REQUEST rephrase
                ("你忘了寄那個檔案",
                 "上次說的那個檔案我這邊還沒收到 你方便再傳一次嗎"),
                // Mixed-language deadline ask — QUESTION stays a QUESTION (softer)
                ("can you do this by tomorrow",
                 "i know it's a tight turnaround — would tomorrow be doable, or should we plan around something later"),
                // HARSH QUESTION → SOFTENED QUESTION. The speaker is asking
                // the recipient, not asking US to answer — output stays a
                // question with the accusatory edge filed off. This is the
                // anchor that prevents Tactful from "answering" questions.
                ("為什麼這個 bug 一直沒修",
                 "想 sync 一下這個 bug 的進度 看起來拖了一陣子 是不是有什麼 blocker 我可以幫忙看看"),
                // ANOTHER QUESTION → QUESTION example to drive the rule home
                ("你什麼時候才會把報告寄給我",
                 "想跟你 check 一下報告的時程 大概什麼時候方便給我"),
                // Demand → request with reason
                ("我需要明天就要這個 ASAP",
                 "這邊比較急 想跟你 sync 一下明天有沒有機會先處理"),
                // NUMBERED list — tactful framing for asks (acknowledge context first)
                ("我想跟你約時間討論預算、時程跟人力",
                 "想跟你約個時間聊一下 主要有三個面向想討論：\n1. 預算\n2. 時程\n3. 人力"),
            ]
        case (.tactful, .toEN):
            pairs = [
                // Statement → English Tactful
                ("我不想做這個案子",
                 "I'd rather not take this one on — happy to chat about how I can help in a different way"),
                // Soft pushback on a plan
                ("這個方案不太行",
                 "This direction has me a bit concerned — would love to talk through the alternatives"),
                // QUESTION stays a QUESTION in English
                ("為什麼這個 bug 一直沒修",
                 "Wanted to check in on this bug — looks like it's been pending for a while, anything blocking?"),
                // Chasing — soft accusation removed
                ("你忘了寄那個檔案了",
                 "Haven't seen that file land on my end yet — could you resend when you get a chance?"),
            ]
        case (.tactful, .toZH):
            pairs = [
                // Deadline pushback → 繁中 Tactful
                ("i can't do this by tomorrow",
                 "明天可能來不及 我們是不是可以一起看一下要怎麼安排"),
                // QUESTION stays a QUESTION in 繁中
                ("why isn't this done yet",
                 "想 sync 一下進度 是不是有什麼地方卡住 我可以幫上忙"),
                // Soft pushback on a plan
                ("this plan won't work",
                 "這個方向我有點擔心 想聽聽你的想法"),
                // Urgent request → softer framing
                ("i need this asap",
                 "這個案子比較急 想跟你討論一下時程怎麼安排"),
            ]

        // Plain (.off) is bypassed in RecordingService (GPT is skipped),
        // so these few-shots only fire when translation is active. They
        // demonstrate the desired "translate-only, no other changes"
        // behavior that the verbatim header dictates.
        case (.plain, .off):
            pairs = []  // never invoked — GPT bypassed entirely for this combo
        case (.plain, .toEN):
            pairs = [
                // Gaming term preserved through translation
                ("25 星可以一起打嗎", "Can we tackle the 25-star together?"),
                // Tech jargon preserved
                ("這個 PR 的 CI 紅了 幫看一下", "The CI for this PR is failing, could you take a look?"),
                // Plain conversational — minimal stylizing
                ("等等開團 缺一個輔助", "Forming a party shortly, need one support"),
            ]
        case (.plain, .toZH):
            pairs = [
                ("can we tackle the 25-star together",
                 "25 星可以一起打嗎"),
                ("CI is red on this PR, can you take a look",
                 "這個 PR 的 CI 紅了 可以幫看一下嗎"),
                ("forming a party, need one support",
                 "等等開團 缺一個輔助"),
            ]
        }

        var messages: [[String: Any]] = []
        for (input, output) in pairs {
            messages.append(["role": "user", "content": input])
            messages.append(["role": "assistant", "content": output])
        }
        return messages
    }
}
