# VoiceCue

> A small, private macOS voice shortcut for opening or closing your coding assistant hands-free.

VoiceCue listens for **“Codex”** or **“Hey Codex”** and sends **Control–Shift–V** to the frontmost app. It is designed for one job: turning a keyboard shortcut into a dependable wake phrase.

## What it does

| VoiceCue listens for | VoiceCue does |
| --- | --- |
| `Codex` or `Hey Codex` | Sends `Control–Shift–V` once |
| Common sound-alikes, such as `Kodak` or `codec` | Treats them as `Codex` |

- Live microphone level meter, so you can see audio is reaching the app.
- A compact “Heard” readout showing the last two recognized words.
- One activation per spoken phrase—no repeated toggles from partial transcripts.
- A full-height, chronological terminal conversation view: your spoken command, then Codex’s live turn state and spoken reply when macOS can transcribe the system-audio response.
- No account, no VoiceCue history files, no stored recordings, and no stored transcripts.

## Install

Copy this into Terminal:

```bash
git clone https://github.com/lucka643/voicecue.git && cd voicecue && ./install.sh
```

The installer builds VoiceCue, places the app in Applications, and adds the `voicecue` command to your local command path.

> If Terminal cannot find `voicecue` afterward, close and reopen Terminal once.

## Use

Start the listener:

```bash
voicecue
```

On the first run, allow VoiceCue to use:

1. **Microphone** — to hear the wake phrase.
2. **Speech Recognition** — to recognize it.
3. **Accessibility** — to send the keyboard shortcut to your active app.

When you first use a wake phrase after this update, macOS may also ask for **Screen Recording**. VoiceCue uses that permission only for a short, sixty-second system-audio window after a wake phrase, so it can tell when Codex starts and stops speaking and can transcribe its spoken reply. It does not save that audio or the resulting text anywhere.

Press `Control-C` whenever you want to stop VoiceCue.

## Keep it current

```bash
voicecue update
```

This gets the newest version from this repository, rebuilds it, and reinstalls it.

The installer removes its temporary Swift build cache after a successful install to keep the clone small. Set `VOICECUE_KEEP_BUILD_CACHE=1` only if you are actively developing VoiceCue and want faster rebuilds.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools: `xcode-select --install`

## Privacy

VoiceCue creates no account or history database, and it does not write recordings or transcripts to disk. Your terminal may retain its own scrollback, which you control. Speech recognition is supplied by macOS and may use Apple’s speech service depending on system settings. The default app does not inspect the screen or run system-audio capture until you ask it to wake Codex.

## Development

```bash
./script/build_and_run.sh
```

## License

[MIT](LICENSE)
