import AppKit
import Combine
import SwiftUI

@MainActor
enum OnboardingWindow {
    static func make(model: StagehandModel, onComplete: @escaping () -> Void) -> NSWindow {
        let size = NSSize(width: 520, height: 600)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Stagehand"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = NSColor(red: 0.025, green: 0.03, blue: 0.045, alpha: 1)
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.auxiliary, .fullScreenNone]
        window.contentMinSize = size
        window.contentMaxSize = size
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(
            rootView: OnboardingView(model: model, onComplete: onComplete)
        )
        window.center()
        return window
    }
}

struct OnboardingView: View {
    @ObservedObject var model: StagehandModel
    let onComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: OnboardingStep
    @State private var direction = 1
    @State private var hasCompleted = false

    init(
        model: StagehandModel,
        onComplete: @escaping () -> Void,
        initialStep: OnboardingStep = .welcome
    ) {
        self.model = model
        self.onComplete = onComplete
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        ZStack {
            OnboardingBackground(step: step)

            VStack(spacing: 0) {
                ZStack {
                    page
                        .id(step)
                        .transition(pageTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                footer
            }
            .padding(.top, 34)
            .padding(.horizontal, 34)
            .padding(.bottom, 28)
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onChange(of: step) { _, newStep in
            if newStep == .accessibility { model.refreshPermissions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if step == .accessibility { model.refreshPermissions() }
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome:
            WelcomeOnboardingPage()
        case .overview:
            OverviewOnboardingPage()
        case .accessibility:
            AccessibilityOnboardingPage(model: model)
        case .ready:
            ReadyOnboardingPage()
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if step != .welcome {
                Button("Back", action: goBack)
                    .buttonStyle(OnboardingSecondaryButtonStyle())
            } else {
                Color.clear.frame(width: 78, height: 34)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                    Capsule(style: .continuous)
                        .fill(item == step ? Color.white : .white.opacity(0.25))
                        .frame(width: item == step ? 18 : 6, height: 6)
                        .animation(.easeOut(duration: 0.22), value: step)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")

            Spacer()

            Button(step == .ready ? "Start Stagehand" : "Continue", action: advance)
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(step == .accessibility && !model.accessibilityGranted)
        }
        .frame(height: 38)
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let incoming: Edge = direction > 0 ? .trailing : .leading
        let outgoing: Edge = direction > 0 ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: incoming).combined(with: .opacity),
            removal: .move(edge: outgoing).combined(with: .opacity)
        )
    }

    private func advance() {
        guard let next = step.next else {
            guard !hasCompleted else { return }
            hasCompleted = true
            onComplete()
            return
        }
        direction = 1
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.88)) {
            step = next
        }
    }

    private func goBack() {
        guard let previous = step.previous else { return }
        direction = -1
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.88)) {
            step = previous
        }
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case overview
    case accessibility
    case ready

    var next: Self? { Self(rawValue: rawValue + 1) }
    var previous: Self? { Self(rawValue: rawValue - 1) }
}

