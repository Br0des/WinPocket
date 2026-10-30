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
import Darwin
#endif
#if canImport(Virtualization)
import Virtualization
#endif

struct VMWizardStartView: View {
    @ObservedObject var wizardState: VMWizardState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var jitAvailable = Main.jitAvailable
    @State private var waitingForStikDebug = false
    @State private var showJitAlert = false
    @State private var jitAlertMessage = ""

    private var isJitAvailable: Bool {
        jitAvailable || Main.jitAvailable
    }
    
    var isVirtualizationSupported: Bool {
        #if os(macOS)
        VZVirtualMachine.isSupported && !processIsTranslated()
        #else
        UTMCapabilities.current.contains(.hasHypervisorSupport)
        #endif
    }
    
    var isEmulationSupported: Bool {
        #if !WITH_JIT
        true
        #else
        isJitAvailable
        #endif
    }
    
    private var startTitle: LocalizedStringKey {
        #if os(iOS) && !WITH_QEMU_TCI && !WITH_REMOTE
        "Set up Windows"
        #else
        "Start"
        #endif
    }

    var body: some View {
        VMWizardContent(startTitle) {
            #if os(iOS) && !WITH_QEMU_TCI && !WITH_REMOTE
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Windows 11 for ARM")
                        .font(.title2.bold())
                    Text("Create a Windows workspace using an official ARM64 installer. CPU emulation requires JIT on this build.")
                        .foregroundColor(.secondary)
                }
                Button {
                    wizardState.useVirtualization = false
                    wizardState.operatingSystem = .Windows
                    wizardState.useAppleVirtualization = false
                    wizardState.isGuestToolsInstallRequested = true
                    wizardState.next()
                } label: {
                    Label("Get started", systemImage: "arrow.right.circle.fill")
                }
            }
            #else
            Section {
                let virtButton = Button {
                    wizardState.useVirtualization = true
                    wizardState.next()
                } label: {
                    HStack {
                        Image(systemName: "hare")
                            .font(.title)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Virtualize")
                                .font(.title)
                            Text("Faster, but can only run the native CPU architecture.")
                                .font(.caption)
                        }
                        Spacer()
                    }
                    .padding()
                }
                .buttonStyle(.inList)
                .disabled(!isVirtualizationSupported)
                virtButton

                Button {
                    wizardState.useVirtualization = false
                    wizardState.next()
                } label: {
                    HStack {
                        Image(systemName: "tortoise")
                            .font(.title)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Emulate")
                                .font(.title)
                            Text("Slower, but can run other CPU architectures.")
                                .font(.caption)
                        }
                        Spacer()
                    }
                    .padding()
                }
                .buttonStyle(.inList)
                
            } header: {
                Text("Custom")
            } footer: {
                if !isEmulationSupported && !isVirtualizationSupported {
                    Text("Enable JIT with StikDebug above to use CPU emulation.")
                } else if !isVirtualizationSupported {
                    Text("Virtualization is not supported on your system.")
                } else if !isEmulationSupported {
                    Text("This build does not emulation.")
                }
            }
            #endif
            #if os(iOS) && WITH_JIT
            Section {
                if isJitAvailable {
                    Label("JIT access detected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Access detection does not confirm that executable memory works on every device. Newer devices with TXM/SPTM need additional support not yet implemented in WinPocket.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        requestJITWithStikDebug()
                    } label: {
                        Label("Enable JIT with StikDebug", systemImage: "bolt.fill")
                    }
                    Text("WinPocket will ask StikDebug to attach to this app, then return here. StikDebug, Developer Mode, and its pairing setup are required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Emulation speed")
            }
            #endif
            #if !os(iOS) || WITH_QEMU_TCI || WITH_REMOTE
            Section {
                Button {
                    NotificationCenter.default.post(name: NSNotification.OpenVirtualMachine, object: nil)
                } label: {
                    Label {
                        Text("Open…")
                    } icon: {
                        Image(systemName: "doc")
                    }
                }
                #if os(macOS)
                .buttonStyle(.link)
                #endif
                Link(destination: URL(string: "https://www.microsoft.com/en-us/software-download/windows11arm64")!) {
                    Label {
                        Text("Download Windows 11 ARM ISO…")
                    } icon: {
                        Image(systemName: "arrow.down.doc")
                    }
                }
            } header: {
                Text("Existing")
            }
            #endif

        }
        .onAppear {
            jitAvailable = Main.jitAvailable
        }
        .onChange(of: scenePhase) { phase in
            #if os(iOS) && WITH_JIT
            guard phase == .active, waitingForStikDebug else {
                return
            }
            waitingForStikDebug = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                refreshJITStatus()
            }
            #endif
        }
        .alert("JIT status", isPresented: $showJitAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(jitAlertMessage)
        }
    }

    #if os(iOS) && WITH_JIT
    private func requestJITWithStikDebug() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            jitAlertMessage = "WinPocket could not determine its app identifier."
            showJitAlert = true
            return
        }

        var components = URLComponents()
        components.scheme = "stikdebug"
        components.host = "enable-jit"
        components.queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "pid", value: String(getpid()))
        ]

        guard let url = components.url else {
            jitAlertMessage = "WinPocket could not create the StikDebug request."
            showJitAlert = true
            return
        }

        openURL(url) { accepted in
            if accepted {
                waitingForStikDebug = true
            } else {
                jitAlertMessage = "StikDebug did not open. Install StikDebug, finish its pairing setup, then try again."
                showJitAlert = true
            }
        }
    }

    private func refreshJITStatus() {
        guard jb_has_jit_entitlement() || jb_has_cs_disabled() else {
            Main.jitAvailable = false
            jitAvailable = false
            jitAlertMessage = "WinPocket could not confirm JIT access. Check Developer Mode, signing, pairing, and StikDebug's JIT status. Some devices need additional JIT support that this build does not yet provide."
            showJitAlert = true
            return
        }
        Main.jitAvailable = true
        jitAvailable = true
    }
    #endif
    
    private func processIsTranslated() -> Bool {
        let key = "sysctl.proc_translated"
        var ret = Int32(0)
        var size: Int = 0
        sysctlbyname(key, nil, &size, nil, 0)
        let result = sysctlbyname(key, &ret, &size, nil, 0)
        if result == -1 {
            return false
        }
        return ret != 0
    }
}

struct VMWizardStartView_Previews: PreviewProvider {
    @StateObject static var wizardState = VMWizardState()
    
    static var previews: some View {
        VMWizardStartView(wizardState: wizardState)
    }
}
