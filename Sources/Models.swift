import Foundation

struct Meter: Equatable {
    var label: String
    /// 剩余比例，0...100。
    var remainingPercent: Double
    var resetAt: Date?
    var footnote: String?
}

struct ProviderReading: Equatable {
    var name: String
    var plan: String?
    var meters: [Meter]
    var notes: [String]
    var error: String?

    static func failed(_ name: String, _ error: String) -> ProviderReading {
        ProviderReading(name: name, plan: nil, meters: [], notes: [], error: error)
    }
}

enum UsageFormat {
    static func remaining(usedPercent: Double) -> Double {
        min(100, max(0, 100 - usedPercent))
    }

    static func percent(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.001 {
            return "\(Int(rounded.rounded()))%"
        }
        return String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), rounded)
    }

    static func count(_ value: Double) -> String {
        if abs(value - value.rounded()) < 0.001 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.usesGroupingSeparator = true
            formatter.groupingSeparator = ","
            formatter.groupingSize = 3
            return formatter.string(from: NSNumber(value: Int(value.rounded()))) ?? "\(Int(value.rounded()))"
        }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func windowLabel(seconds: Double) -> String {
        switch Int(seconds.rounded()) {
        case 18_000: return "5 小时"
        case 604_800: return "7 天"
        default:
            if seconds >= 86_400 { return "\(max(1, Int((seconds / 86_400).rounded()))) 天" }
            if seconds >= 3_600 { return "\(max(1, Int((seconds / 3_600).rounded()))) 小时" }
            return "\(max(1, Int((seconds / 60).rounded()))) 分钟"
        }
    }

    static func resetText(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 60 { return "即将重置" }
        if seconds < 3_600 {
            return "\(Int(ceil(seconds / 60))) 分钟后重置"
        }
        if seconds < 48 * 3_600 {
            let hours = Int(seconds / 3_600)
            let minutes = Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60)
            if hours < 24 {
                return minutes > 0 ? "\(hours) 小时 \(minutes) 分后重置" : "\(hours) 小时后重置"
            }
            let days = hours / 24
            let rest = hours % 24
            return rest > 0 ? "\(days) 天 \(rest) 小时后重置" : "\(days) 天后重置"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date) + " 重置"
    }

    static func expiryText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date) + " 到期"
    }

    static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "premium": return "Premium"
        case "pro", "pro_plus", "proplus": return raw.lowercased().contains("plus") ? "Pro+" : "Pro"
        case "plus": return "Plus"
        case "ultra": return "Ultra"
        case "free": return "Free"
        case "team": return "Team"
        case "enterprise", "business": return "Enterprise"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}

