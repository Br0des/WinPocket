//
// Copyright © 2021 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import SwiftUI
#if os(iOS)
import WebKit
#endif

struct VMWizardOSWindowsView: View {
    @ObservedObject var wizardState: VMWizardState
    @State private var isFileImporterPresented: Bool = false
    #if os(iOS)
    @State private var isWindowsDownloadPresented = false
    #endif
    
    var body: some View {
        VMWizardContent("Windows") {
            #if !WITH_QEMU_TCI
            Section {
                Toggle("Install Windows 10 or higher", isOn: $wizardState.isWindows10OrHigher)
                    .onChange(of: wizardState.isWindows10OrHigher) { newValue in
                        if newValue {
                            wizardState.systemBootUefi = true
                            wizardState.systemBootTpm = true
                            wizardState.isGuestToolsInstallRequested = true
                        } else {
                            wizardState.systemBootUefi = false
                            wizardState.systemBootTpm = false
                            wizardState.isGuestToolsInstallRequested = false
                        }
                    }
                    .disabled(wizardState.legacyHardware)

                if wizardState.isWindows10OrHigher {
                    #if os(macOS)
                    Button {
                        let downloadCrystalFetch = URL(string: "https://mac.getutm.app/crystalfetch/")!
                        if let crystalFetch = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "llc.turing.CrystalFetch") {
                            NSWorkspace.shared.openApplication(at: crystalFetch, configuration: .init()) { _, error in
                                if error != nil {
                                    NSWorkspace.shared.open(downloadCrystalFetch)
                                }
                            }
                        } else {
                            NSWorkspace.shared.open(downloadCrystalFetch)
                        }
                    } label: {
                        Label("Fetch latest Windows installer…", systemImage: "link")
                    }.buttonStyle(.link)
                    #endif
                    Link(destination: URL(string: "https://docs.getutm.app/guides/windows/")!) {
                        Label("Windows Install Guide", systemImage: "link")
                    }.buttonStyle(.borderless)
                }
            } header: {
                Text("Image File Type")
            }
            #endif

            Section {
                if wizardState.legacyHardware {
                    Picker("Boot Device", selection: $wizardState.bootDevice) {
                        Text("CD/DVD Image").tag(VMBootDevice.cd)
                        Text("Floppy Image").tag(VMBootDevice.floppy)
                    }.pickerStyle(.inline)
                    .onAppear {
                        if !wizardState.legacyHardware && wizardState.bootDevice == .floppy {
                            wizardState.bootDevice = .cd
                        }
                    }
                }

                #if os(iOS)
                Button {
                    isWindowsDownloadPresented = true
                } label: {
                    Label("Download Windows 11 ARM64 ISO…", systemImage: "arrow.down.circle")
                }
                #endif

                FileBrowseField(url: $wizardState.bootImageURL, isFileImporterPresented: $isFileImporterPresented, hasClearButton: false)
                
                if wizardState.isBusy {
                    Spinner(size: .large)
                }
            } header: {
                if wizardState.bootDevice == .cd {
                    Text("Boot ISO Image")
                } else {
                    Text("Boot IMG Image")
                }
            }
            
            if !wizardState.isWindows10OrHigher && !wizardState.legacyHardware {
                DetailedSection("", description: "Some older systems do not support UEFI boot, such as Windows 7 and below.") {
                    Toggle("UEFI Boot", isOn: $wizardState.systemBootUefi)
                        .onChange(of: wizardState.systemBootUefi) { newValue in
                            if !newValue {
                                wizardState.systemBootTpm = false
                            }
                        }
                    Toggle("Secure Boot with TPM 2.0", isOn: $wizardState.systemBootTpm)
                        .disabled(!wizardState.systemBootUefi)
                }
            }
            
            // Disabled for non-Windows 10 installs due to autounattend version
            if wizardState.isWindows10OrHigher {
                DetailedSection("", description: "Download and mount the guest support package for Windows. This is required for some features including dynamic resolution and clipboard sharing.") {
                    Toggle("Install drivers and SPICE tools", isOn: $wizardState.isGuestToolsInstallRequested)
                }
            }
        }
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.data], onCompletion: processImage)
        #if os(iOS)
        .sheet(isPresented: $isWindowsDownloadPresented) {
            WindowsISODownloadSheet { url in
                wizardState.bootImageURL = url
            }
        }
        #endif
        .onAppear {
            wizardState.bootDevice = .cd
            #if WITH_QEMU_TCI
            wizardState.legacyHardware = true
            #endif
            if wizardState.legacyHardware {
                wizardState.isWindows10OrHigher = false
                wizardState.isGuestToolsInstallRequested = false
                wizardState.systemBootUefi = false
                wizardState.systemBootTpm = false
            }
        }
    }
    
    private func processImage(_ result: Result<URL, Error>) {
        wizardState.busyWorkAsync {
            let url = try result.get()
            await MainActor.run {
                wizardState.bootImageURL = url
            }
        }
    }
}