private struct WelcomeOnboardingPage: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.black.opacity(0.28))
                    .frame(width: 286, height: 214)
                    .rotationEffect(.degrees(-5))
                    .offset(x: -13, y: 4)
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.white.opacity(0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(.white.opacity(0.14), lineWidth: 1)
                    }
                    .frame(width: 286, height: 214)
                    .rotationEffect(.degrees(4))
                    .offset(x: 13, y: 2)
                Circle()
                    .fill(Color.blue.opacity(0.35))
                    .frame(width: 150, height: 150)
                    .blur(radius: 35)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 116, height: 116)
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 12)
                    .accessibilityHidden(true)
            }
            .frame(height: 260)

            Text("Meet Stagehand")
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 10)

            Text("Arrange windows and move between windows and spaces with shortcuts or three-finger swipes.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.66))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 340)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OverviewOnboardingPage: View {
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceArtwork()
                .frame(height: 254)

            Text("Move through windows and spaces")
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 12)

            Text("Stagehand arranges windows side by side. Swipe left or right to switch windows, and up or down to switch spaces.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.66))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 380)
                .padding(.top, 10)

            HStack(spacing: 20) {
                HStack(spacing: 6) {
                    PhosphorIcon(.arrowsLeftRight)
                        .frame(width: 15, height: 15)
                    Text("Windows")
                }
                HStack(spacing: 6) {
                    PhosphorIcon(.arrowsDownUp)
                        .frame(width: 15, height: 15)
                    Text("Spaces")
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WorkspaceArtwork: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.black.opacity(0.26))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.white.opacity(0.13), lineWidth: 1)
                }
                .frame(width: 370, height: 218)

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(.red.opacity(0.9)).frame(width: 7, height: 7)
                    Circle().fill(.yellow.opacity(0.9)).frame(width: 7, height: 7)
                    Circle().fill(.green.opacity(0.9)).frame(width: 7, height: 7)
                    Spacer()
                    Capsule().fill(.white.opacity(0.14)).frame(width: 68, height: 6)
                }
                .padding(.horizontal, 16)

                HStack(spacing: 8) {
                    windowCard(color: Color(red: 0.37, green: 0.28, blue: 0.94), width: 104)
                    windowCard(color: Color(red: 0.12, green: 0.53, blue: 0.95), width: 136)
                    windowCard(color: Color(red: 0.15, green: 0.72, blue: 0.64), width: 82)
                }
                .padding(.horizontal, 13)
            }
            .frame(width: 370)

        }
        .frame(width: 370, height: 218)
        .overlay(alignment: .bottom) {
            PhosphorIcon(.arrowsLeftRight)
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .frame(width: 38, height: 38)
                .background(.blue.gradient, in: Circle())
                .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                .offset(y: 19)
                .accessibilityHidden(true)
        }
        .frame(width: 370, height: 238, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Three windows arranged side by side")
    }

    private func windowCard(color: Color, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [color.opacity(0.95), color.opacity(0.36)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 7) {
                    Capsule().fill(.white.opacity(0.62)).frame(width: width * 0.34, height: 5)
                    Capsule().fill(.white.opacity(0.25)).frame(width: width * 0.54, height: 4)
                }
                .padding(10)
            }
            .frame(width: width, height: 142)
    }
}

private struct AccessibilityOnboardingPage: View {
    @ObservedObject var model: StagehandModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.28))
                    .frame(width: 166, height: 166)
                    .blur(radius: 34)
                PhosphorIcon(model.accessibilityGranted ? .shieldCheck : .handPalm)
                    .foregroundStyle(model.accessibilityGranted ? Color.green : Color.blue)
                    .frame(width: 76, height: 76)
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
            }
            .frame(height: 202)
            .accessibilityHidden(true)

            Text(model.accessibilityGranted ? "Access granted" : "Allow Accessibility access")
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Stagehand needs Accessibility access to arrange windows, switch focus, and use global controls.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.66))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 390)
                .padding(.top, 10)

            HStack(spacing: 13) {
                PhosphorIcon(.personArmsSpread)
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .frame(width: 38, height: 38)
                    .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility")
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.accessibilityGranted ? "Access granted" : "Access required")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.accessibilityGranted {
                    HStack(spacing: 5) {
                        PhosphorIcon(.checkCircle)
                            .frame(width: 14, height: 14)
                        Text("Granted")
                    }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    Button("Allow") { model.requestAccessibility() }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .tint(.white)
                }
            }
            .padding(14)
            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
            .padding(.top, 20)

            if !model.accessibilityGranted {
                // macOS sometimes reports a fresh grant only to a new process, and a
                // rebuild with a different signature needs the grant again. Without
                // these the step had no way forward but the disabled Continue button.
                VStack(spacing: 6) {
                    HStack(spacing: 14) {
                        Text("Still not detected?")
                            .foregroundStyle(.white.opacity(0.66))
                        Button("Open Accessibility Settings", action: openAccessibilitySettings)
                        Button("Relaunch Stagehand", action: relaunchStagehand)
                    }
                    .buttonStyle(.link)
                    Text("Turn Stagehand on in the list, then relaunch. A rebuild with a different signature needs the grant again.")
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
                .font(.system(size: 12))
                .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func relaunchStagehand() {
        OnboardingRelaunch.relaunch()
    }
}

/// Quits this instance and starts a new one from the same bundle, so the new
/// process reads the Accessibility grant that this one may have missed.
///
/// Stagehand allows one running instance: AppDelegate.claimSingleInstance holds a
/// file lock and refuses a second launch while the first is alive. Opening the
/// replacement before quitting therefore produced the "another instance" alert
/// and then no Stagehand at all. A detached shell waits for this PID to exit and
/// only then asks LaunchServices to open the bundle.
enum OnboardingRelaunch {
    /// The script the helper runs. Single quotes in the path are closed, escaped,
    /// and reopened so `sh` sees one literal argument.
    static func script(pid: pid_t, bundlePath: String) -> String {
        let quoted = "'" + bundlePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open -n \(quoted)"
    }

    @MainActor
    static func relaunch() {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script(pid: ProcessInfo.processInfo.processIdentifier, bundlePath: Bundle.main.bundlePath)]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            NSLog("Stagehand could not start its relaunch helper: %@", String(describing: error))
            return
        }
        NSApp.terminate(nil)
    }
}