enum JSONValue {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        return number.doubleValue
    }

    static func flag(_ value: Any?) -> Bool? {
        value as? Bool
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    /// 数字，或接口里用字符串表示的数字。
    static func quantity(_ value: Any?) -> Double? {
        if let number = number(value) { return number }
        if let text = string(value)?.trimmingCharacters(in: .whitespaces), let parsed = Double(text) {
            return parsed
        }
        return nil
    }

    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func date(_ value: Any?) -> Date? {
        guard var text = string(value) else { return nil }
        // 有的接口给出纳秒。ISO8601 只接受毫秒，多出来的小数位要先截掉。
        if let dot = text.firstIndex(of: ".") {
            let afterDot = text.index(after: dot)
            if let zone = text[afterDot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }),
               text.distance(from: afterDot, to: zone) > 3 {
                let keep = text.index(dot, offsetBy: 4)
                text = String(text[..<keep]) + String(text[zone...])
            }
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

enum UsageParsers {
    static func cursorSummary(_ json: [String: Any]) -> ProviderReading {
        let plan = UsageFormat.planName(JSONValue.string(json["membershipType"]))
        let reset = JSONValue.date(json["billingCycleEnd"])
        if JSONValue.flag(json["isUnlimited"]) == true {
            return ProviderReading(
                name: "Cursor",
                plan: plan,
                meters: [Meter(label: "额度", remainingPercent: 100, resetAt: reset, footnote: "不限量")],
                notes: [],
                error: nil)
        }

        var meters: [Meter] = []
        var notes: [String] = []
        let planUsage = JSONValue.object(JSONValue.object(json["individualUsage"])?["plan"])
        if let auto = JSONValue.number(planUsage?["autoPercentUsed"]) {
            meters.append(Meter(label: "模型", remainingPercent: UsageFormat.remaining(usedPercent: auto), resetAt: reset, footnote: nil))
        }
        if let api = JSONValue.number(planUsage?["apiPercentUsed"]) {
            meters.append(Meter(label: "API", remainingPercent: UsageFormat.remaining(usedPercent: api), resetAt: reset, footnote: nil))
        }
        if meters.isEmpty {
            if let auto = percent(in: JSONValue.string(json["autoModelSelectedDisplayMessage"])) {
                meters.append(Meter(label: "模型", remainingPercent: UsageFormat.remaining(usedPercent: auto), resetAt: reset, footnote: nil))
            }
            if let api = percent(in: JSONValue.string(json["namedModelSelectedDisplayMessage"])) {
                meters.append(Meter(label: "API", remainingPercent: UsageFormat.remaining(usedPercent: api), resetAt: reset, footnote: nil))
            }
        }
        if let limit = JSONValue.number(planUsage?["limit"]), limit > 0,
           let left = JSONValue.number(planUsage?["remaining"]) {
            notes.append("包含额度剩余 \(UsageFormat.count(left)) / \(UsageFormat.count(limit))")
        }
        let onDemand = JSONValue.object(JSONValue.object(json["individualUsage"])?["onDemand"])
        if JSONValue.flag(onDemand?["enabled"]) == true, let used = JSONValue.number(onDemand?["used"]), used > 0 {
            notes.append("按量已用 \(UsageFormat.count(used))")
        }
        guard !meters.isEmpty else {
            return .failed("Cursor", "用量接口没有返回可用的额度")
        }
        return ProviderReading(name: "Cursor", plan: plan, meters: meters, notes: notes, error: nil)
    }

    static func grokBot(_ json: [String: Any]) -> ProviderReading {
        let plan = UsageFormat.planName(JSONValue.string(json["grokPlanLabel"])) ?? "Grok Bot"
        if JSONValue.flag(json["usesPooledEnterpriseAllowance"]) == true {
            return .failed("Grok Bot", "当前是企业共享额度，没有个人余量")
        }
        if JSONValue.flag(json["includedLimitZero"]) == true || JSONValue.flag(json["hasNonZeroIncludedLimit"]) == false {
            return .failed("Grok Bot", "这个账号没有 Grok Bot 包含额度")
        }
        guard let used = JSONValue.number(json["usagePercent"]) else {
            return .failed("Grok Bot", "用量接口没有返回本周额度")
        }
        var notes: [String] = []
        if used >= 100, JSONValue.flag(json["hasAvailableUsage"]) == true {
            notes.append("包含额度已用尽，按量仍可用")
        }
        return ProviderReading(
            name: "Grok Bot",
            plan: plan,
            meters: [Meter(
                label: "本周",
                remainingPercent: UsageFormat.remaining(usedPercent: used),
                resetAt: JSONValue.date(json["nextResetTimestampUtc"]),
                footnote: used >= 100 ? "已用尽" : nil)],
            notes: notes,
            error: nil)
    }

    static func codex(_ json: [String: Any]) -> ProviderReading {
        let plan = UsageFormat.planName(JSONValue.string(json["plan_type"]))
        let rate = JSONValue.object(json["rate_limit"]) ?? [:]
        var meters: [Meter] = []
        if let window = JSONValue.object(rate["primary_window"]), let meter = codexMeter(window, fallback: "当前窗口") {
            meters.append(meter)
        }
        if let window = JSONValue.object(rate["secondary_window"]), let meter = codexMeter(window, fallback: "更长窗口") {
            meters.append(meter)
        }
        guard !meters.isEmpty else {
            return .failed("Codex", "用量接口没有返回额度窗口")
        }
        var notes: [String] = []
        if JSONValue.flag(rate["allowed"]) == false, meters.allSatisfy({ $0.remainingPercent > 0 }) {
            notes.append("账号当前不可用")
        }
        if let credits = JSONValue.object(json["credits"]),
           JSONValue.flag(credits["has_credits"]) == true,
           JSONValue.flag(credits["unlimited"]) != true,
           let balance = JSONValue.string(credits["balance"]),
           let amount = Double(balance), amount > 0 {
            notes.append("充值余额 \(balance)")
        }
        return ProviderReading(name: "Codex", plan: plan, meters: meters, notes: notes, error: nil)
    }

    private static func codexMeter(_ window: [String: Any], fallback: String) -> Meter? {
        guard let used = JSONValue.number(window["used_percent"]) else { return nil }
        let seconds = JSONValue.number(window["limit_window_seconds"]) ?? 0
        let label = seconds > 0 ? UsageFormat.windowLabel(seconds: seconds) : fallback
        let reset = JSONValue.number(window["reset_at"]).map { Date(timeIntervalSince1970: $0) }
        return Meter(
            label: label,
            remainingPercent: UsageFormat.remaining(usedPercent: used),
            resetAt: reset,
            footnote: used >= 100 ? "已用尽" : nil)
    }

    static func kimi(_ payloads: [[String: Any]], planHint: String?, now: Date = Date()) -> ProviderReading {
        struct Candidate {
            var meter: Meter
            var hollow: Bool
        }
        var candidates: [Candidate] = []
        var membership: String?
        for json in payloads {
            if membership == nil {
                membership = JSONValue.string(JSONValue.object(JSONValue.object(json["user"])?["membership"])?["level"])
            }
            if let limits = json["limits"] as? [Any] {
                for item in limits {
                    guard let entry = JSONValue.object(item), let detail = JSONValue.object(entry["detail"]) else { continue }
                    let window = JSONValue.object(entry["window"])
                    let label = kimiWindowLabel(window) ?? "窗口"
                    if let parsed = kimiCountMeter(label: label, detail: detail) {
                        candidates.append(Candidate(meter: parsed.meter, hollow: parsed.hollow))
                    }
                }
            }
            if let usage = JSONValue.object(json["usage"]),
               let parsed = kimiCountMeter(label: kimiUsageLabel(usage, now: now), detail: usage) {
                candidates.append(Candidate(meter: parsed.meter, hollow: parsed.hollow))
            }
            if let total = JSONValue.object(json["totalQuota"]),
               let parsed = kimiCountMeter(label: "额度", detail: total) {
                candidates.append(Candidate(meter: parsed.meter, hollow: parsed.hollow))
            }
        }
        if candidates.contains(where: { !$0.hollow }) {
            candidates.removeAll { $0.hollow }
        }
        var meters: [Meter] = []
        for candidate in candidates {
            let meter = candidate.meter
            let duplicate = meters.contains { existing in
                existing.label == meter.label
                    && abs(existing.remainingPercent - meter.remainingPercent) < 0.2
                    && abs((existing.resetAt?.timeIntervalSince1970 ?? 0) - (meter.resetAt?.timeIntervalSince1970 ?? 0)) < 2
            }
            if !duplicate { meters.append(meter) }
        }
        guard !meters.isEmpty else {
            return .failed("Kimi", "用量接口没有返回可用的额度")
        }
        let plan = UsageFormat.planName(planHint) ?? kimiMembershipName(membership)
        return ProviderReading(name: "Kimi", plan: plan, meters: meters, notes: [], error: nil)
    }

    /// 会员统计里的赠送额度。`amountUsedRatio` 是已用比例，过期的不再显示。
    static func kimiGifts(_ json: [String: Any], now: Date = Date()) -> [Meter] {
        guard let items = json["giftBalances"] as? [Any] else { return [] }
        struct Gift {
            var name: String?
            var remainingPercent: Double
            var expiry: Date?
        }
        var gifts: [Gift] = []
        for item in items {
            guard let gift = JSONValue.object(item) else { continue }
            if let type = JSONValue.string(gift["type"]), type != "GIFT" { continue }
            guard let used = JSONValue.quantity(gift["amountUsedRatio"]) else { continue }
            let expiry = JSONValue.date(gift["expireTime"])
            if let expiry, expiry <= now { continue }
            let usedPercent = min(100, max(0, used <= 1 ? used * 100 : used))
            let name = JSONValue.string(gift["displayName"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            gifts.append(Gift(
                name: (name?.isEmpty == false) ? name : nil,
                remainingPercent: UsageFormat.remaining(usedPercent: usedPercent),
                expiry: expiry))
        }
        return gifts.map { gift in
            var parts: [String] = []
            if gifts.count == 1, let name = gift.name, name != "赠送" {
                parts.append(name)
            }
            if let expiry = gift.expiry {
                parts.append(UsageFormat.expiryText(expiry))
            }
            let label = gifts.count > 1 ? (gift.name ?? "赠送") : "赠送"
            return Meter(
                label: label,
                remainingPercent: gift.remainingPercent,
                resetAt: nil,
                footnote: parts.isEmpty ? nil : parts.joined(separator: "，"))
        }
    }

    private static func kimiCountMeter(label: String, detail: [String: Any]) -> (meter: Meter, hollow: Bool)? {
        let limit = JSONValue.quantity(detail["limit"])
        let remaining = JSONValue.quantity(detail["remaining"])
        let used = JSONValue.quantity(detail["used"])
        guard let percent = kimiRemainingPercent(limit: limit, remaining: remaining, used: used) else { return nil }
        var footnote: String?
        if percent <= 0 {
            footnote = "已用尽"
        } else if let limit, let remaining, abs(limit - 100) > 0.001 {
            footnote = "剩余 \(UsageFormat.count(remaining)) / \(UsageFormat.count(limit))"
        }
        let meter = Meter(
            label: label,
            remainingPercent: percent,
            resetAt: JSONValue.date(detail["resetTime"]),
            footnote: footnote)
        let hollow = used == nil && percent >= 99.95
        return (meter, hollow)
    }

    private static func kimiRemainingPercent(limit: Double?, remaining: Double?, used: Double?) -> Double? {
        if let limit, limit > 0, let remaining {
            return min(100, max(0, remaining / limit * 100))
        }
        if let limit, limit > 0, let used {
            return min(100, max(0, (limit - used) / limit * 100))
        }
        return nil
    }

    private static func kimiUsageLabel(_ usage: [String: Any], now: Date) -> String {
        guard let reset = JSONValue.date(usage["resetTime"]) else { return "每周" }
        let distance = reset.timeIntervalSince(now)
        return distance > 0 && distance < 8 * 3_600 ? "短时" : "每周"
    }

    private static func kimiWindowLabel(_ window: [String: Any]?) -> String? {
        guard let duration = JSONValue.quantity(window?["duration"]), duration > 0 else { return nil }
        let unit = JSONValue.string(window?["timeUnit"]) ?? "TIME_UNIT_MINUTE"
        let seconds: Double
        switch unit {
        case "TIME_UNIT_SECOND": seconds = duration
        case "TIME_UNIT_HOUR": seconds = duration * 3_600
        case "TIME_UNIT_DAY": seconds = duration * 86_400
        default: seconds = duration * 60
        }
        return UsageFormat.windowLabel(seconds: seconds)
    }

    private static func kimiMembershipName(_ level: String?) -> String? {
        switch level {
        case "LEVEL_TRIAL": return "试用"
        case "LEVEL_FREE": return "免费"
        case nil: return nil
        default:
            let trimmed = level?.replacingOccurrences(of: "LEVEL_", with: "") ?? ""
            return trimmed.isEmpty ? nil : trimmed.prefix(1).uppercased() + trimmed.dropFirst().lowercased()
        }
    }

    private static func percent(in message: String?) -> Double? {
        guard let message else { return nil }
        guard let match = message.range(of: #"(\d+(?:\.\d+)?)%"#, options: .regularExpression) else { return nil }
        return Double(message[match].dropLast())
    }
}

enum BarTitle {
    struct Piece: Equatable {
        var text: String
        var remaining: Double?
    }

    static func pieces(for reading: ProviderReading) -> [Piece] {
        if reading.error != nil, reading.meters.isEmpty {
            return [Piece(text: reading.name, remaining: nil), Piece(text: "!", remaining: 0)]
        }
        var pieces = [Piece(text: reading.name, remaining: nil)]
        for (index, meter) in reading.meters.enumerated() {
            if index > 0 { pieces.append(Piece(text: "·", remaining: nil)) }
            pieces.append(Piece(text: UsageFormat.percent(meter.remainingPercent), remaining: meter.remainingPercent))
        }
        if reading.meters.isEmpty {
            pieces.append(Piece(text: "—", remaining: nil))
        }
        return pieces
    }

    static func tooltip(for readings: [ProviderReading]) -> String {
        readings.map { reading in
            if let error = reading.error, reading.meters.isEmpty {
                return "\(reading.name)：\(error)"
            }
            let body = reading.meters.map { "\($0.label) \(UsageFormat.percent($0.remainingPercent))" }.joined(separator: "，")
            return "\(reading.name) \(body)"
        }.joined(separator: "；")
    }
}
