import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import SQLite3

struct BrowserImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct BrowserImportSource: Identifiable, Sendable {
    let directory: URL
    let browser: String
    let service: String
    let keychainAccount: String
    var id: String { directory.path }
    var title: String { "\(browser) — \(directory.lastPathComponent)" }
    var cookiesURL: URL {
        let network = directory.appendingPathComponent("Network/Cookies")
        return FileManager.default.fileExists(atPath: network.path) ? network : directory.appendingPathComponent("Cookies")
    }
    var passwordsURL: URL { directory.appendingPathComponent("Login Data") }
    var hasCookies: Bool { FileManager.default.fileExists(atPath: cookiesURL.path) }
    var hasPasswords: Bool { FileManager.default.fileExists(atPath: passwordsURL.path) }

    static func discover() -> [Self] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let browsers = [
            ("Chrome", "Google/Chrome", "Chrome Safe Storage", "Chrome"),
            ("Chromium", "Chromium", "Chromium Safe Storage", "Chromium"),
            ("Brave", "BraveSoftware/Brave-Browser", "Brave Safe Storage", "Brave"),
            ("Edge", "Microsoft Edge", "Microsoft Edge Safe Storage", "Microsoft Edge"),
        ]
        return browsers.flatMap { name, path, service, account in
            let directories = (try? FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent(path), includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            return directories.filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
                .map { Self(directory: $0, browser: name, service: service, keychainAccount: account) }
                .filter { $0.hasCookies || $0.hasPasswords }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
}

struct ImportedCookie: Sendable {
    let domain: String
    let name: String
    let value: String
    let path: String
    let secure: Bool
    let httpOnly: Bool
    let expires: Date?
    let sameSite: Int

    var url: URL? {
        var components = URLComponents()
        components.scheme = secure ? "https" : "http"
        components.host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        components.path = path
        return components.url
    }

    func httpCookie() throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain, .name: name, .value: value, .path: path,
        ]
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[.init("HttpOnly")] = "TRUE" }
        if let expires { properties[.expires] = expires }
        if sameSite == 0 { properties[.sameSitePolicy] = "none" }
        if sameSite == 1 { properties[.sameSitePolicy] = "lax" }
        if sameSite == 2 { properties[.sameSitePolicy] = "strict" }
        guard let cookie = HTTPCookie(properties: properties), url != nil else {
            throw BrowserImportError(message: "The source contains an invalid cookie. Nothing has been imported.")
        }
        return cookie
    }
}

struct WebsiteLogin: Sendable {
    let origin: String
    let username: String
    let password: String
}

struct WebsiteAccount: Codable, Hashable, Identifiable, Sendable {
    let origin: String
    let username: String
    var id: String { SHA256.hash(data: Data((origin + "\0" + username).utf8)).map { String(format: "%02x", $0) }.joined() }
}

func websiteOrigin(_ url: URL) -> String? {
    guard isBrowserURL(url), url.user == nil, url.password == nil,
          let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    if let port = url.port, !(scheme == "https" && port == 443 || scheme == "http" && port == 80) {
        components.port = port
    }
    return components.string
}

struct BrowserImportBatch: Sendable {
    var cookies: [ImportedCookie] = []
    var logins: [WebsiteLogin] = []
    var skippedCookies = 0
    var skippedPasswords = 0
}

// Read-only transactions include committed WAL data without modifying the source profile.
private final class ImportDatabase {
    private var handle: OpaquePointer?
    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw BrowserImportError(message: "Cannot read the selected browser database. Quit the source browser and try again.")
        }
        sqlite3_busy_timeout(handle, 2_000)
        guard sqlite3_exec(handle, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            handle = nil
            throw BrowserImportError(message: "The source database is busy. Quit the source browser and try again.")
        }
    }
    deinit { sqlite3_close(handle) }

    func rows(_ sql: String, body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw BrowserImportError(message: "This browser database format is not supported.")
        }
        defer { sqlite3_finalize(statement) }
        var count = 0
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, count < 100_000 else {
                throw BrowserImportError(message: "The source database could not be read completely. Nothing has been imported.")
            }
            count += 1
            try body(statement)
        }
    }
    func columns(_ table: String) throws -> Set<String> {
        var result: Set<String> = []
        try rows("PRAGMA table_info(\(table))") { result.insert(Self.text($0, 1)) }
        return result
    }
    static func text(_ row: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(row, index) else { return "" }
        return String(cString: value)
    }
    static func blob(_ row: OpaquePointer, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(row, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, index)))
    }
}

