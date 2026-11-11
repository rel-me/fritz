import SwiftUI
#if !FRITZ_CHROMIUM
import WebKit
#endif

@MainActor @Observable
final class BrowserDataActions {
    var sources: [BrowserImportSource] = []
    var busy = false
    var message: String?
    var accounts: [WebsiteAccount] = []
    private var task: Task<Void, Never>?
    private let reader = BrowserImportReader()

    func discover() {
        run { [self] in
            let result = await reader.discover()
            try Task.checkCancellation()
            sources = result
        }
    }

    func cancel() { task?.cancel() }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        message = nil
        busy = true
        task = Task {
            defer { busy = false; task = nil }
            do { try await action() }
            catch is CancellationError { message = "Cancelled." }
            catch { message = error.localizedDescription }
        }
    }

    func importData(source: BrowserImportSource, cookies: Bool, passwords: Bool) {
        run { [self] in
            var cookieCount = 0
            var passwordCount = 0
            do {
                let batch = try await reader.read(source, cookies: cookies, passwords: passwords)
                try Task.checkCancellation()
                for cookie in batch.cookies {
                    try Task.checkCancellation()
                    try await BrowserCookieStore.set(cookie)
                    cookieCount += 1
                }
                for login in batch.logins {
                    try await WebsitePasswordStore.shared.save(login)
                    passwordCount += 1
                }
                try await BrowserCookieStore.flush()
                message = "Imported \(cookieCount) cookies and \(passwordCount) passwords. Skipped \(batch.skippedCookies) expired or partitioned cookies and \(batch.skippedPasswords) unsupported password records."
            } catch {
                // Engine and Keychain writes are individually durable. Report partial progress honestly.
                let reason = error is CancellationError ? "Cancelled." : error.localizedDescription
                message = "\(reason) Imported \(cookieCount) cookies and \(passwordCount) passwords before stopping. You can retry; matching records are replaced."
            }
        }
    }

    func loadAccounts(page: BrowserPage) {
        accounts = []
        guard let url = page.state.url, let origin = websiteOrigin(url) else {
            message = "Open a website to fill a password."
            return
        }
        run { [self] in
            let result = try await WebsitePasswordStore.shared.accounts(origin: origin)
            try Task.checkCancellation()
            guard page.state.url.flatMap(websiteOrigin) == origin else {
                throw BrowserImportError(message: "The page changed. Open Fill Password again.")
            }
            accounts = result
            if accounts.isEmpty { message = "No imported passwords for \(origin)." }
        }
    }

    func fill(_ account: WebsiteAccount, page: BrowserPage) {
        run { [self] in
            let password = try await WebsitePasswordStore.shared.password(for: account)
            try Task.checkCancellation()
            guard page.state.url.flatMap(websiteOrigin) == account.origin else {
                throw BrowserImportError(message: "The page changed. Open Fill Password again.")
            }
            let filled = try await page.fillPassword(account: account, password: password)
            try Task.checkCancellation()
            message = filled ? "Password filled." : "No single visible password form on this website. Select the password field and try again."
        }
    }
}

@MainActor
enum BrowserCookieStore {
    static func set(_ cookie: ImportedCookie) async throws {
#if FRITZ_CHROMIUM
        guard let url = cookie.url else { throw BrowserImportError(message: "Invalid cookie address.") }
        let success = await withCheckedContinuation { continuation in
            FritzChromiumPage.setCookie(url: url, name: cookie.name, value: cookie.value,
                domain: cookie.domain.hasPrefix(".") ? cookie.domain : "", path: cookie.path,
                secure: cookie.secure, httpOnly: cookie.httpOnly, expires: cookie.expires,
                sameSite: cookie.sameSite) { continuation.resume(returning: $0) }
        }
        guard success else { throw BrowserImportError(message: "Chromium rejected a cookie. The remaining records were not imported.") }
#else
        let value = try cookie.httpCookie()
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(value)
#endif
    }
    static func flush() async throws {
#if FRITZ_CHROMIUM
        let success = await withCheckedContinuation { continuation in
            FritzChromiumPage.flushCookies { continuation.resume(returning: $0) }
        }
        guard success else { throw BrowserImportError(message: "Chromium could not finish saving cookies. Retry the import.") }
#endif
    }
}

