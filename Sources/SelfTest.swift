import Foundation

func runSelfTest() -> Int32 {
    var failed = 0
    func check(_ name: String, _ condition: Bool) {
        if condition {
            print("ok  \(name)")
        } else {
            print("FAIL \(name)")
            failed += 1
        }
    }

    let password = "test-password"
    let plain = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyIn0.sig"
    let encrypted = electronEncrypt(password: password, plaintext: plain)
    let decrypted = encrypted.flatMap { electronDecrypt(password: password, ciphertext: $0) }
    check("v10 roundtrip", decrypted == plain)
    check("wrong password rejected", electronDecrypt(password: "other", ciphertext: encrypted ?? Data()) != plain)

    let cursor = UsageParsers.cursorSummary([
        "membershipType": "premium",
        "isUnlimited": false,
        "billingCycleEnd": "2026-12-01T00:00:00.000Z",
        "individualUsage": [
            "plan": [
                "autoPercentUsed": 20,
                "apiPercentUsed": 0,
                "limit": 4615,
                "remaining": 4000,
            ],
        ],
    ])
    check("cursor plan", cursor.plan == "Premium")
    check("cursor model remaining", cursor.meters.first?.remainingPercent == 80)
    check("cursor api remaining", cursor.meters.dropFirst().first?.remainingPercent == 100)
    check("cursor allowance note", cursor.notes.first == "包含额度剩余 4,000 / 4,615")

    let messageOnly = UsageParsers.cursorSummary([
        "autoModelSelectedDisplayMessage": "You've used 42% of your included total usage",
        "namedModelSelectedDisplayMessage": "You've used 7% of your included API usage",
    ])
    check("cursor message fallback", messageOnly.meters.map(\.remainingPercent) == [58, 93])

    let grok = UsageParsers.grokBot([
        "usagePercent": 0.30335861321776814,
        "hasNonZeroIncludedLimit": true,
        "grokPlanLabel": "Grok Bot Plan",
        "nextResetTimestampUtc": "2026-11-11T14:34:03.889Z",
    ])
    check("grok remaining", abs((grok.meters.first?.remainingPercent ?? 0) - 99.69664138678223) < 0.0001)
    check("grok percent text", grok.meters.first.map { UsageFormat.percent($0.remainingPercent) } == "99.7%")
    check("grok reset", grok.meters.first?.resetAt != nil)

    let noGrant = UsageParsers.grokBot(["hasNonZeroIncludedLimit": false, "usagePercent": 0])
    check("grok no grant", noGrant.error != nil && noGrant.meters.isEmpty)

    let codex = UsageParsers.codex([
        "plan_type": "plus",
        "rate_limit": [
            "allowed": false,
            "limit_reached": true,
            "primary_window": [
                "used_percent": 100,
                "limit_window_seconds": 18000,
                "reset_at": 1_794_032_904,
            ],
            "secondary_window": [
                "used_percent": 16,
                "limit_window_seconds": 604800,
                "reset_at": 1_794_619_749,
            ],
        ],
    ])
    check("codex windows", codex.meters.map(\.label) == ["5 小时", "7 天"])
    check("codex remaining", codex.meters.map { UsageFormat.percent($0.remainingPercent) } == ["0%", "84%"])
    check("codex exhausted footnote", codex.meters.first?.footnote == "已用尽")

    let pieces = BarTitle.pieces(for: codex).map(\.text)
    check("bar pieces", pieces == ["Codex", "0%", "·", "84%"])

    let soon = Date().addingTimeInterval(90 * 60)
    check("reset text", UsageFormat.resetText(soon).contains("1 小时"))

    let kimiCode = UsageParsers.kimi([[
        "usage": [
            "limit": "2048",
            "used": "214",
            "remaining": "1834",
            "resetTime": "2026-01-09T15:23:13.716839300Z",
        ],
        "limits": [[
            "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
            "detail": [
                "limit": "200",
                "used": "139",
                "remaining": "61",
                "resetTime": "2026-01-06T13:33:02.717Z",
            ],
        ]],
    ]], planHint: "Andante")
    check("kimi plan", kimiCode.plan == "Andante")
    check("kimi windows", kimiCode.meters.map(\.label) == ["5 小时", "每周"])
    check("kimi percents", kimiCode.meters.map { UsageFormat.percent($0.remainingPercent) } == ["30.5%", "89.6%"])
    check("kimi count footnote", kimiCode.meters.last?.footnote == "剩余 1,834 / 2,048")
    check("kimi nanosecond reset", kimiCode.meters.last?.resetAt != nil)

    let now = Date()
    let soonReset = ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600))
    let kimiDesktop = UsageParsers.kimi([
        [
            "usage": ["limit": "100", "remaining": "100", "resetTime": soonReset],
        ],
        [
            "user": ["membership": ["level": "LEVEL_TRIAL"]],
            "totalQuota": [
                "limit": "100",
                "used": "57",
                "remaining": "43",
                "resetTime": "2026-11-24T00:00:00Z",
            ],
        ],
    ], planHint: "Andante", now: now)
    check("kimi drops hollow window", kimiDesktop.meters.map(\.label) == ["额度"])
    check("kimi total remaining", kimiDesktop.meters.first.map { UsageFormat.percent($0.remainingPercent) } == "43%")

    if failed == 0 {
        print("self-test passed")
        return 0
    }
    print("\(failed) failed")
    return 1
}