// Chromium's documented macOS v10 format: PBKDF2-SHA1, AES-128-CBC, PKCS#7.
// No legacy empty-key fallback: denied Keychain access or undecodable data fails explicitly.
struct ChromiumImportCipher {
    private let key: Data
    init(password: Data) throws {
        var derived = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        let status = derived.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { input in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    input.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                    salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    output.baseAddress?.assumingMemoryBound(to: UInt8.self), 16)
            }
        }
        guard status == kCCSuccess else { throw BrowserImportError(message: "Could not prepare the source browser encryption key.") }
        key = derived
    }
    func decrypt(_ encrypted: Data, domain: String? = nil) throws -> String {
        guard encrypted.starts(with: Data("v10".utf8)) else {
            throw BrowserImportError(message: "The source uses an unsupported encryption format. Nothing has been imported.")
        }
        let ciphertext = Data(encrypted.dropFirst(3))
        guard !ciphertext.isEmpty, ciphertext.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw BrowserImportError(message: "The source contains truncated encrypted data. Nothing has been imported.")
        }
        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var length = 0
        let iv = [UInt8](repeating: 32, count: 16)
        let status = plaintext.withUnsafeMutableBytes { output in
            ciphertext.withUnsafeBytes { input in
                key.withUnsafeBytes { key in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        key.baseAddress, 16, iv, input.baseAddress, ciphertext.count,
                        output.baseAddress, output.count, &length)
                }
            }
        }
        guard status == kCCSuccess else { throw BrowserImportError(message: "Could not decrypt the source data. Nothing has been imported.") }
        plaintext.count = length
        if let domain {
            let expected = Data(SHA256.hash(data: Data(domain.utf8)))
            guard plaintext.starts(with: expected) else {
                throw BrowserImportError(message: "The source cookie failed its domain check. Nothing has been imported.")
            }
            plaintext = Data(plaintext.dropFirst(32))
        }
        guard let result = String(data: plaintext, encoding: .utf8) else {
            throw BrowserImportError(message: "The source contains unsupported text data. Nothing has been imported.")
        }
        return result
    }
}

