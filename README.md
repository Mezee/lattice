# Lattice

Speech for your Mac, powered by [Phonon](https://github.com/gradium-ai/xn-ptts). (A phonon is a quantum of vibration in a lattice.)

Highlight text in any Mac app, press a shortcut, and hear it read aloud by a fast, fully offline neural voice, while a
small floating bar shows the words one at a time, in sync with the voice.

<!-- demo.gif goes here -->

- **Works anywhere.** Select text in any app, press **⌃⌥R**.
- **One word at a time.** The current word sits on a fixed centre line with its focus letter in lime green, in the style of
  [word-reader](https://github.com/ssharples/word-reader). Word changes follow the actual audio, not a guess.
- **Media controls.** Pause, skip back and skip forward by sentence, or stop, from the floating bar. Drag it anywhere; it
  remembers its place.
- **Private and offline.** Speech is generated on your Mac with [Phonon](https://github.com/gradium-ai/xn-ptts). Nothing
  you read leaves your computer.
- **Fast.** Phonon generates speech many times faster than real time on an Apple Silicon Mac, so playback starts almost
  instantly.
- **Fixable pronunciations.** Mac key symbols (⌘ ⇧ ⌥ ⌃ and arrows) are spoken as words, and you can add your own fixes.

## Requirements

- macOS 26 (Tahoe) or later. Word timing uses Apple's on-device speech analyzer, which needs it.
- [Homebrew](https://brew.sh), to install the Phonon speech engine.

## Install

1. Install the speech engine (the voice model downloads the first time you read something):

   ```bash
   brew install gradium-ai/tap/ptts
   ```

2. Get the app, either:
   - **Download** the latest zip from Releases, unzip it, and drag **Lattice** to Applications. The app isn't
     notarized yet, so macOS will block the first launch. Either open **System Settings → Privacy & Security** and
     click **Open Anyway**, or clear the download flag once in Terminal:

     ```bash
     xattr -dr com.apple.quarantine /Applications/Lattice.app
     ```
   - **Build it** (needs the Xcode command line tools):

     ```bash
     git clone https://github.com/Mezee/lattice && cd lattice
     ./build.sh        # installs to ~/Applications
     ```

3. Open the app. A 🔈 icon appears in the menu bar. Allow it under **System Settings → Privacy & Security →
   Accessibility** when asked. It needs this to copy the text you highlight.

To start at login, add it under **System Settings → General → Login Items**.

## Use

| Action | How |
| --- | --- |
| Read the selected text | **⌃⌥R** (change it under 🔈 → Shortcuts…) |
| Stop | Press the shortcut again, or **✕** on the bar |
| Pause / resume | ⏯ on the bar |
| Previous / next sentence | ⏮ / ⏭ on the bar |
| Choose a voice | 🔈 → Voice |
| Change the accent colour | 🔈 → Accent Color… (a sample word shows while you pick) |
| Fix a pronunciation | 🔈 → Edit Pronunciations… |

### Pronunciations

The file opened by **Edit Pronunciations…** takes one fix per line:

```
Nginx = engine X
Gradium = grah dee um
```

Matching ignores case and punctuation around the word. Changes apply from the next read.

## How it works

1. The selection is copied (⌘C is sent, and any text that was on your clipboard is put back) and split into sentences.
2. Each sentence goes through `ptts`; the next one is prepared while the current one plays.
3. Apple's on-device speech analyzer listens to each generated clip and reports when every word starts. Those times
   drive the word display, mapped back to your original text by letter count, so symbols and oddly heard words stay in
   sync.

## Limitations

- English only for now.
- Word display and skipping work per sentence. Very long sentences take a moment to generate.
- Some apps don't allow copying their selection. The app can't read from those.
- Pronunciation of unusual words, code, and symbols can be off. Use the pronunciations file.

## Troubleshooting

- **Nothing happens when I press the shortcut.** Check that Lattice is switched on under Accessibility. If you
  rebuilt the app and it's already listed, remove it and add it again.
- **"Speech engine isn't installed".** Run the `brew install` command above.
- **Debug log.** `defaults write io.github.mezee.lattice debug -bool true`, then relaunch. Output goes to
  `~/Library/Logs/Lattice.log`.

## Credits and licence

MIT, see [LICENSE](LICENSE). Third-party notices, including Phonon and word-reader, are in
[THIRD_PARTY.md](THIRD_PARTY.md). Not affiliated with Gradium.
