# IOUSBHost userspace probe

This command-line tool uses Apple’s `IOUSBHost` framework from a normal macOS
process to match and open a TIR5V2 or TIR5V3 interface, read its descriptors,
create endpoint pipes, and optionally exercise the first bounded transfers.

Build and run it on macOS with a connected TrackIR 5 device:

```sh
MACOS_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx clang++ -std=gnu++17 -Wall -Wextra -Werror \
  -fobjc-arc -isysroot "$MACOS_SDK_PATH" \
  -Imacos/TrackIRUserSpace \
  macos/TrackIRUserSpace/TrackIRUSBTransport.mm \
  macos/TrackIRUserSpace/TrackIRUserSpaceProbe.mm \
  -framework Foundation -framework IOKit -framework IOUSBHost \
  -o /tmp/linuxtrackx-ir-iousbhost-probe
/tmp/linuxtrackx-ir-iousbhost-probe
```

Use `--seize` only when another owner has the interface and voluntarily
responds to the close request. For a controlled diagnostic, `--capture`
terminates existing clients and drivers and requires root privileges or the
`com.apple.vm.device-access` entitlement plus device authorization:

```sh
sudo /tmp/linuxtrackx-ir-iousbhost-probe --capture
```

Add `--exercise` to issue a standard 18-byte device-descriptor control read.
For TIR5V2 it then sends the stop/LED-off preamble used by LinuxTrack, drains
pending bulk IN data, sends the existing configuration request (`0x17`), and
sends the status request (`0x1d`) to the discovered bulk OUT pipe. Each bulk
IN read is limited to 64 bytes with a 500 ms timeout; empty or unrelated
packets are discarded within a small retry budget:

```sh
sudo /tmp/linuxtrackx-ir-iousbhost-probe --capture --exercise
```

The diagnostic does not load firmware or start the camera. The TIR5V2
exercise turns the camera and its LEDs off first, so use `--capture` for a
controlled run. TIR5V3 commands are randomized 24-byte packets, so the probe
only performs the descriptor/control check for v3 and leaves the full
protocol exercise to the shared LinuxTrack driver. It prints the complete
bounded responses for comparison with captured protocol data.

The default `IOUSBHostObjectInitOptionsNone` path is suitable for an
unsandboxed local development tool. A sandboxed application still needs
`com.apple.security.device.usb`.

## LinuxTrack server integration

The native adapter is built into `libltusb1` on macOS. The existing server
path then owns the device as:

```text
ltr_server1 -> libltr -> libtir -> libltusb1 (IOUSBHost)
```

The server tries ordinary ownership first and automatically retries with
`DeviceCapture` only when a matched interface cannot be opened. If capture is
not authorized, the server advises rerunning `ltr_server1` with `sudo`.