struct BrowserImportSheet: View {
    @Bindable var actions: BrowserDataActions
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var cookies = true
    @State private var passwords = true
    private var source: BrowserImportSource? { actions.sources.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Browser Data").font(.title2)
            if actions.sources.isEmpty && !actions.busy {
                Text("No supported browser profiles found. Fritz supports local Chrome, Chromium, Brave, and Edge profiles.")
            } else {
                Picker("Source", selection: $selected) {
                    ForEach(actions.sources) { source in Text(source.title).tag(Optional(source.id)) }
                }
                .disabled(actions.busy)
                Toggle("Cookies", isOn: $cookies).disabled(actions.busy || source?.hasCookies != true)
                Toggle("Saved passwords", isOn: $passwords).disabled(actions.busy || source?.hasPasswords != true)
            }
            Text("Import merges data into this Fritz build and replaces matching cookies and accounts. macOS may ask permission to read the source browser’s Keychain item. Passwords are saved in Fritz’s own Keychain and filled only when you choose Fill Password.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if actions.busy { ProgressView("Importing…").controlSize(.small) }
            if let message = actions.message { Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(actions.busy ? "Cancel" : "Close") {
                    if actions.busy { actions.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    if let source { actions.importData(source: source, cookies: cookies && source.hasCookies,
                                                       passwords: passwords && source.hasPasswords) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(actions.busy || source == nil || !(cookies && source?.hasCookies == true || passwords && source?.hasPasswords == true))
            }
        }
        .padding(24).frame(width: 480)
        .fritzWindowBackground()
        .onChange(of: actions.sources.map(\.id), initial: true) { selected = actions.sources.first?.id }
        .onDisappear { actions.cancel() }
    }
}

struct BrowserPasswordSheet: View {
    @Bindable var actions: BrowserDataActions
    let page: BrowserPage
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fill Password").font(.title2)
            if let origin = page.state.url.flatMap(websiteOrigin) { Text(origin).foregroundStyle(.secondary) }
            if actions.busy { ProgressView().controlSize(.small) }
            ForEach(actions.accounts) { account in
                Button(account.username.isEmpty ? "Account without a username" : account.username) {
                    actions.fill(account, page: page)
                }.disabled(actions.busy)
            }
            if let message = actions.message { Text(message).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 420)
        .fritzWindowBackground()
        .onDisappear { actions.cancel() }
    }
}

// The script executes only in the main document and rechecks origin after the async Keychain read.
// Never submits a form, fills an iframe, or downgrades a saved HTTPS credential to HTTP.
func passwordFillScript(account: WebsiteAccount, password: String) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: ["origin": account.origin, "username": account.username, "password": password])
    guard let json = String(data: data, encoding: .utf8) else { throw BrowserImportError(message: "Could not prepare password filling.") }
    return """
    (() => {
      const credential = \(json);
      if (window !== window.top || location.origin !== credential.origin) return false;
      const visible = el => !el.disabled && !el.readOnly && el.getClientRects().length > 0;
      const candidates = [...document.querySelectorAll('input[type="password"]')].filter(visible);
      const field = candidates.includes(document.activeElement) ? document.activeElement : candidates.length === 1 ? candidates[0] : null;
      if (!field || !field.form || new URL(field.form.action || location.href, location.href).origin !== credential.origin) return false;
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      const set = (el, value) => { setter.call(el, value); el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true})); };
      const users = [...field.form.querySelectorAll('input')].filter(el => visible(el) && ['text','email'].includes(el.type));
      const named = users.filter(el => el.autocomplete === 'username');
      const username = named.length === 1 ? named[0] : users.length === 1 ? users[0] : null;
      if (username) set(username, credential.username);
      set(field, credential.password);
      return true;
    })()
    """
}