actor BrowserImportReader {
    func discover() -> [BrowserImportSource] { BrowserImportSource.discover() }

    func read(_ source: BrowserImportSource, cookies: Bool, passwords: Bool) throws -> BrowserImportBatch {
        var cipher: ChromiumImportCipher?
        func decrypt(_ value: Data, domain: String? = nil) throws -> String {
            if cipher == nil {
                let authentication = LAContext()
                authentication.localizedReason = "Import browser data into Fritz"
                let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                    kSecAttrService: source.service, kSecAttrAccount: source.keychainAccount, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
                    kSecUseAuthenticationContext: authentication]
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                guard status == errSecSuccess, let data = item as? Data else {
                    throw BrowserImportError(message: "Source browser Keychain access was unavailable (\(status)). Allow access when importing, then try again.")
                }
                cipher = try ChromiumImportCipher(password: data)
            }
            return try cipher!.decrypt(value, domain: domain)
        }
        var batch = BrowserImportBatch()
        if cookies {
            let database = try ImportDatabase(source.cookiesURL)
            var version = 0
            try database.rows("SELECT value FROM meta WHERE key = 'version'") { version = Int(ImportDatabase.text($0, 0)) ?? 0 }
            guard (1...24).contains(version) else {
                throw BrowserImportError(message: "This cookie database version is not supported. Nothing has been imported.")
            }
            let columns = try database.columns("cookies")
            let partition = columns.contains("top_frame_site_key") ? "top_frame_site_key" : "''"
            let ancestor = columns.contains("has_cross_site_ancestor") ? "has_cross_site_ancestor" : "0"
            try database.rows("""
                SELECT host_key, name, value, encrypted_value, path, is_secure, is_httponly,
                       expires_utc, is_persistent, samesite, \(partition), \(ancestor) FROM cookies
                """) { row in
                let persistent = sqlite3_column_int(row, 8) != 0
                let expiration = Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 7)) / 1_000_000 - 11_644_473_600)
                guard ImportDatabase.text(row, 10).isEmpty, sqlite3_column_int(row, 11) == 0,
                      !persistent || expiration > Date() else { batch.skippedCookies += 1; return }
                let domain = ImportDatabase.text(row, 0)
                let encrypted = ImportDatabase.blob(row, 3)
                let value = encrypted.isEmpty ? ImportDatabase.text(row, 2) : try decrypt(encrypted, domain: version >= 24 ? domain : nil)
                let cookie = ImportedCookie(domain: domain, name: ImportDatabase.text(row, 1), value: value,
                    path: ImportDatabase.text(row, 4), secure: sqlite3_column_int(row, 5) != 0,
                    httpOnly: sqlite3_column_int(row, 6) != 0, expires: persistent ? expiration : nil,
                    sameSite: Int(sqlite3_column_int(row, 9)))
                _ = try cookie.httpCookie()
                batch.cookies.append(cookie)
            }
        }
        if passwords {
            let database = try ImportDatabase(source.passwordsURL)
            try database.rows("SELECT origin_url, signon_realm, username_value, password_value, blacklisted_by_user, scheme FROM logins") { row in
                guard sqlite3_column_int(row, 4) == 0, sqlite3_column_int(row, 5) == 0,
                      let url = URL(string: ImportDatabase.text(row, 0)), let origin = websiteOrigin(url),
                      let realm = URL(string: ImportDatabase.text(row, 1)), websiteOrigin(realm) == origin,
                      !ImportDatabase.blob(row, 3).isEmpty else { batch.skippedPasswords += 1; return }
                let password = try decrypt(ImportDatabase.blob(row, 3))
                guard !password.isEmpty else { batch.skippedPasswords += 1; return }
                batch.logins.append(WebsiteLogin(origin: origin, username: ImportDatabase.text(row, 2), password: password))
            }
        }
        return batch
    }
}

actor WebsitePasswordStore {
    static let shared = WebsitePasswordStore(service: Bundle.main.object(forInfoDictionaryKey: "FritzBrowserPasswordsService") as? String)
    private let service: String?
    init(service: String?) { self.service = service }

    private func query(_ account: String? = nil) throws -> [CFString: Any] {
        guard let service, !service.isEmpty else {
            throw BrowserImportError(message: "The app is missing its browser password Keychain namespace. Rebuild Fritz to continue.")
        }
        var result: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        if let account { result[kSecAttrAccount] = account }
        return result
    }
    func save(_ login: WebsiteLogin) throws {
        try Task.checkCancellation()
        let account = WebsiteAccount(origin: login.origin, username: login.username)
        let query = try query(account.id)
        let values: [CFString: Any] = [kSecValueData: Data(login.password.utf8),
            kSecAttrGeneric: try JSONEncoder().encode(account), kSecAttrLabel: "Fritz website password",
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw BrowserImportError(message: "Could not save a website password in Fritz’s Keychain.")
            }
        } else if status != errSecSuccess {
            throw BrowserImportError(message: "Could not update a website password in Fritz’s Keychain (\(status)).")
        }
    }
    func accounts(origin: String) throws -> [WebsiteAccount] {
        var query = try query()
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = item as? [[CFString: Any]] else {
            throw BrowserImportError(message: "Could not read Fritz’s saved website accounts (\(status)).")
        }
        return try rows.compactMap { row in
            guard let data = row[kSecAttrGeneric] as? Data else { return nil }
            let account = try JSONDecoder().decode(WebsiteAccount.self, from: data)
            return account.origin == origin ? account : nil
        }.sorted { $0.username.localizedStandardCompare($1.username) == .orderedAscending }
    }
    func password(for account: WebsiteAccount) throws -> String {
        try Task.checkCancellation()
        var query = try query(account.id)
        query[kSecReturnData] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw BrowserImportError(message: "The saved password is unavailable (\(status)).")
        }
        return password
    }
}
