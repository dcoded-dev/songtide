import Foundation
import WebKit

/// The YouTube Music page's language: Songtide's own (the default), so the page and the app match,
/// or whatever the Google account is set to (YouTube's choice, ahead of the Mac's languages).
/// YouTube keeps the language in its PREF cookie (`hl=…`, which its own language menu sets), and
/// that cookie wins over the account's language.
enum PageLanguage {
    static let key = "pageLanguage"
    private static let googleAccount = "account"

    static var followsSongtide: Bool { UserDefaults.standard.string(forKey: key) != googleAccount }

    /// The language Songtide shows itself in (one of its translations, as macOS chose).
    static var songtideLanguage: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// Its name, in itself ("עברית", "Deutsch").
    static var songtideLanguageName: String {
        let code = songtideLanguage
        return Locale(identifier: code).localizedString(forIdentifier: code)?.localizedCapitalized ?? code
    }

    /// YouTube's code for it, where YouTube's differs.
    static var youTubeCode: String {
        switch songtideLanguage {
        case "he": "iw"
        case "zh-Hans": "zh-CN"
        case "zh-Hant": "zh-TW"
        case "nb": "no"
        case "pt-BR": "pt"
        default: songtideLanguage
        }
    }

    /// Puts the language in YouTube's PREF cookie (or takes it out, for the account's), keeping the
    /// cookie's other settings. Call before loading the page.
    @MainActor static func apply() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let existing = await store.allCookies().first { $0.name == "PREF" && $0.domain.hasSuffix("youtube.com") }
        var fields = (existing?.value ?? "").split(separator: "&").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("hl=") }
        if followsSongtide { fields.append("hl=\(youTubeCode)") }
        let value = fields.joined(separator: "&")
        guard value != existing?.value else { return }
        guard let cookie = HTTPCookie(properties: [
            .name: "PREF", .value: value, .domain: ".youtube.com", .path: "/", .secure: "TRUE",
            .expires: Date().addingTimeInterval(400 * 24 * 3600),
        ]) else { return }
        await store.setCookie(cookie)
    }
}
