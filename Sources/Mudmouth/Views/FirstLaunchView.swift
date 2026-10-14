//
//  FirstLaunchView.swift
//  Mudmouth
//
//  Created by devonly on 2025/08/13.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import BetterSafariView
import SwiftUI

private enum CertificateDownloadLifecycle {
    /// Enqueue start and stop immediately in UI event order, without blocking the UI.
    private static let queue = DispatchQueue(label: "Mudmouth.CertificateDownload")

    static func start(_ proxy: X509Proxy, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        queue.async {
            let message: String?
            do { try proxy.start(); message = nil }
            catch { message = error.localizedDescription }
            Task { @MainActor in completion(message) }
        }
    }

    static func stop(_ proxy: X509Proxy) {
        queue.async { try? proxy.stop() }
    }
}

private struct ConfirmationDialog<A: View, M: View, L: View>: View {
    @State private var isPresented: Bool = false
    let role: ButtonRole?
    let label: () -> L
    let title: Text
    let titleVisibility: Visibility
    let actions: () -> A
    let message: () -> M

    init(
        role: ButtonRole? = nil,
        @ViewBuilder label: @escaping () -> L,
        title: Text,
        titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: @escaping () -> A,
        @ViewBuilder message: @escaping () -> M = { EmptyView() },
    ) {
        self.role = role
        self.label = label
        self.title = title
        self.titleVisibility = titleVisibility
        self.message = message
        self.actions = actions
    }

    var body: some View {
        Button(role: role, action: {
            isPresented.toggle()
        }, label: {
            label()
        })
        .confirmationDialog(title, isPresented: $isPresented, titleVisibility: .visible, actions: {
            actions()
        }, message: {
            message()
        })
    }
}

public struct FirstLaunchView: View {
    /// The set of setup pages to present.
    public enum Flow: Sendable {
        /// The complete nine-page first launch flow.
        case full
        /// Certificate / VPN setup, with optional notifications (pages 2...7).
        case captureSetup

        fileprivate var pages: ClosedRange<Int> {
            switch self {
                case .full: 0 ... 8
                case .captureSetup: 2 ... 7
            }
        }
    }

    @Environment(Mudmouth.self) private var mudmouth: Mudmouth
    @Environment(\.dismiss) var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selection: Int
    @State private var isPresented: Bool = false
    @State private var setupError: String?
    @State private var isActive = true
    @State private var isDownloading = false
    private let flow: Flow
    private let proxy: X509Proxy = .default

