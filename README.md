# WinPocket

WinPocket is an iPhone and iPad app for setting up Windows virtual machines with QEMU. Windows boot and experimental graphics have not yet been verified on an iPhone or iPad.

<p align="center">
  <img src="website/assets/winpocket-icon.png" alt="WinPocket Windows logo app icon" width="144">
</p>

<p align="center"><a href="https://br0des.github.io/WinPocket/">WinPocket website</a> · <a href="https://github.com/Br0des/WinPocket/actions">iOS build</a></p>

## Start a Windows VM

1. Install the unsigned IPA from the iOS build workflow with a development signing method such as AltStore or SideStore. The signature must preserve `get-task-allow` for JIT.
2. Choose **Set up Windows**, then configure memory and storage. Windows 11 requires at least 4 GiB RAM and 64 GiB storage. iOS memory limits may prevent the app from allocating enough RAM.
3. Download the official [Windows 11 Arm64 ISO from Microsoft](https://www.microsoft.com/en-us/software-download/windows11arm64) or import it from Files. The Windows setup flow uses ARM64 QEMU emulation, not hardware virtualization.
4. Use **Enable JIT with StikDebug** if needed. This requires a compatible signing method, Developer Mode and StikDebug pairing. JIT detection does not guarantee execution on every device: TXM/SPTM devices need an executable-memory protocol that has not yet been implemented here.
5. Save the machine and wait for the guest tools download to finish before starting it. After installation, shut down Windows and eject the installer ISO if it boots into Setup again.

The **Try experimental Windows 3D** option requests an accelerated display device, but does not guarantee accelerated guest graphics. On iOS 16+, the experimental DXMT DirectX 11 path also requires the default or ANGLE (Metal) renderer, DirectX enabled, and the experimental 3D driver installed from the Windows guest tools. It may be unstable and has not been verified on a device. See the [Windows guest tools documentation](https://docs.getutm.app/guest-support/windows/) for driver details.

Windows installer media and licenses are not included; obtain Windows from Microsoft. The [bring-up notes](Documentation/WindowsBringup.md) describe the remaining Husk JIT integration and device tests.

## Build

The [GitHub Actions workflow](.github/workflows/winpocket-ios.yml) builds QEMU and the app on a macOS runner, packages an unsigned IPA, and stores it as a workflow artifact. Building QEMU dependencies from source takes time. To build locally, follow the dependency and signing steps in [UTM's iOS development guide](Documentation/iOSDevelopment.md), then open `UTM.xcodeproj` and select the `iOS` scheme. Set your Apple Developer Team and a unique `PRODUCT_BUNDLE_PREFIX` in `CodeSigning.xcconfig`.

Free Apple developer signing expires after seven days and must be refreshed. A Windows ISO and a compatible iPhone/iPad are required to verify a full guest boot; this repository is built on a Windows development host without Xcode or an iOS device attached.

## Licenses

WinPocket is an independent community project based on open-source emulator components. It retains UTM's Apache 2.0 license and source notices. QEMU and other included components retain their respective licenses; see [`LICENSE`](LICENSE) and the upstream [license notes](https://github.com/utmapp/UTM#license). WinPocket is not affiliated with Microsoft or the UTM project. The repository does not bundle compiled emulator binaries, Windows, or firmware images.
