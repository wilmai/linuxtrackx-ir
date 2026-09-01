# Native macOS TrackIR bring-up

This directory contains the native userspace bring-up for TIR5V2 and TIR5V3. It uses
Apple’s `IOUSBHost` framework from a normal command-line process and remains
separate from the probe’s command-line build while also supplying the native
`libltusb1` backend used by the macOS CMake server build.

## Target

- `TrackIRUserSpaceProbe`: matches a TIR5V3 or TIR5V2 interface, opens it, reads the
  USB descriptors, creates pipes for its endpoints, and can exercise the
  first bounded control/bulk transfers. `TrackIRUSBTransport` owns the
  captured interface and pipes for the lifetime of the open context.
- `ltr_server1`: the normal LinuxTrack server now reaches the same IOUSBHost
  transport through `libtir` -> `libltusb1`; clients continue to consume
  poses through the public LinuxTrack API.

Open `LinuxTrackXIR.xcodeproj` in Xcode and build the
`TrackIRUserSpaceProbe` target, or follow
[`TrackIRUserSpace/README.md`](TrackIRUserSpace/README.md) for a command-line
build.

The probe accepts:

```text
          default   request ordinary exclusive ownership
--seize             ask the current owner to close voluntarily
--capture           forcibly terminate existing USB clients and drivers
--exercise          run the bounded descriptor/transfer diagnostic
```

The server first requests ordinary IOUSBHost ownership. If the matched
interface cannot be opened, it retries with `DeviceCapture`. If capture cannot
be authorized for the current user, the server logs an instruction to rerun
`ltr_server1` with `sudo`; no capture is attempted when no TrackIR device is
present.

`--capture` is intended for controlled diagnostics. It requires root
privileges, or the `com.apple.vm.device-access` entitlement together with
device authorization. Releasing the captured object resets the device and
allows normal matching to resume.

The probe matches VID `0x131D`, either TIR5V3 PID `0x0159` or TIR5V2 PID
`0x0158` (v3 preferred), configuration `1`, interface `0`, and alternate
setting `0`. Endpoint addresses are read from the descriptors rather than
hard-coded. `--exercise` performs one standard device-descriptor control read.
For TIR5V2 it also drains pending input, sends the existing `0x17`
configuration request followed by the `0x1d` status request, and reads at most
64 bytes from the discovered bulk IN endpoint with a 500 ms timeout. It first
sends the TIR5V2 stop/LED-off preamble and does not load firmware or start the
camera. TIR5V3 uses randomized 24-byte commands, so its probe exercise stops
after the descriptor/control check; the production server uses the shared
LinuxTrack TIR5V3 protocol implementation.

## Validation

The attached TIR5V2 has been matched and opened through `IOUSBHost` using
`DeviceCapture`. The observed interface has two bulk endpoints: OUT `0x01`
and IN `0x82`, both with 64-byte maximum packets. The bounded diagnostic also
completed the control read and protocol transfers, receiving a 20-byte
configuration response and the 7-byte status response
`07 20 01 01 00 00 02`.

TIR5V3 matching and the existing LinuxTrack protocol path are implemented,
but TIR5V3 descriptor, initialization, and frame behavior remain unverified
until hardware is available.

## Install with Homebrew

The repository includes a Homebrew formula at
`Formula/linuxtrackx-ir.rb`. It builds the native macOS Qt GUI, the
IOUSBHost-backed `ltr_server1`, the LinuxTrack libraries, and the command-line
helpers directly into Homebrew's prefix. No `.app` bundle or code-signing
identity is required.

Because this source repository is not named `homebrew-*`, add it as a tap with
its explicit Git URL:

```sh
brew tap wilmai/linuxtrackx-ir https://github.com/wilmai/linuxtrackx-ir.git
brew install wilmai/linuxtrackx-ir/linuxtrackx-ir
```

The formula pins normal installs to the current `mac` revision. To build the
latest commit from that branch instead, use:

```sh
brew install --HEAD wilmai/linuxtrackx-ir/linuxtrackx-ir
```

After installation, run `ltr_gui` for the GUI or `ltr_server1` for the
background tracking server. If IOUSBHost needs `DeviceCapture`, run the server
with `sudo` as described above.