    var isEnabled: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        switch selection {
            // Installing a traffic source and enabling notifications are optional.
            case 1, 2:
                true
            case 3:
                true
            case 4:
                mudmouth.isVerified
            case 5:
                mudmouth.isTrusted
            case 6:
                mudmouth.isVPNInstalled
            case 7:
                mudmouth.isConnected
            default:
                true
        }
        #endif
    }

    private var isLastPage: Bool {
        selection >= flow.pages.upperBound
    }

    public init(flow: Flow = .full) {
        self.flow = flow
        _selection = State(initialValue: flow.pages.lowerBound)
    }

    private var page: (title: LocalizedStringKey, image: String, description: LocalizedStringKey) {
        switch selection {
            case 0: ("TITLE_APP_NAME", "Logo", "DESCRIPTION_APP_NAME")
            case 1: ("TITLE_INSTALL_NINTENDO_APP", "Nintendo", "DESCRIPTION_INSTALL_NINTENDO_APP")
            case 2: ("TITLE_ALLOW_NOTIFICATION", "Notification", "DESCRIPTION_ALLOW_NOTIFICATION")
            case 3: ("TITLE_DOWNLOAD_VPN_PROFILE", "Download", "DESCRIPTION_DOWNLOAD_VPN_PROFILE")
            case 4: ("TITLE_INSTALL_VPN_PROFILE", "Certificate", "DESCRIPTION_INSTALL_VPN_PROFILE")
            case 5: ("TITLE_TRUST_CERTIFICATE", "Verified", "DESCRIPTION_TRUST_CERTIFICATE")
            case 6: ("TITLE_INSTALL_VPN", "VPN", "DESCRIPTION_INSTALL_VPN")
            case 7: ("TITLE_TEST_TOGGLE_VPN", "Activate", "DESCRIPTION_TEST_TOGGLE_VPN")
            default: ("TITLE_TEST_OPEN_APP", "Start", "DESCRIPTION_TEST_OPEN_APP")
        }
    }

    private func actionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key, bundle: .module)
            .fontWeight(.bold)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    private func advance() {
        withAnimation(.spring) {
            if isLastPage {
                dismiss()
            } else {
                selection += 1
            }
        }
    }

    @ViewBuilder
    private var pageHeader: some View {
        let page = page
        Text(page.title, bundle: .module)
            .font(.title)
            .fontWeight(.bold)
        Image(page.image, bundle: .module)
            .resizable()
            .frame(width: 128, height: 128)
            .padding()
        Text(page.description, bundle: .module)
            .frame(maxWidth: 400, alignment: .center)
            .padding(.horizontal)
    }

    @ViewBuilder
    private var pageControls: some View {
        switch selection {
            case 1:
                Button(action: {
                    UIApplication.shared.open(URL(string: "https://apps.apple.com/app/id1234806557")!)
                }, label: {
                    actionLabel("BUTTON_OPEN_APP_STORE")
                })
                ConfirmationDialog(
                    role: .destructive,
                    label: {
                        actionLabel("BUTTON_SKIP_LATER")
                    },
                    title: Text("TITLE_SKIP_LATER", bundle: .module),
                    titleVisibility: .visible,
                    actions: {
                        Button(role: .destructive, action: {
                            withAnimation(.spring) {
                                selection += 1
                            }
                        }, label: {
                            Text("BUTTON_SKIP_LATER", bundle: .module)
                        })
                    },
                    message: {
                        Text("DIALOG_SKIP_INSTALL_DESC", bundle: .module)
                    },
                )
            case 2:
                Button(action: {
                    Task(priority: .background, operation: {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    })
                }, label: {
                    actionLabel("BUTTON_ALLOW_NOTIFICATION")
                })
                ConfirmationDialog(
                    role: .destructive,
                    label: {
                        actionLabel("BUTTON_SKIP_LATER")
                    },
                    title: Text("TITLE_SKIP_LATER", bundle: .module),
                    titleVisibility: .visible,
                    actions: {
                        Button(role: .destructive, action: {
                            withAnimation(.spring) {
                                selection += 1
                            }
                        }, label: {
                            Text("BUTTON_SKIP_LATER", bundle: .module)
                        })
                    },
                    message: {
                        Text("DIALOG_SKIP_ALLOW_NOTIFICATION_DESC", bundle: .module)
                    },
                )
            case 3:
                Button(action: {
                    isDownloading = true
                    CertificateDownloadLifecycle.start(proxy) { message in
                        isDownloading = false
                        guard isActive else { return }
                        if let message {
                            setupError = message
                        } else {
                            isPresented = true
                        }
                    }
                }, label: {
                    actionLabel("BUTTON_DOWNLOAD_PROFILE")
                })
                .disabled(isDownloading)
            case 4:
                Button(action: {
                    UIApplication.shared.open(URL(string: "App-prefs:General&path=ManagedConfigurationList/VPN")!)
                }, label: {
                    actionLabel("BUTTON_OPEN_VPN_SETTINGS")
                })
            case 5:
                Button(action: {
                    UIApplication.shared.open(URL(string: "App-prefs:General&path=About/CERT_TRUST_SETTINGS")!)
                }, label: {
                    actionLabel("BUTTON_TRUST_CERTIFICATE")
                })
            case 6:
                Button(action: {
                    Task(priority: .background, operation: {
                        try await mudmouth.installVPN()
                    })
                }, label: {
                    actionLabel("BUTTON_INSTALL_VPN")
                })
            case 7:
                Button(action: {
                    Task(priority: .background, operation: {
                        try await mudmouth.startVPNTunnel()
                    })
                }, label: {
                    actionLabel("BUTTON_ACTIVATE_VPN")
                })
            case 8:
                Button(action: {
                    UIApplication.shared.open(URL(string: "com.nintendo.znca://")!)
                }, label: {
                    actionLabel("BUTTON_OPEN_APP")
                })
            default:
                EmptyView()
        }
    }

    public var body: some View {
        // Page content and controls share one ScrollView so every control stays reachable
        // at large Dynamic Type sizes / in landscape. Pages only change via `selection`.
        ScrollView(content: {
            VStack(spacing: 12, content: {
                pageHeader
                VStack(spacing: 12) {
                    pageControls
                    Button(action: advance, label: {
                        actionLabel(isLastPage ? "BUTTON_END" : "BUTTON_NEXT")
                    })
                    .disabled(!isEnabled || isDownloading)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 560 : 320)
            })
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.vertical, 24)
            .id(selection)
        })
        .multilineTextAlignment(.center)
        .safeAreaInset(edge: .top) {
            HStack { Spacer(); Button { dismiss() } label: { Text("BUTTON_CLOSE", bundle: .module).foregroundStyle(Color.primary) }.padding() }
                .background(.background)
        }
        .alert(Text("TITLE_SETUP_ERROR", bundle: .module), isPresented: Binding(get: { setupError != nil }, set: {
            if !$0 {
                setupError = nil
            }
        })) {
            Button("OK", role: .cancel) { setupError = nil }
        } message: { Text(setupError ?? "") }
        .sheet(isPresented: $isPresented, content: {
            SafariView(url: .init(string: "http://127.0.0.1:8888")!)
                .onDisappear(perform: {
                    CertificateDownloadLifecycle.stop(proxy)
                })
        })
        .onAppear { isActive = true }
        .onDisappear(perform: {
            // Do not stop the server while Safari is still presented over this view.
            guard !isPresented else { return }
            isActive = false
            CertificateDownloadLifecycle.stop(proxy)
        })
    }
}

#Preview {
    FirstLaunchView()
        .environment(\.locale, .init(identifier: "ja"))
        .environment(Mudmouth.default)
}
