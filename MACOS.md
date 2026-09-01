# macOS TrackIR support plan

Status: planning

This document defines the plan to restart native macOS development in
LinuxTrack X-IR. The macOS implementation must use Apple's USBDriverKit
framework. It must not depend on the NaturalPoint SDK, the Windows driver, a
Wine bridge, or a kernel extension.

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
GCC-specific compiler flags. These must be separated from the USBDriverKit
work instead of being treated as working macOS support.

The existing product-ID list is a starting point only. The DriverKit match
configuration and endpoint map must be confirmed against descriptors captured
from the actual TrackIR 5 v2 device before the first driver release.

## Target architecture

```text
TrackIR USB device
        |
        v
TrackIRDriver.dext                 macOS system extension
  USBDriverKit matching/claiming
  IOUSBHostInterface / IOUSBHostPipe
  control and bulk transfers
  reset and disconnect handling
        |
        v
macOS user-client transport shim      host process/library
        |
        v
existing TrackIR protocol engine
  tir_hw.c + image processing + pose computation
        |
        v
liblinuxtrack C API -> native macOS applications
```

### DriverKit extension

Create a dedicated DriverKit system extension, tentatively named
`TrackIRDriver.dext`.

The extension will:

1. Match only the supported NaturalPoint VID/PID combinations.
2. Open the matched `IOUSBHostInterface` and obtain pipes from the endpoint
   descriptors.
3. Expose a narrow, versioned `IOUserClient` interface to the signed host
   component.
4. Perform validated control, bulk-write, and bulk-read operations.
5. Handle USB reset, stop, disconnect, and re-enumeration safely.
6. Keep all DriverKit-specific code inside the macOS driver target.

The first bring-up path should use synchronous operations where that makes
debugging easier. Frame acquisition should then move to asynchronous USB I/O
and a bounded queue or equivalent notification mechanism so the host does not
poll inefficiently.

Apple documents `IOUSBHostInterface` as the provider for a custom USB
function driver and `IOUSBHostPipe` as the object for bulk and interrupt I/O:

