import Foundation

/// Deterministic, regex-based formatting transformations that should be
/// consistent ACROSS ALL TONES — including Plain (which bypasses GPT) and
/// Verbatim mode (which tells GPT to skip rule 10). Runs as a final pass
/// after either Whisper (Plain bypass path) or GPT (normal rewrite path).
///
/// Patterns are deliberately conservative: only match when the input is
/// unambiguous. Borderline cases stay untouched on purpose — we'd rather
/// miss a conversion than mangle the speaker's intent (especially for the
/// Plain tone use case: gaming jargon, proper nouns, in-jokes).
///
/// Idempotent: running this twice produces the same result as running once,
/// so it's safe to chain after GPT (which may already have applied rule 10)
/// without risk of double-conversion.
enum LocalFormatter {

    static func apply(_ input: String) -> String {
        var output = input
        for transform in transforms {
            output = transform(output)
        }
        return output
    }

    private static let transforms: [(String) -> String] = [
        applyEmail,
        applyURL,
        applyCurrencyUSD,
        applyPercent,
        applyChinesePercent,
        // Order matters: minute patterns (more specific) before half-hour
        // before bare hour, and Chinese-digit forms after Arabic-digit
        // forms so already-converted matches don't double-fire.
        applyChineseTimeMinute,
        applyChineseTimeHalfHour,
        applyChineseDigitTimeMinute,
        applyChineseDigitTimeHalfHour,
        applyEnglishAmPm,
        applyEnglishDecimal,
        applyPhoneNumberUS,
    ]

    // MARK: - Chinese digit table

    /// Maps Chinese hour words to Arabic digits. Order matters when used
    /// in a sequential pattern loop — multi-character entries MUST appear
    /// before their single-character prefixes (e.g. "十二" before "十"),
    /// otherwise "十" would match first and leave "二" orphaned.
    private static let chineseHourPairs: [(zh: String, arabic: String)] = [
        ("十二", "12"),
        ("十一", "11"),
        ("十", "10"),
        ("兩", "2"),  // 兩點 is the spoken form for 2 o'clock in 中文
        ("一", "1"), ("二", "2"), ("三", "3"), ("四", "4"), ("五", "5"),
        ("六", "6"), ("七", "7"), ("八", "8"), ("九", "9"),
    ]

    // MARK: - Regex helper

