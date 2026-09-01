# macOS TrackIR support plan

Status: IOUSBHost userspace capture, pipe creation, and bounded control/bulk
transfers validated against the attached TIR5V2

This document defines the plan for native macOS support in LinuxTrack X-IR.
The macOS implementation uses Apple’s `IOUSBHost` framework from a normal
userspace process. It must not depend on the NaturalPoint SDK, the Windows
driver, a Wine bridge, a kernel extension, or `libusb`.

## Scope

### In scope

- Native macOS support for TrackIR hardware.
- TrackIR 5 v2 as the first hardware target:
  - Vendor ID: `0x131D`.
  - Product ID: `0x0158`.
- TrackIR 5 v3 as the next target:
  - Vendor ID: `0x131D`.
  - Product ID: `0x0159`.
- Reuse of the existing LinuxTrack TrackIR protocol, image processing, and
  pose API where practical.
- Native macOS applications consuming the existing LinuxTrack C API.
- Intel and Apple Silicon Macs.
- Firmware supplied by the user through the native installer extractor. The
  project will not redistribute NaturalPoint firmware.

### Out of scope

- Wine, Proton, NPClient, `TIRViews.dll`, or Windows application support.
- A macOS implementation based on `libusb`.
- A legacy kernel extension (KEXT).
- TrackIR hardware flashing or firmware replacement.
- Assuming that TrackIR 5 v2 and v3 are identical before descriptor and
  protocol testing confirms it.

## Current repository state

The existing TrackIR protocol is split between the hardware/protocol layer and
the Linux USB transport:

- [`src/tir_hw.c`](src/tir_hw.c) contains device initialization, firmware
  loading, control packets, endpoint use, and frame decoding.
- [`src/libusb_ifc.c`](src/libusb_ifc.c) performs USB discovery, interface
  claiming, control transfers, bulk transfers, reset, and cleanup.
- [`src/99-TIR.rules`](src/99-TIR.rules) is Linux-specific permission setup.
- [`src/native_extractor/`](src/native_extractor/) already provides a native
  installer extraction path and produces the complete `tir_firmware` set.

The source tree still has `APPLE`/`DARWIN` conditionals and old macOS camera
and GUI files, but the current CMake build is not a complete modern macOS
build. It contains Linux assumptions such as x86/i386-only architecture
detection, Linux joystick/uinput sources, `dl`/`pthread` link names, and
GCC-specific compiler flags. These must be separated from the macOS USB work
instead of being treated as working macOS support.

The existing product-ID list is a starting point only. The IOUSBHost matching
configuration and endpoint map must be confirmed against descriptors captured
from the actual TrackIR 5 v2 device before protocol integration is complete.

## Target architecture

```text
TrackIR USB device
        |
        v
IOUSBHost userspace transport
  discovery and ownership
  descriptors and endpoint pipes
  control and bulk transfers
  reset and disconnect handling
        |
        v
ltr_server1 -> libtir -> libltusb1 (native macOS adapter)
        |
        v
existing TrackIR protocol engine
  tir_hw.c + image processing + pose computation
        |
        v
liblinuxtrack C API -> native macOS applications
```

## IOUSBHost userspace transport

The macOS transport is a normal host process using the `IOUSBHost` framework.
`IOUSBHostInterface` matches the TIR5V2 interface, establishes ownership,
retrieves descriptors, creates pipes, and performs control/bulk I/O. The
checked-in [`TrackIRUserSpaceProbe`](macos/TrackIRUserSpace/README.md) validates
these operations before the protocol engine is connected.

The default `IOUSBHostObjectInitOptionsNone` mode requests ordinary exclusive
ownership. `--seize` asks an existing owner to close voluntarily. The
diagnostic `--capture` mode can terminate existing USB clients and drivers;
Apple requires root privileges or the `com.apple.vm.device-access` entitlement
and device authorization for that mode. Capture is for controlled bring-up,
not the normal application path.

The first bring-up path should use synchronous operations where that makes
debugging easier. Frame acquisition should then move to asynchronous USB I/O
and a bounded queue or equivalent notification mechanism so the host does not
poll inefficiently.

Apple documents the relevant APIs here:

