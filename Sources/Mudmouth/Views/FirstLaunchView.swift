//
//  FirstLaunchView.swift
//  Mudmouth
//
//  Created by devonly on 2025/08/13.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import BetterSafariView
import SwiftUI
import UserNotifications

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

private enum NotificationAuthorization {
    /// Nonisolated so only `Sendable` values cross back to the main actor.
    static func currentStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func request() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
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

    private enum NotificationState {
        case notDetermined
        case granted
        case denied

        init(_ status: UNAuthorizationStatus) {
            switch status {
                case .notDetermined: self = .notDetermined
                case .authorized, .provisional, .ephemeral: self = .granted
                default: self = .denied
            }
        }
    }

    @Environment(Mudmouth.self) private var mudmouth: Mudmouth
    @Environment(\.dismiss) var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: Int
    @State private var isPresented: Bool = false
    @State private var setupError: String?
    @State private var isActive = true
    @State private var isDownloading = false
    /// Bumped whenever the certificate page is left, so stale download callbacks are ignored.
    @State private var downloadGeneration = 0
    /// `nil` while the notification permission is being loaded.
    @State private var notificationState: NotificationState?
    @State private var isRequestingNotification = false
    @State private var notificationQueryGeneration = 0
    @State private var notificationRequestGeneration = 0
    @State private var notificationRequestID = 0
    @State private var notificationTask: Task<Void, Never>?
    @State private var notificationError: String?
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

    private var isFirstPage: Bool {
        selection <= flow.pages.lowerBound
    }

    private var isLastPage: Bool {
        selection >= flow.pages.upperBound
    }

    private var stepNumber: Int {
        selection - flow.pages.lowerBound + 1
    }

    private var stepCount: Int {
        flow.pages.count
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

    private var imageSize: CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            48
        } else if horizontalSizeClass == .compact {
            80
        } else {
            96
        }
    }

    private func actionLabel(_ key: LocalizedStringKey, bold: Bool = true) -> some View {
        Text(key, bundle: .module)
            .fontWeight(bold ? .bold : .regular)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
    }
}

extension FirstLaunchView {
    // MARK: - Navigation

    /// Common exit path for every page change, Close and disappearance.
    /// Invalidates in-flight notification work and the pending certificate download callback.
    private func invalidatePageWork() {
        notificationQueryGeneration += 1
        notificationRequestGeneration += 1
        notificationRequestID += 1
        notificationTask?.cancel()
        notificationTask = nil
        isRequestingNotification = false
        notificationState = nil
        notificationError = nil
        if selection == 3, !isPresented {
            // Leaving the certificate page: drop the pending callback and stop the server (FIFO after start).
            downloadGeneration += 1
            isDownloading = false
            CertificateDownloadLifecycle.stop(proxy)
        }
    }

    private func advance() {
        invalidatePageWork()
        withAnimation(.spring) {
            if isLastPage {
                dismiss()
            } else {
                selection += 1
            }
        }
    }

    private func goBack() {
        guard !isFirstPage else { return }
        invalidatePageWork()
        withAnimation(.spring) {
            selection -= 1
        }
    }

    private func close() {
        invalidatePageWork()
        dismiss()
    }

    // MARK: - Notifications

    private func refreshNotificationState() {
        guard isActive, selection == 2, !isRequestingNotification else { return }
        notificationQueryGeneration += 1
        let generation = notificationQueryGeneration
        Task { @MainActor in
            let status = await NotificationAuthorization.currentStatus()
            guard generation == notificationQueryGeneration,
                  isActive, selection == 2, !isRequestingNotification else { return }
            notificationState = NotificationState(status)
        }
    }

