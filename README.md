# Narrate

Point at any text on your Mac, and Narrate reads it aloud, lighting up each word on screen as
it's spoken, with big TikTok-style subtitles at the bottom. It's built for accessibility
(dyslexia, low vision, fatigue) and for reading faster.

It works on **any** pixels: web pages, PDFs, images, videos, slides, apps that block copy/paste,
because it reads the screen itself with on-device OCR. With the offline voice, nothing leaves your
Mac. With natural voices, only the text being read is sent to ElevenLabs.

## Use

| Shortcut | Action |
|---|---|
| **⌃⌥R** | Read from the word under the pointer (press again to stop) |
| **⌃⌥P** | Pause / resume |
| **⌃⌥F** | Follow-mouse mode: rest the pointer on any text and it starts reading there |
| **Esc** | Stop (only while reading) |

Menu bar icon → speed (0.8×–2×), voice, toggles for subtitles / on-screen highlight /
continue to the next paragraph.

## Voices

**Natural (recommended):** Menu ▸ Voice ▸ *Set Up Natural Voices…* and paste an
[ElevenLabs API key](https://elevenlabs.io/app/settings/api-keys). The key is kept in your macOS
Keychain. The audio streams in with per-character timestamps, so the highlight follows the real
audio clock (measured drift under 20ms). The next paragraph is generated while the current one
plays. This uses ElevenLabs character credits. *Quality* switches between Flash v2.5 (fastest) and
Multilingual v2 (most natural). If the network or API fails, Narrate falls back to the offline voice
mid-sentence.

**Offline (Apple):** the free fallback. To make it sound much better, download a *Premium* voice:
System Settings ▸ Accessibility ▸ Spoken Content ▸ System Voice ▸ Manage Voices. In "Auto" mode
Narrate picks the best installed voice for each paragraph's language.

## Build & run

```bash
scripts/build-app.sh --open      # builds dist/Narrate.app and launches it
.build/debug/Narrate --selftest  # OCR + layout + realign pipeline test (no permissions needed)

# natural-voice streaming + word-clock test against a local fake ElevenLabs server
python3 scripts/fake_elevenlabs.py 8765 &
NARRATE_ELEVEN_BASE=http://127.0.0.1:8765 .build/debug/Narrate --selftest-stream
```

Timings are logged: `log stream --predicate 'subsystem == "com.ash.narrate"'`.

On first launch Narrate shows one setup dialog: turn it on under Screen & System Audio Recording,
then click **Relaunch Narrate**.

**Keep the permission across rebuilds:** macOS ties the permission to the app's signature, and
ad-hoc signatures change on every build. Create a self-signed certificate once (Keychain Access ▸
Certificate Assistant ▸ Create a Certificate…, name `Narrate Dev`, type *Code Signing*). The build
script picks it up automatically. If a stale entry keeps the prompt coming back, run
`tccutil reset ScreenCapture com.ash.narrate`.

## How it works

```
hotkey / dwell ──► ScreenCaptureKit grab of the display (Narrate's own windows excluded)
               ──► Vision OCR (accurate, auto-language) ──► lines + per-word boxes
               ──► Layout: stitch rows, group lines into paragraphs, hit-test the pointer
               ──► AVSpeechSynthesizer, with a word-boundary callback for each word
               ──► HighlightOverlay (click-through, slides between word boxes)
                   + SubtitleBar (≤6-word chunks, current word in yellow)
```

- **Scrolling while reading:** the highlight hides, speech keeps going, and when scrolling stops
  Narrate re-scans and re-anchors the remaining words to their new positions.
- **Hyphenated line breaks** ("under-/standing") are joined so they're spoken as one word.
- **Continue reading:** at the end of a paragraph it moves to the next one below in the same column.
- **Responsiveness:** Vision compiles its OCR model per screen size the first time (~30s), so
  Narrate warms it up in the background at launch. After that a full Retina screen takes about 0.45s.
  Follow mode starts scanning as soon as the pointer moves, so the scan is ready when it stops.
  Scans are cached and thrown away on any click or scroll.

| File | Role |
|---|---|
| `TextCapture.swift` | Screen capture + Vision OCR → words with screen rects |
| `Layout.swift` | Paragraph grouping, pointer hit-testing, next block, scroll re-alignment |
| `Speaker.swift` | Offline Apple TTS, word callbacks, voice/language selection |
| `ElevenLabsSpeaker.swift` | Natural voices: streaming PCM + timestamps, audio-clock word sync, prefetch |
| `HighlightOverlay.swift` | On-screen word highlight |
| `SubtitleBar.swift` | Karaoke captions |
| `ReaderController.swift` | Orchestration, follow-mouse, scroll re-sync |

## Roadmap

- [ ] **"Explain / summarise" mode (Claude):** speak a short summary of the paragraph and highlight
      the exact source words each point comes from
- [ ] Accessibility-API text path for native apps (exact text, no OCR errors), with OCR as fallback
- [ ] Local neural voice (e.g. Kokoro) for natural speech with no cloud or credits
- [ ] Bionic-reading / focus dimming: fade everything except the current line
- [ ] Draggable subtitle bar, font size settings, Settings window
- [ ] Multi-column pages and tables: smarter reading order