- [IOUSBHost](https://developer.apple.com/documentation/iousbhost)
- [IOUSBHostInterface](https://developer.apple.com/documentation/iousbhost/iousbhostinterface)
- [IOUSBHostPipe](https://developer.apple.com/documentation/iousbhost/iousbhostpipe)
- [DeviceCapture](https://developer.apple.com/documentation/iousbhost/iousbhostobjectinitoptions/devicecapture)

## Host transport shim

Refactor the current USB calls behind a small platform-neutral transport
interface. The protocol engine should continue to own TrackIR semantics; only
the transport implementation changes by platform.

The transport abstraction should cover at least:

- device discovery and model selection;
- open and close;
- interface/configuration setup;
- control transfer;
- bulk write;
- bulk read or asynchronous frame delivery;
- reset/reopen;
- descriptor and diagnostic information.

Keep the current Linux implementation as the `libusb` backend. Add a macOS
backend that keeps `IOUSBHostDevice`, `IOUSBHostInterface`, and
`IOUSBHostPipe` objects in its private context. Do not duplicate TrackIR
initialization or frame decoding in the USB layer.

The transport should validate endpoint addresses, transfer lengths, timeout
values, and device state before issuing each operation. Avoid an unrestricted
"execute arbitrary USB request" interface in the production build.

## USB and TrackIR protocol work

### Device matching

Start with TIR5V2 (`0x131D:0x0158`) and add TIR5V3 (`0x131D:0x0159`) after
TIR5V2 is stable. Match the interface and configuration as well as the device
identity so that unrelated interfaces cannot be claimed.

Capture and record, for each model:

- device, configuration, interface, and endpoint descriptors;
- interface number and alternate settings;
- endpoint direction, transfer type, maximum packet size, and polling data;
- device state before and after firmware upload;
- the product ID after any firmware-triggered re-enumeration.

Do not rely on hard-coded endpoint constants until descriptor capture confirms
them. Preserve the existing TrackIR command sequence from `tir_hw.c`,
including status, FPGA initialization, configuration reload, video control, IR
brightness, and frame acquisition.

### Firmware

The host side will:

1. Locate the user-provided firmware directory.
2. Decompress and validate the selected firmware with zlib.
3. Send bounded chunks through the macOS transport.
4. Wait for and verify the device's status response.
5. Re-discover the device if firmware causes USB re-enumeration.

The USB transport must not read arbitrary firmware paths. It receives
validated transfer data from the host-side protocol engine. Firmware files
remain local user assets and are never embedded in the source tree or release
binary.

The native extractor should be made a supported macOS build target once the
host configuration path is defined. Extraction must remain independent of the
USB transport and must not execute the TrackIR installer.

## macOS project and build layout

Use a dedicated `macos/` project for the IOUSBHost userspace probe and future
macOS transport tests:

```text
macos/
  LinuxTrackXIR.xcodeproj/    IOUSBHost probe target
  TrackIRUserSpace/           probe source and USB identity definitions
```

The Xcode project contains one `TrackIRUserSpaceProbe` command-line target and
links `Foundation`, `IOKit`, and `IOUSBHost`. The standalone command-line
build in [`macos/TrackIRUserSpace/README.md`](macos/TrackIRUserSpace/README.md)
is the reference build until the main CMake port is ready.

The existing top-level CMake project should gain a macOS host configuration
only after the standalone userspace bring-up succeeds. The first CMake port
should:

- remove Linux-only sources from macOS targets;
- replace hard-coded `dl`, `pthread`, and compiler flags with portable CMake
  variables or platform-specific options;
- add `arm64` architecture handling;
- avoid building Linux uinput, joystick, udev, and Wine components on macOS;
- keep `libusb_ifc.c` Linux-only;
- build the native extractor on macOS with the same minimal dependencies.

## macOS access and distribution

An unsandboxed local development tool can use ordinary IOUSBHost ownership
without a special transport entitlement. A sandboxed application needs
`com.apple.security.device.usb` to interact with USB devices.

Controlled device capture requires root privileges, or
`com.apple.vm.device-access` together with successful device authorization.
The application must explain that capture terminates other USB clients and
that releasing the captured object resets the device.

Normal application signing, packaging, and notarization remain separate
distribution concerns and should be documented once the host application
exists.

## Configuration and API integration

The public LinuxTrack API should remain platform-neutral. A native macOS
client should be able to:

1. Initialize LinuxTrack.
2. Auto-detect the IOUSBHost-backed TrackIR device.
3. Receive the same pose units and axis semantics as Linux.
4. Pause, resume, and recenter.
5. Shut down cleanly when the device is unplugged.

Define the macOS configuration directory deliberately. Prefer the normal
macOS application-support location, with a migration/read-only fallback for
the existing LinuxTrack configuration if practical. The path must be shared
by the GUI, server, extractor, and protocol engine so that firmware discovery
does not depend on the launching application.

The first macOS client can be a small diagnostic host rather than the full
GUI. It should print device model, firmware availability, USB state, frame
rate, and pose values before GUI integration begins.

## Implementation phases

### Phase 0: hardware and application inventory

- [ ] Record the exact macOS versions and Xcode/SDK versions to support.
- [x] Confirm the observed TIR5V2 product ID and interface identity.
- [x] Capture the TIR5V2 descriptor and endpoint map from the connected device.
- [ ] Capture LinuxTrack USB traces for protocol comparison.
- [ ] Confirm the TIR5V3 product ID and descriptors.
- [ ] Decide the normal-app distribution/signing model.

### Phase 1: isolate the portable protocol

- [x] Define the platform-neutral USB transport interface.
- [x] Adapt `tir_hw.c` to that interface without changing TrackIR packet
  semantics.
- [x] Keep Linux `libusb` behavior unchanged.
- [x] Add tests for packet construction, checksum, status parsing, and frame
  decoding using captured data.

### Phase 2: IOUSBHost userspace bring-up

- [x] Add a normal-process TIR5V2 IOUSBHost probe.
- [x] Compile and run the probe’s no-device path against the macOS SDK.
- [x] Match the real TIR5V2 interface and create pipes through controlled
  `DeviceCapture`.
- [x] Record bulk OUT `0x01` and bulk IN `0x82`, both with 64-byte packets.
- [x] Add a bounded control and bulk transfer diagnostic using captured
  protocol data.
- [x] Run the bounded transfer diagnostic against TIR5V2 and record the
  control/status responses:
  - Device descriptor: 18 bytes, `131d:0158`.
  - Configuration response: 20 bytes, `14 40 03 01 04 dd 67 12 6a 70 23 66
    00 70 72 25 10 07 00 b0`.
  - Status response: 7 bytes, `07 20 01 01 00 00 02`.
- [x] Keep the captured interface and discovered pipes alive in the
  `TrackIRUSBTransport` context until explicit shutdown.
- [x] Connect the validated IOUSBHost path to the platform-neutral transport
  through the `libltusb1` ABI loaded by `libtir` in `ltr_server1`.

### Phase 3: USB transport

- [x] Implement control transfers.
- [x] Implement bulk writes and bounded bulk reads.
- [ ] Add asynchronous frame delivery after synchronous bring-up works.
- [ ] Implement timeout, cancellation, and device re-enumeration handling.
- [ ] Add host-side transport tests and a diagnostic CLI.

### Phase 4: TIR5V2 operation

- [ ] Port the existing initialization sequence through the new transport.
- [ ] Load user-provided `tir5v2.fw.gz` when required.
- [ ] Verify firmware checksum and status responses.
- [ ] Start the camera and receive raw TrackIR frames.
- [ ] Compare decoded blobs and pose values with the Linux backend.
- [ ] Verify pause, resume, recenter, and clean unplug behavior.

### Phase 5: public LinuxTrack integration

- [x] Add the macOS backend to device auto-detection through `ltr_server1`.
- [ ] Build the native extractor and shared configuration path on macOS.
- [ ] Add a minimal macOS diagnostic host.
- [x] Integrate the existing server after the diagnostic host is stable.
- [ ] Integrate the existing GUI after the diagnostic host is stable.
- [ ] Document installation, firmware extraction, and recovery.

### Phase 6: TIR5V3 and release hardening

- [ ] Add `0x131D:0x0159` after TIR5V2 passes the acceptance tests.
- [ ] Compare v2/v3 descriptors, initialization packets, firmware behavior,
  and frame formats.
- [ ] Add only verified model-specific differences.
- [ ] Test Intel and Apple Silicon builds.
- [ ] Sign, notarize, install, update, and uninstall a release package.
- [ ] Publish reproducible source-build instructions and the signing limits.

## Acceptance criteria

The first macOS TrackIR release is complete when all of the following are
true:

- A macOS userspace host can match and retain the TIR5V2 interface through
  IOUSBHost without `libusb`.
- TIR5V2 is detected as `0x131D:0x0158` without vendor software.
- The device can be initialized using locally extracted firmware.
- Raw frames and poses are produced at the expected rate and match the Linux
  backend within defined tolerances.
- Disconnect, reconnect, reset, pause, resume, and recenter are handled
  without restarting the host application.
- The public LinuxTrack API works for a native macOS client.
- No Wine bridge, NPClient, NaturalPoint SDK, `TIRViews.dll`, or KEXT is
  required.
- The normal application access and signing model is documented.

## Main risks

1. **USB ownership and access.** Other clients can retain a device after an
   application exits; ordinary ownership, cooperative seize, and privileged
   capture need clear behavior.
2. **Firmware re-enumeration.** TrackIR may change state or product ID during
   initialization. Treat every reset and re-enumeration as a normal state
   transition.
3. **Unverified v2/v3 equivalence.** Share code only after packet and
   descriptor comparison; keep model-specific tables available.
4. **Old portability assumptions.** The existing macOS files are historical
   support, not proof that the current Qt6/CMake tree builds or runs on modern
   macOS.
5. **Limited transfer test coverage.** Descriptor and pipe creation are
   validated, but protocol transfers and sustained frame delivery still need
   hardware testing.

## Initial implementation decision

The macOS implementation is a narrow TIR5V2 IOUSBHost transport plus a small
diagnostic host. It should reuse the existing TrackIR protocol engine, keep
all vendor-independent USB logic in the new platform abstraction, and delay
GUI, TIR5V3, and packaging polish until real TIR5V2 frames are flowing on
macOS.
