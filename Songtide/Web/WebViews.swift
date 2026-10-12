import SwiftUI
import WebKit

/// Hosts the controller's long-lived web view. The same WKWebView instance is
/// re-parented whenever the window is recreated, so playback never stops.
struct MusicWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Google sign-in in a separate web view that shares the default cookie store
/// with the main player. Completes once Google redirects back to YouTube Music.
struct SignInWebView: NSViewRepresentable {
    var onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = MusicController.applicationNameForUserAgent
        config.userContentController.addUserScript(MusicController.disablePasskeysScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: MusicController.signInURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onFinish: () -> Void
        private var finished = false
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .allow }
            if url.host() == "music.youtube.com" {
                finish()
                return .cancel
            }
            if navigationAction.targetFrame?.isMainFrame ?? true, !MusicController.isInternal(url) {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            webView.load(navigationAction.request)
            return nil
        }

        private func finish() {
            guard !finished else { return }
            finished = true
            onFinish()
        }
    }
}

struct SignInSheet: View {
    @Environment(MusicController.self) private var music

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Sign in with Google", systemImage: "person.crop.circle")
                    .font(.headline)
                Spacer()
                Button("Cancel") { music.isShowingSignIn = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            SignInWebView { music.signInCompleted() }
        }
        .frame(width: 480, height: 640)
    }
}
