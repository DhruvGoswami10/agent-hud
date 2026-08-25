import AppKit
import SwiftUI

/// A MacBook you can put anywhere on the desk.
///
/// There is no macOS simulator — Xcode only ships iOS, watchOS, tvOS and
/// visionOS — and a macOS VM is worse than useless here, because a virtual
/// display has no notch: `safeAreaInsets.top` is zero, so the app would draw
/// its no-notch fallback and you'd be reviewing the wrong layout.
///
/// So the lid is drawn instead: a real window containing a mock screen with a
/// real cutout, and the real `NotchRootView` hung from it, driven by the same
/// AppState as everything else. Same pixels the notch would show, somewhere
/// you can look at them without a hardware notch to fight over.
@MainActor
final class PreviewWindowController {
    private var window: NSWindow?
    private let state: AppState

    init(state: AppState) { self.state = state }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = "MacBook Preview — Agent HUD Playground"
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(rootView: LidView(state: state))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

/// The mock machine: lid, menu bar, cutout, and the HUD hanging under it.
private struct LidView: View {
    @ObservedObject var state: AppState
    /// The measured geometry of a 14" MacBook Pro, so what you see here is
    /// the size it will actually be.
    private let notch = CGSize(width: 185, height: 32)

    var body: some View {
        GeometryReader { geo in
            let scale = min(1.35, max(0.85, geo.size.width / 900))
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(white: 0.08), Color(white: 0.02)],
                               startPoint: .top, endPoint: .bottom)

                VStack(spacing: 0) {
                    menuBar
                    Spacer()
                }

                // The HUD itself, hung from the top edge exactly as it is on
                // hardware — the cutout above is drawn, this part is real.
                NotchRootView(state: state,
                              metrics: NotchWindowController.Metrics(
                                notchWidth: notch.width, notchHeight: notch.height, hasNotch: true))
                    .frame(width: 820, height: 620, alignment: .top)
                    .allowsHitTesting(true)
            }
            .scaleEffect(scale, anchor: .top)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 16 * scale, style: .continuous))
        }
        .background(Color(white: 0.06))
        .onAppear { state.openPanel() }
    }

    private var menuBar: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.05)).frame(height: notch.height)
            HStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "apple.logo")
                    Text("Finder").fontWeight(.semibold)
                    Text("File"); Text("Edit"); Text("View")
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.leading, 16)

                Spacer()
                // the cutout: nothing renders behind the camera
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.black)
                    .frame(width: notch.width, height: notch.height)
                    .overlay(alignment: .center) {
                        HStack(spacing: 24) {
                            Circle().fill(Color(white: 0.09)).frame(width: 4, height: 4)
                            Circle().fill(Color(white: 0.10)).frame(width: 7, height: 7)
                            Circle().fill(Color(white: 0.09)).frame(width: 4, height: 4)
                        }
                    }
                Spacer()

                HStack(spacing: 13) {
                    Image(systemName: "battery.75"); Image(systemName: "wifi")
                    Text("Mon 16:04")
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.trailing, 16)
            }
            .frame(height: notch.height)
        }
    }
}
