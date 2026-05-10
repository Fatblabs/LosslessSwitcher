# LATEST RELEASE: https://github.com/Fatblabs/LosslessSwitcher/releases/tag/v1.1.0

# LosslessSwitcher

A macOS utility that automatically matches your system output device to the sample rate and bit depth of the audio currently playing in Apple Music.

LosslessSwitcher is designed for listeners using external DACs, audio interfaces, or hi-res-capable output devices. Instead of manually opening **Audio MIDI Setup** every time a track changes from 44.1 kHz to 96 kHz, 192 kHz, or another supported rate, the app detects the playback format and switches the default output device automatically when possible.

> Example: Apple Music starts playing a 24-bit / 96 kHz track while your DAC is currently set to 16-bit / 44.1 kHz. LosslessSwitcher detects the source format and switches the DAC output to 96 kHz with the selected bit-depth behavior.

This project was inspired by the idea and functionality of [vincentneo/LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher), with custom implementation details around live Console log monitoring, CoreAudio device control, Apple Music metadata detection, and a SwiftUI interface.

---
## Security

LosslessSwitcher releases include automated VirusTotal scanning during the release process to help improve user safety and peace of mind.

Release builds are automatically checked before distribution so users can verify downloaded builds with greater confidence.

## Download

The recommended way to install LosslessSwitcher is from the GitHub **Releases** page.

1. Open the repository on GitHub.
2. Click **Releases** on the right side of the repository page.
3. Download the latest release asset.
4. Open the downloaded app or archive.
5. Move **LosslessSwitcher.app** to your **Applications** folder.
6. Launch the app and allow any required macOS permissions.

If macOS blocks the app because it is from an unidentified developer:

1. Open **System Settings**.
2. Go to **Privacy & Security**.
3. Scroll to the security warning for LosslessSwitcher.
4. Click **Open Anyway**.

Developers can also build the project from source using Xcode. See **Build from Source** below.

---

## Features

- **Automatic sample-rate switching**
  - Detects the currently playing Apple Music track.
  - Switches the default macOS output device to the detected sample rate when supported.

- **Bit-depth preference control**
  - Preserve detected bit depth when available.
  - Or force 16-bit, 24-bit, or 32-bit output when supported by the device.

- **Live CoreAudio format detection**
  - Monitors Apple Music, CoreAudio, and CoreMedia log output for real playback format information.
  - Useful for Apple Music streaming tracks where metadata alone may be unreliable.

- **Manual sample-rate switching**
  - Shows supported sample-rate modes for the current default output device.
  - Allows one-click manual switching.

- **Menu bar mode**
  - Optional menu bar item.
  - Optional menu-bar-only mode.
  - Quick access to Auto mode, Match Now, current source, current output format, and settings.

- **Launch at login**
  - Optional login item support.

- **Track format cache**
  - Remembers reliable detected formats for previously played songs.
  - Cached song formats persist across app restarts.
  - Includes an option to clear remembered song formats.

- **Activity log**
  - Shows recent detections, switches, unsupported rates, and error messages.

---

## How It Works

LosslessSwitcher combines three detection paths:

1. **Apple Music metadata detection**
   - Uses AppleScript automation to read the current Apple Music player state, track name, artist, album, kind, cloud status, persistent ID, sample rate, and bit rate.

2. **Live Console format detection**
   - Runs macOS `log stream` with predicates for:
     - `com.apple.Music`
     - `com.apple.coreaudio`
     - `com.apple.coremedia`
   - Parses recent decoder and AudioQueue messages to detect the actual sample rate and bit depth being used by Apple Music/CoreAudio.

3. **CoreAudio output switching**
   - Reads the current default output device.
   - Reads supported nominal sample-rate ranges.
   - Applies the target sample rate using CoreAudio.
   - Attempts to select the best matching physical output format for the preferred bit depth when available.

---

## Supported Sample Rates

The app can display and switch to rates reported by the current default output device. It also checks common hi-res sample rates, including:

- 44.1 kHz
- 48 kHz
- 88.2 kHz
- 96 kHz
- 176.4 kHz
- 192 kHz
- 352.8 kHz
- 384 kHz
- 705.6 kHz
- 768 kHz

Actual support depends on your DAC, audio interface, or output device.

---

## Requirements

- macOS with SwiftUI menu bar app support
- Apple Music app
- A DAC, audio interface, or output device with multiple supported sample rates
- Apple Music Automation permission
- Console log access may be required for the most accurate live stream format detection
- Xcode, only if building from source

Because the app uses AppleScript automation and system audio APIs, permissions may be requested by macOS the first time the app tries to read Apple Music or monitor audio behavior.

---

## Permissions

### Apple Music Automation

LosslessSwitcher needs permission to control/read Apple Music metadata.

If detection fails with an automation permission error:

1. Open **System Settings**
2. Go to **Privacy & Security**
3. Open **Automation**
4. Find **LosslessSwitcher**
5. Enable access to **Music**

### Console / Log Access

The live format monitor uses `/usr/bin/log stream` to read relevant Apple Music/CoreAudio/CoreMedia messages. Depending on your macOS privacy settings, the app may need additional permission to access log data.

