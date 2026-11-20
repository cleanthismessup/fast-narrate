# Fast Narrate

**Point at any text on your Mac and press ⌃⌥R. A soft reading window glides along the lines at
your reading pace, guiding your eyes through the text: on web pages, PDFs, images and apps.**

> **Status:** the visual reader (silent mode) works. A natural, on-device voice is next.

## Features

- **Reads the section you point at.** No need to aim at the exact first word: point anywhere in
  a paragraph and reading starts at its beginning.
- **Read a selection.** Select text, right-click, and choose **Read with Fast Narrate** (directly
  in the menu or under **Services**, depending on the app).
- **A flowing reading window.** A fixed-size window, two or three words wide, moves smoothly
  along each line at reading speed and fades to the next line. People take in several words at
  a glance, so it never stops on single words.
- **Inverted colours with soft edges.** Inside the window the screen's colours are inverted, so
  the words you're on stand out in any app, light mode or dark. Other styles: Marker (yellow),
  Underline, Outline, and Focus (dims everything except the current line).
- **Works on almost anything.** Text is read through macOS Accessibility (exact and instant in
  native apps, Safari, Chrome and Electron apps). Anything else, such as images, scanned PDFs or
  slides, is read with on-device text recognition.
- **Follows scrolling.** The window stays on the text while you scroll.
- **Follow-mouse mode.** Rest the pointer on text to start reading there.

## Shortcuts

| Keys | Action |
|---|---|
| ⌃⌥R | Read from the pointer |
| ⌃⌥P | Pause / resume |
| ⌃⌥S or Esc | Stop |
| ⌃⌥↑ / ⌃⌥↓ | Faster / slower (while reading) |
| ⌃⌥M | Follow-mouse mode on / off |
| ⌃⌥F | Report a visual problem (screenshot + note, saved locally) |

Speed, highlight style and permissions are also in the menu-bar icon.

## Install

Requires macOS 14 or later and the Xcode command-line tools.

```bash
git clone https://github.com/cleanthismessup/fast-narrate.git
cd fast-narrate
./scripts/make-cert.sh   # once: a local signing certificate so permissions survive rebuilds
./scripts/build.sh
open "dist/Fast Narrate.app"
```

Fast Narrate lives in the menu bar (no Dock icon).

## Permissions

Fast Narrate asks for each permission once, the first time it needs it, and never again.

- **Accessibility:** to read text and word positions from apps. This is the main, fast path.
- **Screen Recording (optional):** only to read text that isn't available through
  Accessibility, like images and scanned PDFs. Without it, everything else still works.

## Privacy

Everything runs on your Mac. No text, screenshots or usage data leave your computer. Debug logs
and feedback reports stay in `~/Library/Application Support/FastNarrate/`.

## Development

```bash
swift test                               # layout, timing and motion tests
"dist/Fast Narrate.app/Contents/MacOS/FastNarrate" --render-qa qa-out   # offline render check
```

## Roadmap

1. ~~Visual reader~~ (done)
2. Natural on-device voice, with the window following the spoken words
3. Settings window, launch at login, release builds

Built for accessibility (dyslexia, ADHD, low vision, reading fatigue) and for reading faster.

## License

[MIT](LICENSE)
