# VoiceCue

VoiceCue is a deliberately small macOS command-line app. It listens for **“Codex”** or **“Hey Codex”**, then sends **Control–Shift–V** to the frontmost app.

It does nothing else: no network requests, no recordings saved to disk, no background account, and no text processing beyond Apple’s speech-recognition service.

## Install

Copy and paste this into Terminal:

```bash
git clone https://github.com/REPLACE-WITH-YOUR-USERNAME/voicecue.git && cd voicecue && ./install.sh
```

The installer builds VoiceCue, places it in Applications, and adds a `voicecue` command to your user-local bin folder. Restart Terminal after installing if that folder is not already on your PATH.

## Run

```bash
voicecue
```

On first run, macOS will ask for Microphone, Speech Recognition, and Accessibility access. Grant them for VoiceCue. Accessibility is what lets it send the shortcut to the app you are using.

Press Control-C in the terminal to stop it.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install`)

## Privacy

VoiceCue does not save audio or transcripts. Speech recognition is provided by macOS and may use Apple’s speech service depending on your system settings.

## Development

```bash
./script/build_and_run.sh
```

## License

MIT
