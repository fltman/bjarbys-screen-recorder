import Foundation

/// Språket gränssnittet faktiskt visas på (låst till svenska), för datum och decimaltal.
/// `Locale.current` följer systemets region och kan ge "Nov 4" och "2.0" mitt i svensk text.
enum AppLocale {
    static let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "sv")

    /// `String(format:)` med rätt decimaltecken.
    static func format(_ format: String, _ args: CVarArg...) -> String {
        String(format: format, locale: locale, arguments: args)
    }
}
