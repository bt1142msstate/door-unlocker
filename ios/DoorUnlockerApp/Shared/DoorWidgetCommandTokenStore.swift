import Foundation

enum DoorWidgetCommandTokenStore {
    private static let tokenKey = "DoorUnlockerWidgetCommandToken"
    private static let tokenQueryName = "token"

    static func commandURL(action: String) -> URL {
        var components = URLComponents()
        components.scheme = "doorunlocker"
        components.host = action
        components.queryItems = [
            URLQueryItem(name: tokenQueryName, value: currentToken())
        ]

        return components.url!
    }

    static func isValidWidgetCommandURL(_ url: URL) -> Bool {
        guard url.scheme == "doorunlocker",
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == tokenQueryName })?
                .value else {
            return false
        }

        return token == currentToken()
    }

    private static func currentToken() -> String {
        if let token = DoorStatusStore.sharedDefaults.string(forKey: tokenKey), !token.isEmpty {
            return token
        }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        DoorStatusStore.sharedDefaults.set(token, forKey: tokenKey)
        return token
    }
}
