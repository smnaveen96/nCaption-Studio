# nCaption Studio

nCaption Studio is an open-source macOS app and Final Cut Pro workflow extension for transcribing, editing, refining, and exporting captions. It also includes a video-compression workspace for preparing smaller media files without leaving the app.

## Features

- Transcribe audio and video with Apple on-device transcription, Parakeet, or Whisper
- Download and manage local Parakeet and Whisper models from the app
- Import SRT and iTunes Timed Text (`.itt`) captions
- Edit caption text and timing in a native SwiftUI interface
- Automatically split captions by character or word limits
- Refine captions with Apple Intelligence, Anthropic Claude, or OpenAI
- Store third-party API keys securely in the macOS Keychain
- Export standard SRT captions
- Convert captions to timed Final Cut Pro titles using Motion title templates (`.moti`)
- Export FCPXML or send a generated project directly to Final Cut Pro
- Run the caption workflow inside Final Cut Pro as a workflow extension
- Compress video with selectable quality, resolution, format, destination, and audio options

## Requirements

- macOS 15.5 or later
- Xcode 26 or later (recommended for building the project)
- An Apple Silicon Mac is recommended for local speech models
- Final Cut Pro is optional and is required only for the workflow extension and direct-to-Final-Cut export
- Apple on-device transcription and Apple Intelligence features require compatible hardware, language/region support, and macOS 26 or later
- Internet access is required to download speech models and to use Anthropic or OpenAI

## Getting Started

1. Clone the repository:

   ```bash
   git clone https://github.com/YOUR-USERNAME/nCaption-Studio.git
   cd nCaption-Studio
   ```

2. Open `nCaption Studio.xcodeproj` in Xcode.
3. Wait for Xcode to resolve the Swift Package Manager dependencies.
4. Select the **nCaptionStudio** scheme and **My Mac** as the run destination.
5. In **Signing & Capabilities**, select your development team for both `nCaptionStudio` and `nCaptionExtension`. If needed, replace the bundle identifiers and App Group identifier with values owned by your team, keeping the App Group identical across both targets.
6. Build and run with **Product > Run** (`⌘R`).

No Homebrew packages, command-line tools, or separately installed runtimes are required.

### Swift Package Dependencies

Xcode downloads these automatically when the project is opened:

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — version 1.0.0 or later, up to the next major version
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — version 0.12.4 or later, up to the next major version

If dependency resolution does not start automatically, choose **File > Packages > Resolve Package Versions** in Xcode.

## Using nCaption Studio

### Create and edit captions

1. Open or drop an audio/video file, SRT file, ITT file, Final Cut Pro XML project, or Motion title template into the Transcribe workspace.
2. Choose Apple, Parakeet, or Whisper as the transcription engine. Download the selected local model when prompted.
3. Transcribe the media, then review and edit the generated cues.
4. Optionally enable automatic splitting and choose a character or word limit.
5. Export an SRT, or choose a `.moti` template to create timed Final Cut Pro titles.

### AI cleanup

- **Apple:** runs on-device when Apple Intelligence and the required macOS version are available.
- **Claude or OpenAI:** choose a provider, enter your own API key, select a model, and apply a saved cleanup prompt. API usage may incur charges from the selected provider.

Third-party API keys are saved in the macOS Keychain. Caption text sent to Claude or OpenAI is processed under that provider's terms and privacy policy.

### Final Cut Pro workflow extension

Build and run the containing app at least once. Then open Final Cut Pro and launch **nCaption Studio** from the Workflow Extensions menu. The extension embeds the same caption workflow and can generate and open FCPXML directly in Final Cut Pro.

If the extension is not listed, confirm that both targets are signed by the same team, that their App Group capability matches, and then rebuild the app.

### Compress video

Switch to the Compress workspace, select a video, choose the desired quality, resolution, format, destination, and audio settings, and start the export. Enable replacement only when you intentionally want the successfully exported file to replace the source.

## Project Structure

```text
nCaption Studio/       Main SwiftUI macOS application
nCaptionExtension/    Final Cut Pro workflow extension
MotionTitles/          Bundled Motion title templates and previews
```

## Privacy

Local transcription stays on the Mac after the selected model has been downloaded. Apple Intelligence processing is on-device. When Claude or OpenAI is selected, the app sends the caption text and prompt to that provider's API. Do not commit API keys, signing certificates, or provisioning profiles to the repository.

## Contributing

Contributions and bug reports are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow.

## Credits

Created and maintained by Naveen. The project builds on earlier open-source work by Ken Raley.

WhisperKit is maintained by Argmax, and FluidAudio is maintained by FluidInference. Their respective licenses apply to those dependencies.

## License

nCaption Studio is available under the [MIT License](LICENSE).
# nCaption-Studio
