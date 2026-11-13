import AVFoundation
import Foundation

struct ElevenLabsVoice: Codable, Equatable {
    let id: String
    let name: String
}

enum ElevenLabsError: LocalizedError {
    case noKey
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noKey: return "No ElevenLabs API key set."
        case let .http(code, msg): return code == 401 ? "ElevenLabs rejected the API key (\(msg))." : "ElevenLabs error \(code): \(msg)"
        }
    }
}

enum ElevenLabsAPI {
    static let base = URL(string: ProcessInfo.processInfo.environment["NARRATE_ELEVEN_BASE"]
        ?? "https://api.elevenlabs.io")!
    static let sampleRate = 24_000.0

    static let models: [(id: String, label: String)] = [
        ("eleven_flash_v2_5", "Fastest (Flash v2.5)"),
        ("eleven_multilingual_v2", "Most natural (Multilingual v2)"),
    ]

    /// ElevenLabs' stock voices, used if the account's voice list can't be fetched.
    static let fallbackVoices: [ElevenLabsVoice] = [
        .init(id: "EXAVITQu4vr4xnSDxMaL", name: "Sarah"),
        .init(id: "JBFqnCBsd6RMkjVDRZzb", name: "George"),
        .init(id: "XB0fDUnXU5powFXDhCwa", name: "Charlotte"),
        .init(id: "nPczCjzI2devNBz1zQrb", name: "Brian"),
        .init(id: "Xb7hH8MSUJpSbSDYk0k2", name: "Alice"),
        .init(id: "onwK4e9ZLuTAKqWW03F9", name: "Daniel"),
        .init(id: "pFZP5JQG7iQjIQuC4Bku", name: "Lily"),
    ]

    static func voices(apiKey: String) async throws -> [ElevenLabsVoice] {
        var req = URLRequest(url: base.appendingPathComponent("v1/voices"))
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ElevenLabsError.http(code, message(from: data)) }
        struct Response: Decodable {
            struct Voice: Decodable { let voice_id: String; let name: String }
            let voices: [Voice]
        }
        return try JSONDecoder().decode(Response.self, from: data).voices.map { .init(id: $0.voice_id, name: $0.name) }
    }

    static func message(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let d = obj["detail"] as? [String: Any], let m = d["message"] as? String { return m }
            if let d = obj["detail"] as? String { return d }
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? "unknown error"
    }

    static func streamRequest(text: String, apiKey: String, voiceID: String, model: String) -> URLRequest {
        var c = URLComponents(url: base.appendingPathComponent("v1/text-to-speech/\(voiceID)/stream/with-timestamps"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "text": text,
            "model_id": model,
            "voice_settings": ["stability": 0.45, "similarity_boost": 0.75, "style": 0.0, "use_speaker_boost": true],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }
}

/// One streaming synthesis request: accumulates raw PCM chunks and per-character start times.
@MainActor
final class StreamJob {
    let text: String
    private(set) var pcm: [Data] = []
    private(set) var charStarts: [Double] = []
    private(set) var audioSeconds = 0.0
    private(set) var isDone = false
    private(set) var error: Error?
    let created = Date()
    var onUpdate: (() -> Void)?

    private var task: Task<Void, Never>?
    private var lastStart = -Double.infinity
    private var carry = Data()

    init(text: String, request: URLRequest) {
        self.text = text
        task = Task.detached { [weak self] in
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: request)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code != 200 {
                    var d = Data()
                    for try await b in bytes { d.append(b); if d.count > 8192 { break } }
                    throw ElevenLabsError.http(code, ElevenLabsAPI.message(from: d))
                }
                // The response is a sequence of JSON objects; split on balanced braces so we
                // don't depend on how they're delimited.
                var buf = Data()
                var depth = 0, inString = false, escaped = false, started = false
                for try await b in bytes {
                    if !started {
                        guard b == UInt8(ascii: "{") else { continue }
                        started = true
                    }
                    buf.append(b)
                    if inString {
                        if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
                        continue
                    }
                    switch b {
                    case 0x22: inString = true
                    case 0x7B: depth += 1
                    case 0x7D:
                        depth -= 1
                        if depth == 0 {
                            let object = buf
                            buf = Data()
                            started = false
                            await self?.ingest(object)
                        }
                    default: break
                    }
                }
                await self?.finish(nil)
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                await self?.finish(error)
            }
        }
    }

    func cancel() {
        task?.cancel()
        onUpdate = nil
    }

    private func ingest(_ data: Data) {
        struct Chunk: Decodable {
            struct Alignment: Decodable { let character_start_times_seconds: [Double] }
            let audio_base64: String?
            let alignment: Alignment?
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { return }
        let audioBefore = audioSeconds
        if let b64 = chunk.audio_base64, let decoded = Data(base64Encoded: b64) {
            var d = carry + decoded
            carry = Data()
            if d.count % 2 == 1 { carry = Data(d.suffix(1)); d = Data(d.dropLast()) }
            if !d.isEmpty {
                pcm.append(d)
                audioSeconds += Double(d.count / 2) / ElevenLabsAPI.sampleRate
            }
        }
        if let starts = chunk.alignment?.character_start_times_seconds, let first = starts.first {
            // Chunk timings may be relative to the chunk; if they jump backwards, offset them.
            let offset = first + 0.05 < lastStart ? audioBefore : 0
            charStarts += starts.map { $0 + offset }
            lastStart = charStarts.last ?? lastStart
        }
        onUpdate?()
    }

    private func finish(_ error: Error?) {
        self.error = error
        isDone = true
        onUpdate?()
    }
}

