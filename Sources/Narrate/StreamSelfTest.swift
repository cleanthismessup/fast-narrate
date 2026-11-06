import AppKit

/// `NARRATE_ELEVEN_BASE=http://127.0.0.1:PORT Narrate --selftest-stream`: plays a fake
/// ElevenLabs stream (silent audio + chunk-relative timings) and checks the word clock.
@MainActor
enum StreamSelfTest {
    static func run() -> Int32 {
        ElevenLabsSpeaker.cachedKey = .some("test-key")
        let words = ["one", "two", "three", "four", "five", "six"]
        let speaker = ElevenLabsSpeaker()
        let t = Date()
        speaker.warmUp()
        print(String(format: "  audio engine start: %.2fs", Date().timeIntervalSince(t)))
        let start = Date()
        var seen: [(Int, Double)] = []
        var finished: Double?
        var failure: Error?
        speaker.onWord = { seen.append(($0, Date().timeIntervalSince(start))) }
        speaker.onFinish = { finished = Date().timeIntervalSince(start) }
        speaker.onError = { failure = $0 }
        speaker.speak(words, speed: 1.0)
        while finished == nil, failure == nil, Date().timeIntervalSince(start) < 8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        for (w, t) in seen { print(String(format: "  word %d (%@) at %.2fs", w, words[w], t)) }
        if let failure { print("FAIL error: \(failure.localizedDescription)"); return 1 }
        var ok = true
        func check(_ c: Bool, _ m: String) { print(c ? "  ok   \(m)" : "  FAIL \(m)"); ok = ok && c }
        check(seen.map(\.0) == Array(0..<words.count), "every word reported once, in order")
        check(finished != nil, String(format: "finished (%.2fs)", finished ?? -1))
        // Fake server: 3 chunks × 0.5s; word k starts at k*0.25s of audio, plus network/start delay.
        if let t0 = seen.first?.1, seen.count == words.count {
            let drift = seen.enumerated().map { abs(($0.element.1 - t0) - Double($0.offset) * 0.25) }.max() ?? 9
            check(drift < 0.08, String(format: "words land on their audio timestamps (max drift %.0fms)", drift * 1000))
        }
        print(ok ? "PASS" : "FAILED")
        return ok ? 0 : 1
    }
}
