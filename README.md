# Narrate

Point at any text on your Mac, and Narrate reads it aloud, lighting up each word on screen as
it's spoken, with big TikTok-style subtitles at the bottom. It's built for accessibility
(dyslexia, low vision, fatigue) and for reading faster.

It works on **any** pixels: web pages, PDFs, images, videos, slides, apps that block copy/paste,
because it reads the screen itself with on-device OCR. Nothing leaves your Mac.

## Use

| Shortcut | Action |
|---|---|
| **⌃⌥R** | Read from the word under the pointer (press again to stop) |
| **⌃⌥P** | Pause / resume |
| **⌃⌥F** | Follow-mouse mode: rest the pointer on any text and it starts reading there |
| **Esc** | Stop (only while reading) |

Menu bar icon → speed (0.8×–2×), voice, toggles for subtitles / on-screen highlight /
continue to the next paragraph.

**Better voices:** System Settings ▸ Accessibility ▸ Spoken Content ▸ System Voice ▸ Manage
Voices, then download an *Enhanced* or *Premium* voice. In "Auto" mode, Narrate picks the best
installed voice for each paragraph's detected language (so French text gets a French voice).

## Build & run

```bash
scripts/build-app.sh --open      # builds dist/Narrate.app and launches it
.build/debug/Narrate --selftest  # OCR + layout + realign pipeline test (no permissions needed)
```

On first launch, allow **Screen Recording** for Narrate, then relaunch. Builds are ad-hoc signed,
so macOS may ask again after a rebuild. To avoid that, set `NARRATE_SIGN_IDENTITY` to a real
signing identity.

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

| File | Role |
|---|---|
| `TextCapture.swift` | Screen capture + Vision OCR → words with screen rects |
| `Layout.swift` | Paragraph grouping, pointer hit-testing, next block, scroll re-alignment |
| `Speaker.swift` | TTS, word callbacks, voice/language selection |
| `HighlightOverlay.swift` | On-screen word highlight |
| `SubtitleBar.swift` | Karaoke captions |
| `ReaderController.swift` | Orchestration, follow-mouse, scroll re-sync |

## Roadmap

- [ ] **"Explain / summarise" mode (Claude):** speak a short summary of the paragraph and highlight
      the exact source words each point comes from
- [ ] Accessibility-API text path for native apps (exact text, no OCR errors), with OCR as fallback
- [ ] Neural voices (ElevenLabs / OpenAI TTS with word timestamps) as an option
- [ ] Bionic-reading / focus dimming: fade everything except the current line
- [ ] Draggable subtitle bar, font size settings, Settings window
- [ ] Multi-column pages and tables: smarter reading order