/// Natural neural voices via ElevenLabs, with highlight timing taken from the audio clock.
@MainActor
final class ElevenLabsSpeaker: SpeechEngine {
    var onWord: ((Int) -> Void)?
    var onFinish: (() -> Void)?
    var onError: ((Error) -> Void)?

    static var cachedKey: String??

    static var apiKey: String? {
        get {
            if let k = cachedKey { return k }
            let k = Keychain.read("elevenlabs")
            cachedKey = .some(k)
            return k
        }
        set {
            Keychain.write(newValue, "elevenlabs")
            cachedKey = .some(newValue)
        }
    }

    static var isConfigured: Bool { apiKey?.isEmpty == false }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: ElevenLabsAPI.sampleRate,
                                       channels: 1, interleaved: false)!

    private var job: StreamJob?
    private var prefetched: StreamJob?
    private var wordCharStart: [Int] = []
    private var scheduledChunks = 0
    private var pendingBuffers = 0
    private var started = false
    private var starved = false
    private var userPaused = false
    private var lastWord = -1
    private var clock: Timer?
    private var generation = 0

    /// Small lead so the highlight lands as the word is heard, not just after.
    private let highlightLead = 0.05

    init() {
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    /// Spin the audio engine up ahead of time so the first word isn't delayed by device start.
    func warmUp() {
        idleStop?.cancel()
        guard !engine.isRunning else { return }
        let t = Date()
        try? engine.start()
        Log.timing("audio engine start", since: t)
    }

    /// Open the TLS connection to ElevenLabs while the screen is still being scanned.
    func preconnect() {
        var req = URLRequest(url: ElevenLabsAPI.base)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req).resume()
    }

    private var idleStop: DispatchWorkItem?

    /// Release the audio device when nothing has played for a while.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.job == nil else { return }
            self.engine.stop()
        }
        idleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func makeJob(_ text: String) -> StreamJob? {
        guard let key = Self.apiKey else { return nil }
        let s = Settings.shared
        let voice = s.elevenVoiceID ?? ElevenLabsAPI.fallbackVoices[0].id
        return StreamJob(text: text, request: ElevenLabsAPI.streamRequest(text: text, apiKey: key, voiceID: voice,
                                                                          model: s.elevenModel))
    }

    func prefetch(_ words: [String]) {
        let text = words.joined(separator: " ")
        guard prefetched?.text != text, job?.text != text else { return }
        prefetched?.cancel()
        prefetched = makeJob(text)
    }

    func speak(_ words: [String], speed: Double) {
        reset()
        let text = words.joined(separator: " ")
        let j: StreamJob
        if let p = prefetched, p.text == text, p.error == nil {
            j = p
        } else {
            prefetched?.cancel()
            guard let fresh = makeJob(text) else { onError?(ElevenLabsError.noKey); return }
            j = fresh
        }
        prefetched = nil
        job = j

        var idx = 0
        wordCharStart = words.map { w in
            defer { idx += w.count + 1 }
            return idx
        }
        pitch.rate = Float(min(max(speed, 0.5), 2.0))
        idleStop?.cancel()
        if !engine.isRunning {
            do { try engine.start() } catch { onError?(error); return }
        }
        j.onUpdate = { [weak self, weak j] in
            guard let self, let j, j === self.job else { return }
            self.pump()
        }
        clock = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        pump()
    }

    func stop() {
        reset()
        prefetched?.cancel()
        prefetched = nil
    }

    func pause() {
        userPaused = true
        player.pause()
    }

    func resume() {
        userPaused = false
        if started, pendingBuffers > 0 { player.play(); starved = false } else { pump() }
    }

    // MARK: Playback

    private func reset() {
        generation += 1
        clock?.invalidate()
        clock = nil
        job?.cancel()
        job = nil
        player.stop()
        scheduledChunks = 0
        pendingBuffers = 0
        started = false
        starved = false
        userPaused = false
        lastWord = -1
        scheduleIdleStop()
    }

    private func pump() {
        guard let j = job else { return }
        if let e = j.error {
            let cb = onError
            reset()
            cb?(e)
            return
        }
        while scheduledChunks < j.pcm.count {
            schedule(j.pcm[scheduledChunks])
            scheduledChunks += 1
        }
        guard !userPaused else { return }
        if !started, j.audioSeconds >= 0.3 || j.isDone, pendingBuffers > 0 {
            player.play()
            started = true
            Log.timing("natural voice first audio", since: j.created)
        } else if starved, pendingBuffers > 0 {
            player.play()
            starved = false
        }
        checkFinished()
    }

    private func schedule(_ d: Data) {
        let frames = d.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let out = buf.floatChannelData![0]
        d.withUnsafeBytes { raw in
            for i in 0..<frames {
                out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
        }
        pendingBuffers += 1
        let gen = generation
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.bufferPlayed(gen) }
            }
        }
    }

    private func bufferPlayed(_ gen: Int) {
        guard gen == generation else { return }
        pendingBuffers -= 1
        if pendingBuffers == 0, let j = job, !j.isDone, !userPaused {
            // Network fell behind playback: pause the clock so the highlight doesn't run ahead.
            player.pause()
            starved = true
        }
        checkFinished()
    }

    private func checkFinished() {
        guard let j = job, j.isDone, j.error == nil, pendingBuffers == 0, scheduledChunks == j.pcm.count else { return }
        if let last = wordCharStart.indices.last, lastWord != last { onWord?(last) }
        let cb = onFinish
        reset()
        cb?()
    }

    private func tick() {
        guard started, let j = job, let nodeTime = player.lastRenderTime,
              let t = player.playerTime(forNodeTime: nodeTime) else { return }
        let now = Double(t.sampleTime) / t.sampleRate + highlightLead
        var w = lastWord
        while w + 1 < wordCharStart.count {
            let ci = wordCharStart[w + 1]
            guard ci < j.charStarts.count, j.charStarts[ci] <= now else { break }
            w += 1
        }
        if w != lastWord, w >= 0 {
            lastWord = w
            onWord?(w)
        }
    }
}
