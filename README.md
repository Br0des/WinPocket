# WinPocket

[iOS build workflow](.github/workflows/winpocket-ios.yml)

WinPocket is an iPhone and iPad app for installing Windows in a QEMU virtual machine. It is an independent community fork of [UTM](https://github.com/utmapp/UTM), built with UTM's iOS frontend and QEMU runtime. It is not an official UTM release.

## Start a Windows VM

1. Install WinPocket using the unsigned IPA from the iOS build workflow and a development signing method such as AltStore or SideStore. The signature must preserve `get-task-allow` for JIT.
2. Open WinPocket and choose **Create a New Virtual Machine** → **Emulate** → **Windows**.
3. Download the official [Windows 11 Arm64 ISO from Microsoft](https://www.microsoft.com/software-download/windows11arm64). In WinPocket, turn on **Install Windows 10 or higher**, choose **Boot ISO Image**, and import that ISO from Files. Its ARM64 guest matches the iPhone/iPad CPU family; an x64/AMD64 ISO forces much slower cross-architecture emulation.
4. Keep the 64 GB virtual disk. The iOS preset starts with 2 GB RAM to reduce the chance iOS kills the app. If your device has enough free memory, raise guest RAM to 4 GB in the hardware settings before creating the VM. Keep the ISO mounted for first boot, then complete Windows Setup.
5. Shut down the guest when Setup finishes. Eject the ISO or set the virtual disk first in the boot order, then start the VM again.

For the best speed, use the ARM64 ISO, enable JIT for WinPocket in StikDebug, and close other memory-heavy apps before starting the VM. Install Windows and its VirtIO/SPICE guest tools on the virtual disk, then eject the ISO for later boots. StikDebug requires a pairing file and LocalDevVPN setup on supported releases. iOS 26+ has extra JIT requirements; consult the current [StikDebug](https://github.com/StikDebug/StikDebug) and [StikJIT](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md) notes. QEMU still emulates the CPU on iOS because Apple does not expose Hypervisor.framework to ordinary iOS apps, so even with JIT and an ARM64 guest Windows will run far below native speed.

Windows installer media and licenses are not included. Obtain them from Microsoft or another authorized source.

## Build

The [GitHub Actions workflow](.github/workflows/winpocket-ios.yml) builds QEMU and the app on a macOS runner, packages an unsigned IPA, and stores it as a workflow artifact. Building the QEMU dependencies from source takes time. To build locally, follow the dependency and signing steps in [UTM's iOS development guide](Documentation/iOSDevelopment.md), then open `UTM.xcodeproj` and select the `iOS` scheme. Set your Apple Developer Team and a unique `PRODUCT_BUNDLE_PREFIX` in `CodeSigning.xcconfig`.

Free Apple developer signing expires after seven days and must be refreshed. A Windows ISO and a compatible iPhone/iPad are required to verify a full guest boot; this Windows development host has no Xcode or iOS device attached.

## Licenses

WinPocket retains UTM's Apache 2.0 license and source notices. The project also includes QEMU and other components under their respective licenses; see the retained [`LICENSE`](LICENSE) and upstream [license notes](https://github.com/utmapp/UTM#license). This source-only repository does not bundle compiled emulator binaries, Windows, or firmware images.