private struct ReadyOnboardingPage: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.24))
                    .frame(width: 190, height: 190)
                    .blur(radius: 42)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.green, Color(red: 0.12, green: 0.53, blue: 0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 124, height: 124)
                    .overlay {
                        PhosphorIcon(.check)
                            .foregroundStyle(.white)
                            .frame(width: 58, height: 58)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 12)
            }
            .frame(height: 264)
            .accessibilityHidden(true)

            Text("Stagehand is ready")
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Click the Stagehand icon in the menu bar for quick controls, or open Settings for more options.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.66))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 380)
                .padding(.top, 10)

            HStack(spacing: 8) {
                PhosphorIcon(.browser)
                    .frame(width: 14, height: 14)
                Text("Stagehand lives in your menu bar")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.white.opacity(0.075), in: Capsule())
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OnboardingBackground: View {
    let step: OnboardingStep

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.03, blue: 0.045)

            Circle()
                .fill(color.opacity(0.48))
                .frame(width: 430, height: 430)
                .blur(radius: 90)
                .offset(x: xOffset, y: -245)
                .animation(.easeInOut(duration: 0.65), value: step)

            Circle()
                .fill(Color(red: 0.10, green: 0.48, blue: 0.95).opacity(0.2))
                .frame(width: 360, height: 360)
                .blur(radius: 100)
                .offset(x: -230, y: 295)

            LinearGradient(
                colors: [.white.opacity(0.04), .clear, .black.opacity(0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private var color: Color {
        switch step {
        case .welcome: Color(red: 0.34, green: 0.22, blue: 0.96)
        case .overview: Color(red: 0.04, green: 0.55, blue: 0.95)
        case .accessibility: Color(red: 0.14, green: 0.42, blue: 0.96)
        case .ready: Color(red: 0.05, green: 0.72, blue: 0.55)
        }
    }

    private var xOffset: CGFloat {
        switch step {
        case .welcome: -190
        case .overview: 190
        case .accessibility: 50
        case .ready: -20
        }
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minWidth: 112, minHeight: 34)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.18, green: 0.55, blue: 1), Color(red: 0.12, green: 0.38, blue: 0.94)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(configuration.isPressed ? 0.72 : 1),
                in: Capsule()
            )
            .opacity(isEnabled ? 1 : 0.42)
            .overlay { Capsule().stroke(.white.opacity(0.22), lineWidth: 1) }
            .shadow(color: .black.opacity(0.24), radius: 5, y: 2)
            .contentShape(Capsule())
    }
}

private struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.55 : 0.82))
            .padding(.horizontal, 17)
            .frame(minWidth: 78, minHeight: 34)
            .background(.white.opacity(configuration.isPressed ? 0.05 : 0.09), in: Capsule())
            .overlay { Capsule().stroke(.white.opacity(0.12), lineWidth: 1) }
            .contentShape(Capsule())
    }
}
