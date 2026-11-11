import Foundation
import Security
import SQLite3
import WebKit
import XCTest
@testable import FritzApp

@MainActor
final class BrowserImportTests: XCTestCase {
    // These fixed ciphertexts were generated independently with OpenSSL, not the decoder under test.
    private let cookieHex = "763130f9aad756a0481bc1b11e28165171971440ce487efbeb4959639aaece7e170d148191fd079baa7be02d4d2d1fbd6b3843"
    private let passwordHex = "763130928e3705b4fff3ab715b924cdb6bcb5b809ac51d5f64a9fea2c5d5478858bca1"
    private let wrongDomainHex = "7631303956c50d679da3d922d92f6b191ff19d8467e75b84ff03875c6f30b78e6201c6096387f4024b5f94f0cd7cae82d27c29"

    func testImportReadsCommittedWALDecryptsAndSkipsUnrepresentableRecords() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.sql("""
            CREATE TABLE meta(key TEXT, value TEXT);
            INSERT INTO meta VALUES('version','24');
            CREATE TABLE cookies(host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT,
                is_secure INTEGER, is_httponly INTEGER, expires_utc INTEGER, is_persistent INTEGER,
                samesite INTEGER, top_frame_site_key TEXT, has_cross_site_ancestor INTEGER);
            INSERT INTO cookies VALUES('127.0.0.1','session','',X'\(cookieHex)','/',0,1,0,0,1,'',0);
            INSERT INTO cookies VALUES('127.0.0.1','partitioned','private',X'','/',0,0,0,0,1,'https://other.example',1);
            INSERT INTO cookies VALUES('127.0.0.1','expired','old',X'','/',0,0,1,1,1,'',0);
            """, file: "Cookies")
        try fixture.sql("""
            CREATE TABLE logins(origin_url TEXT, signon_realm TEXT, username_value TEXT, password_value BLOB,
                blacklisted_by_user INTEGER, scheme INTEGER);
            INSERT INTO logins VALUES('https://example.test/login','https://example.test/','fixture-user',X'\(passwordHex)',0,0);
            INSERT INTO logins VALUES('https://example.test/','https://example.test/','blocked',X'\(passwordHex)',1,0);
            INSERT INTO logins VALUES('https://example.test/','https://other.test/','wrong-realm',X'\(passwordHex)',0,0);
            """, file: "Login Data")
        let batch = try await BrowserImportReader().read(fixture.source, cookies: true, passwords: true)
        XCTAssertEqual(batch.cookies.count, 1)
        let cookie = try XCTUnwrap(batch.cookies.first).httpCookie()
        XCTAssertEqual(cookie.value, "fixture-cookie")
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertFalse(cookie.isSecure)
        XCTAssertEqual(cookie.domain, "127.0.0.1")
        XCTAssertNil(cookie.expiresDate)
        XCTAssertEqual(batch.skippedCookies, 2)
        XCTAssertEqual(batch.logins.count, 1)
        XCTAssertEqual(batch.logins.first?.origin, "https://example.test")
        XCTAssertEqual(batch.logins.first?.username, "fixture-user")
        XCTAssertEqual(batch.logins.first?.password, "fixture-password")
        XCTAssertEqual(batch.skippedPasswords, 2)
        // The source connections remain open in WAL mode throughout the import.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Cookies-wal").path))
    }

    func testImportRejectsDomainMismatchAndUnsupportedEncryptionBeforeReturningData() throws {
        let cipher = try ChromiumImportCipher(password: Data("fritz-synthetic-source-key".utf8))
        func bytes(_ hex: String) -> Data {
            Data(stride(from: 0, to: hex.count, by: 2).map { index in
                let start = hex.index(hex.startIndex, offsetBy: index)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            })
        }
        XCTAssertThrowsError(try cipher.decrypt(bytes(wrongDomainHex), domain: "127.0.0.1"))
        XCTAssertThrowsError(try cipher.decrypt(Data("v20unsupported".utf8)))
        XCTAssertThrowsError(try cipher.decrypt(bytes(passwordHex).dropLast()))
    }

    func testSavedPasswordsMergeAndStayRestrictedToExactOrigin() async throws {
        let service = "dev.fritz.tests.website-passwords.\(UUID().uuidString)"
        defer { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary) }
        let store = WebsitePasswordStore(service: service)
        try await store.save(WebsiteLogin(origin: "https://example.test", username: "fixture-user", password: "first"))
        try await store.save(WebsiteLogin(origin: "https://example.test", username: "fixture-user", password: "updated"))
        let accounts = try await store.accounts(origin: "https://example.test")
        XCTAssertEqual(accounts.count, 1)
        let saved = try await store.password(for: XCTUnwrap(accounts.first))
        XCTAssertEqual(saved, "updated")
        for origin in ["http://example.test", "https://sub.example.test", "https://example.test:8443"] {
            let other = try await store.accounts(origin: origin)
            XCTAssertTrue(other.isEmpty)
        }
        XCTAssertEqual(websiteOrigin(URL(string: "https://EXAMPLE.test:443/login")!), "https://example.test")
    }

    func testCookieImportWritesEngineStoreWithSecurityAttributes() async throws {
        let name = "fritz-import-\(UUID().uuidString)"
        let expiration = Date(timeIntervalSinceNow: 3600)
        let imported = ImportedCookie(domain: "import-fixture.example.test", name: name, value: "synthetic",
            path: "/account", secure: true, httpOnly: true, expires: expiration, sameSite: 2)
        try await BrowserCookieStore.set(imported)
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await store.allCookies()
        let cookie = try XCTUnwrap(cookies.first { $0.name == name })
        await store.deleteCookie(cookie)
        XCTAssertEqual(cookie.domain, "import-fixture.example.test")
        XCTAssertEqual(cookie.path, "/account")
        XCTAssertEqual(cookie.value, "synthetic")
        XCTAssertTrue(cookie.isSecure)
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertEqual(cookie.properties?[.sameSitePolicy] as? String, "strict")
        XCTAssertEqual(try XCTUnwrap(cookie.expiresDate).timeIntervalSince1970, expiration.timeIntervalSince1970, accuracy: 1)
    }

    func testManualFillChecksDocumentOriginAndDoesNotSubmit() async throws {
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 640, height: 480))
        let observer = LoadObserver()
        webView.navigationDelegate = observer
        webView.loadHTMLString("""
            <form action="/login" onsubmit="window.submitted = true; return false">
              <input autocomplete="username"><input type="password"><button>Sign in</button>
            </form>
            """, baseURL: URL(string: "https://example.test/login"))
        for _ in 0..<200 {
            if observer.finished { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(observer.finished, "The synthetic document must finish loading")
        let account = WebsiteAccount(origin: "https://example.test", username: "fixture-user")
        let script = try passwordFillScript(account: account, password: "fixture-password")
        let filled = try await webView.evaluateJavaScript(script) as? Bool
        XCTAssertEqual(filled, true)
        let values = try await webView.evaluateJavaScript("[document.querySelector('input').value, document.querySelector('[type=password]').value, !!window.submitted]") as? [Any]
        XCTAssertEqual(values?[0] as? String, "fixture-user")
        XCTAssertEqual(values?[1] as? String, "fixture-password")
        XCTAssertEqual(values?[2] as? Bool, false)
        let wrongOrigin = WebsiteAccount(origin: "http://example.test", username: "other")
        let rejected = try await webView.evaluateJavaScript(passwordFillScript(account: wrongOrigin, password: "wrong")) as? Bool
        XCTAssertEqual(rejected, false)
        _ = try await webView.evaluateJavaScript("document.querySelector('form').action = 'https://other.test/'")
        let crossOriginForm = try await webView.evaluateJavaScript(script) as? Bool
        XCTAssertEqual(crossOriginForm, false)
        webView.stopLoading()
    }

    private final class LoadObserver: NSObject, WKNavigationDelegate {
        var finished = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fritz-browser-import-\(UUID().uuidString)")
        let service = "dev.fritz.tests.source-browser.\(UUID().uuidString)"
        private var databases: [OpaquePointer] = []
        var source: BrowserImportSource { .init(directory: root, browser: "Synthetic", service: service, keychainAccount: "Synthetic") }
        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                kSecAttrAccount: "Synthetic", kSecValueData: Data("fritz-synthetic-source-key".utf8)] as CFDictionary, nil)
            guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        func sql(_ sql: String, file: String) throws {
            var database: OpaquePointer?
            guard sqlite3_open(root.appendingPathComponent(file).path, &database) == SQLITE_OK, let database else {
                throw NSError(domain: "FixtureSQLite", code: 1)
            }
            databases.append(database)
            guard sqlite3_exec(database, "PRAGMA journal_mode=WAL; \(sql)", nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "FixtureSQLite", code: 2)
            }
        }
        func remove() {
            for database in databases { sqlite3_close(database) }
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