- [USBDriverKit](https://developer.apple.com/documentation/usbdriverkit)
- [IOUSBHostInterface](https://developer.apple.com/documentation/usbdriverkit/iousbhostinterface)
- [IOUSBHostPipe](https://developer.apple.com/documentation/usbdriverkit/iousbhostpipe)

### Host transport shim

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
backend that calls the DriverKit user client through the macOS I/O Kit client
APIs. Do not duplicate TrackIR initialization or frame decoding in the
DriverKit extension.

The macOS transport should use fixed-width, versioned request and response
structures. Every user-client method must validate selector numbers, buffer
sizes, endpoint addresses, transfer lengths, and timeout values. Avoid an
unrestricted "execute arbitrary USB request" interface in the production
build.

Apple's `IOUserClient` model uses `IOServiceOpen` and typed external methods
for communication between the host and the driver:

- [IOUserClient](https://developer.apple.com/documentation/driverkit/iouserclient)
- [ExternalMethod](https://developer.apple.com/documentation/driverkit/iouserclient/externalmethod)
- [Communicating between a DriverKit extension and a client app](https://developer.apple.com/documentation/driverkit/communicating-between-a-driverkit-extension-and-a-client-app)

## USB and TrackIR protocol work

### Device matching

Start with TIR5V2 (`0x131D:0x0158`) and add TIR5V3 (`0x131D:0x0159`) after
TIR5V2 is stable. Retain the older IDs in the design, but do not add them to
the DriverKit match entitlement until each one has a tested protocol path.

Capture and record, for each model:

- device, configuration, interface, and endpoint descriptors;
- interface number and alternate settings;
- endpoint direction, transfer type, maximum packet size, and polling data;
- device state before and after firmware upload;
- the product ID after any firmware-triggered re-enumeration.

Do not rely on the current hard-coded endpoint constants until the descriptor
capture confirms them. Preserve the existing TrackIR command sequence from
`tir_hw.c`, including status, FPGA initialization, configuration reload,
video control, IR brightness, and frame acquisition.

### Firmware

The host side will:

1. Locate the user-provided firmware directory.
2. Decompress and validate the selected firmware with zlib.
3. Send bounded chunks through the macOS transport.
4. Wait for and verify the device's status response.
5. Re-discover the device if firmware causes USB re-enumeration.

The DriverKit extension must not read arbitrary firmware paths. It receives
validated transfer data from the host through the user client. Firmware files
remain local user assets and are never embedded in the source tree or release
binary.

The native extractor should be made a supported macOS build target once the
host configuration path is defined. Extraction must remain independent of the
DriverKit extension and must not execute the TrackIR installer.

## macOS project and build layout

Use a dedicated `macos/` project for DriverKit and system-extension packaging.
The initial layout should be:

```text
macos/
  TrackIRDriver/             DriverKit C++ target and Info.plist
  TrackIRHost/               host-side activation/user-client code
  entitlements/              development and distribution entitlements
  tests/                     descriptor, transport, and protocol tests
```

Use Xcode's DriverKit target model for the `.dext`, because signing,
provisioning, system-extension packaging, and DriverKit SDK selection are
first-class Xcode workflows. Keep the reusable C protocol and pose code in
the normal source tree, with a small macOS adapter target exposing a C ABI to
that code.

The existing top-level CMake project should gain a macOS host configuration
only after the standalone DriverKit bring-up succeeds. The first CMake port
should:

- remove Linux-only sources from macOS targets;
- replace hard-coded `dl`, `pthread`, and compiler flags with portable CMake
  variables or platform-specific options;
- add `arm64` architecture handling;
- avoid building Linux uinput, joystick, udev, and Wine components on macOS;
- keep `libusb_ifc.c` Linux-only;
- build the native extractor on macOS with the same minimal dependencies.

## Signing, entitlements, and installation

The DriverKit extension cannot be treated like an ordinary shared library.
Plan for the following from the start:

- Driver entitlement on the extension:
  `com.apple.developer.driverkit`.
- USB transport entitlement on the extension:
  `com.apple.developer.driverkit.transport.usb`.
- System-extension installation capability on the host app.
- Restricted user-client access using
  `com.apple.developer.driverkit.userclient-access`.
- Development and distribution provisioning profiles for the app and the
  extension.
- Code signing and notarization for release artifacts.

The USB transport entitlement must identify the supported hardware. The
bundle identifiers and entitlement values must be chosen before requesting
Apple approval. Do not use `allow-any-userclient-access` in a release build.

Apple's requirements are described in:

- [Requesting Entitlements for DriverKit Development](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development)
- [Installing System Extensions and Drivers](https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers)
- [System Extensions and DriverKit](https://developer.apple.com/system-extensions/)
- [Debugging and testing system extensions](https://developer.apple.com/documentation/driverkit/debugging-and-testing-system-extensions)

Package the extension inside the host application's
`Contents/Library/SystemExtensions` directory. The host app will activate it
through `OSSystemExtensionManager`, report approval or failure clearly, and
provide a diagnostic command using `systemextensionsctl list`.

Open-source distribution needs a separate signing decision: source remains
MIT-licensed, but users building the DriverKit target may need their own Apple
developer identity, provisioning profile, and granted entitlements. Record
the supported development and release-signing paths before publishing a
binary.

## Configuration and API integration

The public LinuxTrack API should remain platform-neutral. A native macOS
client should be able to:

1. Initialize LinuxTrack.
2. Auto-detect the DriverKit-backed TrackIR device.
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

### Phase 0: hardware and entitlement inventory

- [ ] Obtain a Mac for testing, with both Intel and Apple Silicon coverage if
      possible.
- [ ] Record the exact macOS versions and Xcode/SDK versions to support.
- [ ] Capture TIR5V2 USB descriptors and LinuxTrack USB traces.
- [ ] Confirm the observed TIR5V2 and TIR5V3 product IDs.
- [ ] Choose bundle identifiers and request DriverKit entitlements.
- [ ] Decide the signed-binary distribution model.

### Phase 1: isolate the portable protocol

- [ ] Define the platform-neutral USB transport interface.
- [ ] Adapt `tir_hw.c` to that interface without changing TrackIR packet
      semantics.
- [ ] Keep Linux `libusb` behavior unchanged.
- [ ] Add tests for packet construction, checksum, status parsing, and frame
      decoding using captured data.

### Phase 2: DriverKit skeleton

- [ ] Create the signed `TrackIRDriver.dext` target.
- [ ] Match only `0x131D:0x0158` initially.
- [ ] Open the correct USB interface and enumerate descriptors.
- [ ] Implement start/stop, disconnect, reset, and diagnostic logging.
- [ ] Add a minimal user client with versioned capabilities and error codes.
- [ ] Prove that the extension can be installed, activated, and removed.

### Phase 3: USB transport

- [ ] Implement control transfers.
- [ ] Implement bulk writes and bounded bulk reads.
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

- [ ] Add the macOS backend to device auto-detection.
- [ ] Build the native extractor and shared configuration path on macOS.
- [ ] Add a minimal macOS diagnostic host.
- [ ] Integrate the existing GUI/server only after the diagnostic host is
      stable.
- [ ] Document installation, approval, firmware extraction, and recovery.

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

- A clean macOS install can activate the DriverKit extension after the normal
  user approval flow.
- TIR5V2 is detected as `0x131D:0x0158` without `libusb` or vendor software.
- The device can be initialized using locally extracted firmware.
- Raw frames and poses are produced at the expected rate and match the Linux
  backend within defined tolerances.
- Disconnect, reconnect, reset, pause, resume, and recenter are handled
  without restarting the host application.
- The public LinuxTrack API works for a native macOS client.
- No Wine bridge, NPClient, NaturalPoint SDK, `TIRViews.dll`, or KEXT is
  required.
- The build and signing process is documented for both development and
  release use.

## Main risks

1. **Apple entitlement and signing requirements.** This is the largest
   distribution risk for an open-source project. Source publication and
   binary distribution must be documented as separate concerns.
2. **DriverKit user-client design.** An unsafe or unstable ABI could expose
   arbitrary USB operations or break when the host app updates. Keep the
   interface small, typed, versioned, and capability-based.
3. **Firmware re-enumeration.** TrackIR may change state or product ID during
   initialization. Treat every reset and re-enumeration as a normal state
   transition.
4. **Unverified v2/v3 equivalence.** Share code only after packet and
   descriptor comparison; keep model-specific tables available.
5. **Old portability assumptions.** The existing macOS files are historical
   support, not proof that the current Qt6/CMake tree builds or runs on modern
   macOS.
6. **Limited hardware test coverage.** A Linux-only development machine
   cannot validate DriverKit activation, USB ownership, signing, or actual
   frame delivery. Mac hardware testing is required for each milestone after
   the skeleton.

## Initial implementation decision

The first implementation should be a narrow TIR5V2 DriverKit transport plus a
small diagnostic host. It should reuse the existing TrackIR protocol engine,
keep all vendor-independent USB logic in the new platform abstraction, and
delay GUI, TIR5V3, and packaging polish until real TIR5V2 frames are flowing
on macOS.