#if os(iOS)
private struct WindowsISODownloadSheet: View {
    let onComplete: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var downloadState = WindowsISODownloadState()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose the Windows 11 ARM64 edition and language on Microsoft’s page. When you tap the ISO download link, WinPocket saves it here and selects it as the boot image.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("The installer is several gigabytes. Use Wi-Fi and make sure your iPhone has enough free storage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

                if downloadState.isDownloading {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: downloadState.fractionComplete)
                        Text("Downloading Windows installer… \(Int(downloadState.fractionComplete * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }

                WindowsISOWebView(downloadState: downloadState)
                    .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle("Windows 11 ARM64 ISO")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Download failed", isPresented: Binding(
                get: { downloadState.errorMessage != nil },
                set: { if !$0 { downloadState.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { downloadState.errorMessage = nil }
            } message: {
                Text(downloadState.errorMessage ?? "")
            }
            .onChange(of: downloadState.completedURL) { url in
                guard let url else { return }
                onComplete(url)
                dismiss()
            }
        }
    }
}

private struct WindowsISOWebView: UIViewRepresentable {
    let downloadState: WindowsISODownloadState

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = downloadState
        webView.uiDelegate = downloadState
        downloadState.webView = webView
        webView.load(URLRequest(url: URL(string: "https://www.microsoft.com/en-us/software-download/windows11arm64")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) { }
}

@MainActor
private final class WindowsISODownloadState: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    @Published var isDownloading = false
    @Published var fractionComplete = 0.0
    @Published var completedURL: URL?
    @Published var errorMessage: String?
    weak var webView: WKWebView?
    private var progressObservation: NSKeyValueObservation?
    private var destinationURL: URL?

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = navigationAction.request.url,
              url.pathExtension.lowercased() == "iso",
              let host = url.host?.lowercased(),
              host == "microsoft.com" || host.hasSuffix(".microsoft.com") else {
            decisionHandler(.allow, preferences)
            return
        }
        preferences.shouldPerformDownload = true
        decisionHandler(.download, preferences)
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        beginTracking(download)
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        beginTracking(download)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        webView.load(navigationAction.request)
        return nil
    }

    func download(_ download: WKDownload,
                 decideDestinationUsing response: URLResponse,
                 suggestedFilename: String,
                 completionHandler: @escaping (URL?) -> Void) {
        guard suggestedFilename.lowercased().hasSuffix(".iso") else {
            completionHandler(nil)
            return
        }

        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let directory = documents.appendingPathComponent("Windows ISOs", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let safeFilename = URL(fileURLWithPath: suggestedFilename).lastPathComponent
            guard safeFilename.lowercased().hasSuffix(".iso") else {
                completionHandler(nil)
                return
            }
            let requestedURL = directory.appendingPathComponent(safeFilename)
            let destination = uniqueDestination(for: requestedURL)
            destinationURL = destination
            completionHandler(destination)
        } catch {
            errorMessage = error.localizedDescription
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        progressObservation = nil
        isDownloading = false
        fractionComplete = 1
        completedURL = destinationURL
        destinationURL = nil
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        progressObservation = nil
        isDownloading = false
        errorMessage = error.localizedDescription
        destinationURL = nil
    }

    private func beginTracking(_ download: WKDownload) {
        download.delegate = self
        isDownloading = true
        fractionComplete = 0
        progressObservation = download.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
            Task { @MainActor in
                self?.fractionComplete = progress.fractionCompleted
            }
        }
    }

    private func uniqueDestination(for url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let baseName = url.deletingPathExtension().lastPathComponent
        let suffix = UUID().uuidString.prefix(8)
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(baseName)-\(suffix)")
            .appendingPathExtension(url.pathExtension)
    }
}
#endif

struct VMWizardOSWindowsView_Previews: PreviewProvider {
    @StateObject static var wizardState = VMWizardState()
    
    static var previews: some View {
        VMWizardOSWindowsView(wizardState: wizardState)
    }
}
