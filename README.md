# WinPocket

WinPocket is an iPhone and iPad app for setting up Windows virtual machines with QEMU. Import your own Windows ARM installer and boot it in a VM.

<p align="center">
  <img src="website/assets/winpocket-icon.png" alt="WinPocket Windows logo app icon" width="144">
</p>

<p align="center"><a href="https://br0des.github.io/WinPocket/">WinPocket website</a> · <a href="https://github.com/Br0des/WinPocket/actions">iOS build</a></p>

## Start a Windows VM

1. Install the unsigned IPA from the iOS build workflow with a development signing method such as AltStore or SideStore. The signature must preserve `get-task-allow` for JIT.
2. Choose **Create a New Virtual Machine** → **Emulate** → **Windows**.
3. Download the official [Windows 11 Arm64 ISO from Microsoft](https://www.microsoft.com/en-us/software-download/windows11arm64). Turn on **Install Windows 10 or higher**, choose **Boot ISO Image**, and import the ISO from Files. Arm64 matches the iPhone and iPad CPU family; x64 media requires slower cross-architecture emulation.
4. Keep the 64 GB virtual disk and mount the ISO for Windows Setup. The preset uses 2 GB RAM; increase it in hardware settings if your device has enough free memory.
5. For faster CPU emulation, use **Enable JIT with StikDebug** in the app. StikDebug, Developer Mode, and pairing setup are required. Close other memory-heavy apps before starting the VM.
6. When installation finishes, shut down Windows, eject the ISO or set the virtual disk first in boot order, then start the VM again.

The Windows preset selects QEMU's OpenGL-capable VirtIO display device when the architecture supports it. Windows guest 3D acceleration depends on compatible drivers; QEMU still emulates the CPU, so performance is below a PC.

Windows installer media and licenses are not included. Obtain them from Microsoft or another authorized source.

## Build

The [GitHub Actions workflow](.github/workflows/winpocket-ios.yml) builds QEMU and the app on a macOS runner, packages an unsigned IPA, and stores it as a workflow artifact. Building QEMU dependencies from source takes time. To build locally, follow the dependency and signing steps in [UTM's iOS development guide](Documentation/iOSDevelopment.md), then open `UTM.xcodeproj` and select the `iOS` scheme. Set your Apple Developer Team and a unique `PRODUCT_BUNDLE_PREFIX` in `CodeSigning.xcconfig`.

Free Apple developer signing expires after seven days and must be refreshed. A Windows ISO and a compatible iPhone/iPad are required to verify a full guest boot; this repository is built on a Windows development host without Xcode or an iOS device attached.

## Licenses

WinPocket is an independent community project based on open-source emulator components. It retains UTM's Apache 2.0 license and source notices. QEMU and other included components retain their respective licenses; see [`LICENSE`](LICENSE) and the upstream [license notes](https://github.com/utmapp/UTM#license). WinPocket is not affiliated with Microsoft or the UTM project. The repository does not bundle compiled emulator binaries, Windows, or firmware images.
