import Foundation
import WebKit

/// The YouTube Music page's language: the Mac's (the default; or the one picked for Songtide alone
/// in Language & Region), or whatever the Google account is set to. The Mac's own language rather
/// than Songtide's translation: YouTube has many more languages than Songtide.
/// YouTube keeps the language in its PREF cookie (`hl=…`, which its own language menu sets), and
/// that cookie wins over the account's language.
enum PageLanguage {
    static let key = "pageLanguage"
    private static let googleAccount = "account"

    static var followsMac: Bool { UserDefaults.standard.string(forKey: key) != googleAccount }

    /// The Mac's first language for Songtide ("he-IL", "zh-Hans-US", "pt-BR").
    private static var macLanguage: Locale.Language { Locale.Language(identifier: Locale.preferredLanguages.first ?? "en") }

    /// Its name, in itself ("עברית", "Deutsch").
    static var macLanguageName: String {
        let id = Locale.preferredLanguages.first ?? "en"
        let code = macLanguage.languageCode?.identifier ?? "en"
        let name = Locale(identifier: id).localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// YouTube's code for it (YouTube's own codes, where they differ from Apple's).
    static var youTubeCode: String {
        let language = macLanguage
        let code = language.languageCode?.identifier ?? "en"
        let region = language.region?.identifier
        switch code {
        case "he": return "iw"
        case "nb", "no": return "no"
        case "zh":
            if region == "HK" { return "zh-HK" }
            return language.script?.identifier == "Hant" || region == "TW" ? "zh-TW" : "zh-CN"
        case "pt": return region == "PT" ? "pt-PT" : "pt"
        case "es": return region == nil || region == "ES" ? "es" : "es-419"
        case "fr": return region == "CA" ? "fr-CA" : "fr"
        case "en": return region == "GB" || region == "AU" || region == "IE" || region == "NZ" || region == "IN" ? "en-GB" : "en"
        default: return code
        }
    }

    /// Puts the language in YouTube's PREF cookie (or takes it out, for the account's), keeping the
    /// cookie's other settings. Call before loading the page.
    @MainActor static func apply() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let existing = await store.allCookies().first { $0.name == "PREF" && $0.domain.hasSuffix("youtube.com") }
        var fields = (existing?.value ?? "").split(separator: "&").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("hl=") }
        if followsMac { fields.append("hl=\(youTubeCode)") }
        let value = fields.joined(separator: "&")
        #if DEBUG
        FileHandle.standardError.write(Data("[language] mac=\(Locale.preferredLanguages) page=\(followsMac ? youTubeCode : "account") PREF \(existing?.value ?? "-") -> \(value)\n".utf8))
        #endif
        guard value != existing?.value else { return }
        guard let cookie = HTTPCookie(properties: [
            .name: "PREF", .value: value, .domain: ".youtube.com", .path: "/", .secure: "TRUE",
            .expires: Date().addingTimeInterval(400 * 24 * 3600),
        ]) else { return }
        await store.setCookie(cookie)
    }
}