---

## Usage

1. Connect your DAC or audio interface.
2. Set it as the default macOS output device.
3. Open LosslessSwitcher.
4. Enable **Auto**.
5. Play a track in Apple Music.
6. The app will detect the source format and switch the output device when the target format is supported.

For manual control, use the **Manual Rate** section to switch to any supported rate reported by the current default output device.

---

## Build from Source

For normal users, download the latest app from the **Releases** tab instead. These steps are for developers who want to build the project manually.

1. Clone the repository:

   ```bash
   git clone https://github.com/YOUR_USERNAME/YOUR_REPOSITORY_NAME.git
   cd YOUR_REPOSITORY_NAME
   ```

2. Open the project in Xcode.

3. Select the **LosslessSwitcher** scheme.

4. Build and run:

   ```bash
   Command + R
   ```

5. Start playing music in Apple Music.

6. Click **Request Music Access** or **Match Now** if the app does not detect the current track immediately.

---

## Interface Overview

### Main Window

The main window includes:

- **Source**
  - Current track title
  - Artist
  - Detected sample rate / bit depth
  - Format source, such as Music metadata, CoreAudio decoder, CoreMedia AudioQueue, or cached format

- **Output**
  - Current default output device
  - Current device sample rate / bit depth
  - Number of reported sample-rate modes
  - Bit-depth preference selector

- **Manual Rate**
  - One-click buttons for supported sample rates

- **Settings**
  - Show Menu Bar Item
  - Menu Bar Only
  - Launch at Login
  - Remembered song count
  - Clear Song Memory

- **Activity**
  - Recent detection and switching events

### Menu Bar

The menu bar window provides quick access to:

- Auto mode toggle
- Current source format
- Current output device format
- Bit-depth preference
- Match Now
- Main window
- Settings
- Quit

---

## Project Structure

```text
LosslessSwitcher/
├── AudioModels.swift
├── ConsoleAudioFormatDetector.swift
├── ContentView.swift
├── CoreAudioDeviceManager.swift
├── LiveConsoleAudioFormatMonitor.swift
├── LosslessSwitcher.entitlements
├── LosslessSwitcherApp.swift
├── LosslessSwitcherController.swift
├── MusicSourceDetector.swift
└── TrackFormatCache.swift
```

### Key Files

| File | Purpose |
| --- | --- |
| `LosslessSwitcherApp.swift` | App entry point, menu bar item, settings scene, and main window presentation. |
| `LosslessSwitcherController.swift` | Main app state, detection loop, auto-switch logic, settings, launch-at-login support, and logging. |
| `CoreAudioDeviceManager.swift` | Reads CoreAudio output devices, supported sample rates, current bit depth, and applies sample-rate / physical-format changes. |
| `MusicSourceDetector.swift` | Uses AppleScript to detect Apple Music playback metadata and sample-rate information. |
| `ConsoleAudioFormatDetector.swift` | Parses recent macOS Console entries for CoreAudio/CoreMedia/Music format messages. |
| `LiveConsoleAudioFormatMonitor.swift` | Streams live Console output and reports newly detected audio formats. |
| `ContentView.swift` | SwiftUI main window, settings UI, activity log, and menu bar interface. |
| `TrackFormatCache.swift` | Saves reliable detected song formats to Application Support for reuse across app launches. |
| `AudioModels.swift` | Shared models and formatting helpers for devices, sources, sample rates, bit-depth preferences, and logs. |

---

## Notes and Limitations

- The app currently focuses on **Apple Music**.
- Sample-rate switching only works when the default output device reports support for the target rate.
- Some streaming tracks may not expose reliable sample-rate metadata immediately; in those cases, the app waits for CoreAudio decoder information.
- Bit-depth switching depends on the physical formats exposed by the output stream.
- macOS, Apple Music, and CoreAudio logging behavior may change over time.
- The app does not improve the quality of the source audio; it only attempts to align the output device format with the detected playback format.

---

## Troubleshooting

### Music is not detected

- Make sure Apple Music is open.
- Start playback.
- Click **Request Music Access**.
- Check **System Settings > Privacy & Security > Automation** and allow LosslessSwitcher to access Music.

### Output device does not switch

- Confirm the DAC or audio interface is the default output device.
- Confirm the device supports the target sample rate.
- Try clicking **Refresh Devices**.
- Try using **Manual Rate** to confirm that CoreAudio allows switching.

### Unsupported rate message

The detected source sample rate is not reported as supported by the current output device. Choose a different output device or use a DAC that supports that rate.

### Bit depth does not change

Not all devices expose settable physical formats. The app will still attempt to switch sample rate, but bit-depth behavior depends on the device driver and CoreAudio-reported formats.

---

## Inspiration and Credits

Inspired by [vincentneo/LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher).

This implementation is built as a SwiftUI macOS app using Apple Music automation, CoreAudio device APIs, live Console log parsing, and local track-format caching.

---

## Disclaimer

This project is experimental audio utility software. Use it at your own risk. Audio device switching behavior depends on macOS, Apple Music, CoreAudio, and your specific DAC or audio interface.