    private func requestNotificationAuthorization() {
        guard !isRequestingNotification, selection == 2 else { return }
        isRequestingNotification = true
        notificationQueryGeneration += 1
        notificationRequestID += 1
        let id = notificationRequestID
        let generation = notificationRequestGeneration
        func isCurrent() -> Bool {
            id == notificationRequestID && generation == notificationRequestGeneration
                && isActive && selection == 2 && !Task.isCancelled
        }
        notificationTask = Task { @MainActor in
            defer {
                // Only the current request may clear the state.
                if id == notificationRequestID, generation == notificationRequestGeneration {
                    isRequestingNotification = false
                    notificationTask = nil
                }
            }
            do {
                _ = try await NotificationAuthorization.request()
                guard isCurrent() else { return }
                // Granted or denied: either way the choice is made, move on once.
                advance()
            } catch {
                guard isCurrent() else { return }
                notificationError = error.localizedDescription
            }
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

extension FirstLaunchView {
    // MARK: - Content

    @ViewBuilder
    private var pageHeader: some View {
        let page = page
        Text(page.title, bundle: .module)
            .font(.title2)
            .fontWeight(.semibold)
        Image(page.image, bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(width: imageSize, height: imageSize)
            .padding(.vertical, 8)
            .accessibilityHidden(true)
        Text(page.description, bundle: .module)
            .frame(maxWidth: 400, alignment: .center)
            .padding(.horizontal)
    }

    private func skipDialog(_ message: LocalizedStringKey) -> some View {
        ConfirmationDialog(
            label: {
                actionLabel("BUTTON_SKIP_LATER", bold: false)
            },
            title: Text("TITLE_SKIP_LATER", bundle: .module),
            titleVisibility: .visible,
            actions: {
                Button(action: advance, label: {
                    Text("BUTTON_SKIP_LATER", bundle: .module)
                })
            },
            message: {
                Text(message, bundle: .module)
            },
        )
        .buttonStyle(.plain)
    }

    private func nextButton(prominent: Bool) -> some View {
        Button(action: advance, label: {
            actionLabel("BUTTON_NEXT")
        })
        .buttonStyleProminent(prominent)
        .disabled(!isEnabled || isDownloading)
    }

    @ViewBuilder
    private var pageControls: some View {
        switch selection {
            case 0:
                nextButton(prominent: true)
            case 1:
                Button(action: {
                    UIApplication.shared.open(URL(string: "https://apps.apple.com/app/id1234806557")!)
                }, label: {
                    actionLabel("BUTTON_OPEN_APP_STORE")
                })
                .buttonStyle(.borderedProminent)
                skipDialog("DIALOG_SKIP_INSTALL_DESC")
            case 2:
                notificationControls
            case 3:
                Button(action: {
                    isDownloading = true
                    let generation = downloadGeneration
                    CertificateDownloadLifecycle.start(proxy) { message in
                        // Ignore callbacks from a page visit that has been left.
                        guard generation == downloadGeneration, selection == 3 else { return }
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
                .buttonStyle(.borderedProminent)
                .disabled(isDownloading)
                nextButton(prominent: false)
            case 4:
                Button(action: {
                    UIApplication.shared.open(URL(string: "App-prefs:General&path=ManagedConfigurationList/VPN")!)
                }, label: {
                    actionLabel("BUTTON_OPEN_VPN_SETTINGS")
                })
                .buttonStyle(.borderedProminent)
                nextButton(prominent: false)
            case 5:
                Button(action: {
                    UIApplication.shared.open(URL(string: "App-prefs:General&path=About/CERT_TRUST_SETTINGS")!)
                }, label: {
                    actionLabel("BUTTON_TRUST_CERTIFICATE")
                })
                .buttonStyle(.borderedProminent)
                nextButton(prominent: false)
            case 6:
                Button(action: {
                    Task(priority: .background, operation: {
                        try await mudmouth.installVPN()
                    })
                }, label: {
                    actionLabel("BUTTON_INSTALL_VPN")
                })
                .buttonStyle(.borderedProminent)
                nextButton(prominent: false)
            case 7:
                Button(action: {
                    Task(priority: .background, operation: {
                        try await mudmouth.startVPNTunnel()
                    })
                }, label: {
                    actionLabel("BUTTON_ACTIVATE_VPN")
                })
                .buttonStyle(.borderedProminent)
                if !isLastPage {
                    nextButton(prominent: false)
                }
            case 8:
                // The final confirmation lives in the toolbar.
                Button(action: {
                    UIApplication.shared.open(URL(string: "com.nintendo.znca://")!)
                }, label: {
                    actionLabel("BUTTON_OPEN_APP")
                })
                .buttonStyle(.borderedProminent)
            default:
                EmptyView()
        }
    }

    @ViewBuilder
    private var notificationControls: some View {
        switch notificationState {
            case nil:
                ProgressView()
                    .accessibilityLabel(Text("LABEL_NOTIFICATION_CHECKING", bundle: .module))
                Button(action: advance, label: {
                    actionLabel("BUTTON_SKIP_LATER", bold: false)
                })
                .buttonStyle(.plain)
            case .notDetermined:
                Button(action: requestNotificationAuthorization, label: {
                    actionLabel("BUTTON_ALLOW_NOTIFICATION")
                })
                .buttonStyle(.borderedProminent)
                .disabled(isRequestingNotification)
                Button(action: advance, label: {
                    actionLabel("BUTTON_SKIP_LATER", bold: false)
                })
                .buttonStyle(.plain)
            case .granted:
                Text("LABEL_NOTIFICATION_GRANTED", bundle: .module)
                    .foregroundStyle(.secondary)
                nextButton(prominent: true)
            case .denied:
                Text("LABEL_NOTIFICATION_DENIED", bundle: .module)
                    .foregroundStyle(.secondary)
                nextButton(prominent: true)
                Button(action: openAppSettings, label: {
                    actionLabel("BUTTON_OPEN_SETTINGS", bold: false)
                })
                .buttonStyle(.plain)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text("LABEL_STEP_OF \(stepNumber) \(stepCount)", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        ToolbarItem(placement: .topBarLeading) {
            if isFirstPage {
                Button(action: close, label: {
                    Text("BUTTON_CLOSE", bundle: .module).foregroundStyle(Color.primary)
                })
            } else {
                Button(action: goBack, label: {
                    Text("BUTTON_BACK", bundle: .module).foregroundStyle(Color.primary)
                })
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isLastPage {
                Button(action: advance, label: {
                    Text("BUTTON_END", bundle: .module).fontWeight(.semibold)
                })
                .disabled(!isEnabled || isDownloading)
            } else if !isFirstPage {
                Button(action: close, label: {
                    Text("BUTTON_CLOSE", bundle: .module).foregroundStyle(Color.primary)
                })
            }
        }
    }

    public var body: some View {
        NavigationStack {
            // Page content and controls share one ScrollView so every control stays reachable
            // at large Dynamic Type sizes / in landscape. Pages only change via `selection`.
            GeometryReader { viewport in
                ScrollView(content: {
                    VStack(spacing: 12, content: {
                        pageHeader
                        // Pushes the actions to the bottom when the content fits the viewport.
                        Spacer(minLength: 24)
                        VStack(spacing: 12) {
                            pageControls
                            if (4 ... 7).contains(selection) {
                                Label {
                                    Text(isEnabled ? "LABEL_SETUP_STEP_READY" : "LABEL_SETUP_STEP_REQUIRED", bundle: .module)
                                } icon: {
                                    Image(systemName: isEnabled ? "checkmark.circle" : "info.circle")
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 560 : 320)
                    })
                    .frame(maxWidth: 560, minHeight: max(0, viewport.size.height - 32))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .padding(.vertical, 16)
                    .id(selection)
                })
            }
            .multilineTextAlignment(.center)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .alert(Text("TITLE_NOTIFICATION_ERROR", bundle: .module), isPresented: Binding(get: { notificationError != nil }, set: {
                if !$0 {
                    notificationError = nil
                }
            })) {
                Button(role: .cancel, action: { notificationError = nil }, label: { Text("BUTTON_OK", bundle: .module) })
            } message: { Text(verbatim: notificationError ?? "") }
        }
        .alert(Text("TITLE_SETUP_ERROR", bundle: .module), isPresented: Binding(get: { setupError != nil }, set: {
            if !$0 {
                setupError = nil
            }
        })) {
            Button(role: .cancel, action: { setupError = nil }, label: { Text("BUTTON_OK", bundle: .module) })
        } message: { Text(verbatim: setupError ?? "") }
        .sheet(isPresented: $isPresented, content: {
            SafariView(url: .init(string: "http://127.0.0.1:8888")!)
                .onDisappear(perform: {
                    CertificateDownloadLifecycle.stop(proxy)
                })
        })
        .onChange(of: selection, initial: true) {
            refreshNotificationState()
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-query after returning from Settings; never while the system prompt is pending.
            if phase == .active {
                refreshNotificationState()
            }
        }
        .onAppear { isActive = true }
        .onDisappear(perform: {
            // Do not stop the server while Safari is still presented over this view.
            guard !isPresented else { return }
            isActive = false
            invalidatePageWork()
            CertificateDownloadLifecycle.stop(proxy)
        })
    }
}

private extension View {
    @ViewBuilder
    func buttonStyleProminent(_ prominent: Bool) -> some View {
        if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
                .foregroundStyle(.primary)
        }
    }
}

#Preview {
    FirstLaunchView()
        .environment(\.locale, .init(identifier: "ja"))
        .environment(Mudmouth.default)
}