    private static func regexReplace(_ input: String,
                                       pattern: String,
                                       template: String,
                                       options: NSRegularExpression.Options = [.caseInsensitive]) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input,
                                                options: [],
                                                range: range,
                                                withTemplate: template)
    }

    // MARK: - Patterns

    /// "user at example dot com"  →  "user@example.com"
    /// Requires `at … dot …` shape — won't match prose like "meet me at home".
    private static func applyEmail(_ input: String) -> String {
        regexReplace(input,
                     pattern: #"([A-Za-z0-9._+-]+)\s+at\s+([A-Za-z0-9-]+)\s+dot\s+([A-Za-z]{2,})"#,
                     template: "$1@$2.$3")
    }

    /// "github dot com slash your dash org"  →  "github.com/your-org"
    /// Conservative: requires the `<host> dot <tld> slash` shape.
    private static func applyURL(_ input: String) -> String {
        var s = input
        s = regexReplace(s,
                         pattern: #"([A-Za-z0-9-]+)\s+dot\s+([A-Za-z]{2,})\s+slash\s+"#,
                         template: "$1.$2/")
        // Within an already-formed URL stem ("github.com/"), trailing
        // " dash X" tokens become "-X". Conservative: only fires when
        // preceded by an already-formatted URL slash.
        s = regexReplace(s,
                         pattern: #"(\S+/[A-Za-z0-9-]+)\s+dash\s+([A-Za-z0-9]+)"#,
                         template: "$1-$2")
        return s
    }

    /// "5 dollars" / "500 dollars" / "$5" left alone.
    /// "5 dollars" → "$5"
    /// "500 dollars" → "$500"
    private static func applyCurrencyUSD(_ input: String) -> String {
        regexReplace(input,
                     pattern: #"(\d+(?:,\d{3})*(?:\.\d+)?)\s+dollars?"#,
                     template: "$$$1")
    }

    /// "30 percent" / "30 趴" → "30%"
    private static func applyPercent(_ input: String) -> String {
        regexReplace(input,
                     pattern: #"(\d+(?:\.\d+)?)\s*(?:percent|趴)\b"#,
                     template: "$1%")
    }

    /// "百分之三十" / "百分之 30" — second form converts to "30%".
    /// First form (pure Chinese digits) too risky to convert reliably;
    /// leave for GPT in non-Plain modes.
    private static func applyChinesePercent(_ input: String) -> String {
        regexReplace(input,
                     pattern: #"百分之\s*(\d+(?:\.\d+)?)"#,
                     template: "$1%")
    }

    /// "三點半" / "3 點半" / "下午三點半" → "3:30" / "下午 3:30"
    /// Only matches when minutes are exactly "半" (= 30). Other patterns
    /// (e.g. 三點一刻 = 3:15) are too uncommon to handle reliably.
    private static func applyChineseTimeHalfHour(_ input: String) -> String {
        regexReplace(input,
                     pattern: #"(\d{1,2})\s*點\s*半"#,
                     template: "$1:30")
    }

    /// "3 點 30 分" / "下午 3 點 45 分" → "3:30" / "下午 3:45"
    private static func applyChineseTimeMinute(_ input: String) -> String {
        regexReplace(input,
                     pattern: #"(\d{1,2})\s*點\s*(\d{1,2})\s*分"#,
                     template: "$1:$2")
    }

    /// 中文-digit hour + 半 → "X:30"
    /// Examples:
    ///   "三點半"        → "3:30"
    ///   "下午三點半"    → "下午 3:30"
    ///   "十二點半"      → "12:30"
    ///   "兩點半"        → "2:30"   (兩 is the spoken form for 2)
    /// Whisper transcribes Chinese-language input with Chinese digit
    /// characters by default. Without this pass those stay literal.
    private static func applyChineseDigitTimeHalfHour(_ input: String) -> String {
        var s = input
        for pair in chineseHourPairs {
            s = regexReplace(s,
                             pattern: "\(pair.zh)\\s*點\\s*半",
                             template: "\(pair.arabic):30",
                             options: [])
        }
        return s
    }

    /// 中文-digit hour + (Arabic minute) 分 → "X:Y"
    /// Examples:
    ///   "三點 15 分"  → "3:15"
    ///   "下午十點 45 分" → "下午 10:45"
    /// Pure-Chinese minute ("三點四十五分") is intentionally NOT handled —
    /// parsing multi-character Chinese numerals reliably is out of scope.
    private static func applyChineseDigitTimeMinute(_ input: String) -> String {
        var s = input
        for pair in chineseHourPairs {
            s = regexReplace(s,
                             pattern: "\(pair.zh)\\s*點\\s*(\\d{1,2})\\s*分",
                             template: "\(pair.arabic):$1",
                             options: [])
        }
        return s
    }

    /// "3 pm" / "3 PM" / "10 am" → "3pm" / "10am" (no space, lowercase)
    private static func applyEnglishAmPm(_ input: String) -> String {
        regexReplace(input,
                     pattern: #"(\d{1,2})\s+(am|pm)\b"#,
                     template: "$1$2")
    }

    /// "3 point 14" → "3.14"   (NOT "3.1.4" — single decimal point)
    private static func applyEnglishDecimal(_ input: String) -> String {
        regexReplace(input,
                     pattern: #"(\d+)\s+point\s+(\d+)"#,
                     template: "$1.$2")
    }

    /// "918 555 0100" / "918-555-0100" → "918-555-0100"
    /// 10-digit US format only. Anchored at word boundaries to avoid
    /// snagging digits embedded in longer numeric runs.
    private static func applyPhoneNumberUS(_ input: String) -> String {
        regexReplace(input,
                     pattern: #"\b(\d{3})[\s-](\d{3})[\s-](\d{4})\b"#,
                     template: "$1-$2-$3")
    }
}
