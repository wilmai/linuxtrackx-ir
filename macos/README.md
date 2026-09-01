# Native macOS TrackIR bring-up

This directory contains the native userspace bring-up for TIR5V2. It uses
Apple’s `IOUSBHost` framework from a normal command-line process and remains
separate from the probe’s command-line build while also supplying the native
`libltusb1` backend used by the macOS CMake server build.

## Target

- `TrackIRUserSpaceProbe`: matches the TIR5V2 interface, opens it, reads the
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
--exercise          run a bounded descriptor read and TrackIR status transfer
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

The probe currently matches only VID `0x131D`, PID `0x0158`, configuration `1`,
interface `0`, and alternate setting `0`. Endpoint addresses are read from
the descriptors rather than hard-coded. `--exercise` performs one standard
device-descriptor control read, drains pending input, sends the existing
`0x17` configuration request followed by the `0x1d` status request, and reads
at most 64 bytes from the discovered bulk IN endpoint with a 500 ms timeout.
It first sends the TIR5V2 stop/LED-off preamble and does not load firmware or
start the camera.

## Validation

The attached TIR5V2 has been matched and opened through `IOUSBHost` using
`DeviceCapture`. The observed interface has two bulk endpoints: OUT `0x01`
and IN `0x82`, both with 64-byte maximum packets. The bounded diagnostic also
completed the control read and protocol transfers, receiving a 20-byte
configuration response and the 7-byte status response
`07 20 01 01 00 00 02`.
