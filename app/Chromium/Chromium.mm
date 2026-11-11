#import "Chromium.h"

#include "include/cef_app.h"
#include "include/cef_client.h"
#include "include/cef_cookie.h"
#include "include/cef_parser.h"
#include "include/cef_devtools_message_observer.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/cef_application_mac.h"

#include <crt_externs.h>
#include <memory>
#include <set>
#include <utility>

namespace {

std::unique_ptr<CefScopedLibraryLoader> library;
bool initialized = false;
bool startupAttempted = false;
std::set<int> openBrowsers;
void (^shutdownCompletion)(void);
NSTimer *messageTimer;

void finishShutdown() {
    [messageTimer invalidate];
    messageTimer = nil;
    initialized = false;
    CefShutdown();
    library.reset();
}

NSString *string(const CefString &value) {
    return [NSString stringWithUTF8String:value.ToString().c_str()] ?: @"";
}

bool isWebURL(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    return ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) && url.host.length;
}

class SetCookieResult : public CefSetCookieCallback {
public:
    explicit SetCookieResult(void (^completion)(BOOL)) : completion_(completion) {}
    void OnComplete(bool success) override {
        auto completion = completion_;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
    }
private:
    void (^completion_)(BOOL);
    IMPLEMENT_REFCOUNTING(SetCookieResult);
};

class FlushCookieResult : public CefCompletionCallback {
public:
    explicit FlushCookieResult(void (^completion)(BOOL)) : completion_(completion) {}
    void OnComplete() override {
        auto completion = completion_;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
    }
private:
    void (^completion_)(BOOL);
    IMPLEMENT_REFCOUNTING(FlushCookieResult);
};

// Registration owns the observer until the response or bounded timeout releases it.
class FillResult : public CefDevToolsMessageObserver {
public:
    explicit FillResult(void (^completion)(BOOL)) : completion_(completion) {}
    CefRefPtr<CefRegistration> registration;
    int messageID = 0;
    void finish(bool success) {
        registration = nullptr;
        auto completion = std::exchange(completion_, nil);
        if (completion) completion(success);
    }
    void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int id, bool success,
                               const void *result, size_t size) override {
        if (id != messageID) return;
        bool filled = false;
        if (success) {
            auto parsed = CefParseJSON(CefString(static_cast<const char *>(result), size), JSON_PARSER_RFC);
            if (parsed && parsed->GetType() == VTYPE_DICTIONARY) {
                auto dictionary = parsed->GetDictionary();
                auto value = dictionary->GetDictionary("result");
                filled = value && value->GetBool("value");
            }
        }
        finish(filled);
    }
private:
    void (^completion_)(BOOL);
    IMPLEMENT_REFCOUNTING(FillResult);
};

class PageClient : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler,
                   public CefLoadHandler, public CefRequestHandler, public CefDownloadHandler,
                   public CefPermissionHandler, public CefJSDialogHandler {
public:
    explicit PageClient(FritzChromiumPage *owner, NSURL *url) : owner_(owner), url_(url) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
    CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
    CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        openBrowsers.insert(browser->GetIdentifier());
    }

    bool DoClose(CefRefPtr<CefBrowser> browser) override {
        // A tab owns a child view. CEF's default action closes the whole window.
        NSView *child = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([child.window.firstResponder isKindOfClass:NSView.class] &&
                [(NSView *)child.window.firstResponder isDescendantOf:child]) {
                [child.window makeFirstResponder:nil];
            }
            [child removeFromSuperview];
        });
        return true;
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        openBrowsers.erase(browser->GetIdentifier());
        if (openBrowsers.empty() && shutdownCompletion) {
            // Return to the AppKit loop before shutting down CEF.
            dispatch_async(dispatch_get_main_queue(), ^{
                auto completion = std::exchange(shutdownCompletion, nil);
                finishShutdown();
                completion();
            });
        }
    }

    bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, int,
                       const CefString &url, const CefString &, WindowOpenDisposition,
                       bool userGesture, const CefPopupFeatures &, CefWindowInfo &,
                       CefRefPtr<CefClient> &, CefBrowserSettings &,
                       CefRefPtr<CefDictionaryValue> &, bool *) override {
        if (userGesture && isWebURL([NSURL URLWithString:string(url)])) {
            browser->GetMainFrame()->LoadURL(url);
        }
        return true;
    }

    bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefRequest> request, bool, bool) override {
        return frame->IsMain() && !isWebURL([NSURL URLWithString:string(request->GetURL())]);
    }

    bool CanDownload(CefRefPtr<CefBrowser>, const CefString &, const CefString &) override {
        return false;
    }

    bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem>,
                          const CefString &, CefRefPtr<CefBeforeDownloadCallback>) override {
        return true;
    }

    bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                        const CefString &, uint32_t,
                                        CefRefPtr<CefMediaAccessCallback> callback) override {
        callback->Cancel();
        return true;
    }

    bool OnShowPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t, const CefString &, uint32_t,
                                CefRefPtr<CefPermissionPromptCallback> callback) override {
        callback->Continue(CEF_PERMISSION_RESULT_DENY);
        return true;
    }

    bool OnJSDialog(CefRefPtr<CefBrowser>, const CefString &, JSDialogType,
                    const CefString &, const CefString &, CefRefPtr<CefJSDialogCallback>,
                    bool &suppress) override {
        suppress = true;
        return false;
    }

    bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser>, const CefString &, bool,
                              CefRefPtr<CefJSDialogCallback> callback) override {
        callback->Continue(true, "");
        return true;
    }

    void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                         const CefString &url) override {
        NSURL *address = [NSURL URLWithString:string(url)];
        if (frame->IsMain() && isWebURL(address)) {
            url_ = address;
            publish(browser);
        }
    }

    void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString &title) override {
        title_ = string(title);
        publish(browser);
    }

    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool, bool, bool) override {
        publish(browser);
    }

    void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                     TransitionType) override {
        if (!frame->IsMain()) return;
        error_ = nil;
        publish(browser);
    }

    void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode code,
                     const CefString &error, const CefString &) override {
        if (frame->IsMain() && code != ERR_ABORTED) {
            error_ = [@"Could not load the page: " stringByAppendingString:string(error)];
            publish(browser);
        }
    }

    void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus, int,
                                   const CefString &) override {
        error_ = @"The page process closed. Reload to try again.";
        publish(browser);
    }

    void navigate(CefRefPtr<CefBrowser> browser, NSURL *url) {
        url_ = url;
        error_ = nil;
        publish(browser);
        browser->GetMainFrame()->LoadURL(url.absoluteString.UTF8String);
    }

    void publish(CefRefPtr<CefBrowser> browser) {
        auto change = owner_.onChange;
        if (change) {
            change(url_, title_ ?: @"", browser->IsLoading(), browser->CanGoBack(),
                   browser->CanGoForward(), error_);
        }
    }

private:
    __weak FritzChromiumPage *owner_;
    NSURL *url_;
    NSString *title_;
    NSString *error_;
    IMPLEMENT_REFCOUNTING(PageClient);
};

}  // namespace

@interface FritzChromiumApplication () <CefAppProtocol>
@property(nonatomic, assign, getter=isHandlingSendEvent) BOOL handlingSendEvent;
@end

@implementation FritzChromiumApplication
+ (void)prepare {
    [self sharedApplication];
}

- (void)sendEvent:(NSEvent *)event {
    if (initialized) {
        CefScopedSendingEvent sending;
        [super sendEvent:event];
    } else {
        [super sendEvent:event];
    }
}

+ (BOOL)startBrowserWithDataDirectory:(NSURL *)directory {
    if (startupAttempted) return initialized;
    startupAttempted = true;

    NSString *storage = [NSBundle.mainBundle objectForInfoDictionaryKey:@"FritzBrowserStorageIdentifier"];
    NSString *service = [NSBundle.mainBundle objectForInfoDictionaryKey:@"FritzBrowserKeychainService"];
    NSString *account = [NSBundle.mainBundle objectForInfoDictionaryKey:@"FritzBrowserKeychainAccount"];
    if (![NSApp isKindOfClass:self] || !storage.length || !service.length || !account.length) return NO;
    directory = [directory URLByAppendingPathComponent:storage isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                               withIntermediateDirectories:YES attributes:nil error:nullptr]) return NO;

    library = std::make_unique<CefScopedLibraryLoader>();
    if (!library->LoadInMain()) return NO;

    CefSettings settings;
    settings.command_line_args_disabled = true;
    settings.log_severity = LOGSEVERITY_ERROR;
    CefString(&settings.log_file) = [directory URLByAppendingPathComponent:@"chromium.log"].path.UTF8String;
    CefString(&settings.root_cache_path) = directory.path.UTF8String;
    CefString(&settings.cache_path) = directory.path.UTF8String;
    CefString(&settings.keychain_service_name) = service.UTF8String;
    CefString(&settings.keychain_account_name) = account.UTF8String;
    CefMainArgs args(*_NSGetArgc(), *_NSGetArgv());
    initialized = CefInitialize(args, settings, nullptr, nullptr);
    if (initialized) {
        messageTimer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *) {
            CefDoMessageLoopWork();
        }];
        [NSRunLoop.mainRunLoop addTimer:messageTimer forMode:NSDefaultRunLoopMode];
    }
    return initialized;
}

+ (BOOL)finishBrowserShutdown:(void (^)(void))completion {
    if (!initialized) return YES;
    if (openBrowsers.empty()) {
        finishShutdown();
        return YES;
    }
    shutdownCompletion = completion;
    return NO;
}
@end

@implementation FritzChromiumPage {
    CefRefPtr<PageClient> _client;
    CefRefPtr<CefBrowser> _browser;
    CefRefPtr<FillResult> _fill;
}

+ (void)setCookieWithURL:(NSURL *)url name:(NSString *)name value:(NSString *)value
                  domain:(NSString *)domain path:(NSString *)path secure:(BOOL)secure
                httpOnly:(BOOL)httpOnly expires:(NSDate *)expires sameSite:(NSInteger)sameSite
              completion:(void (^)(BOOL))completion {
    if (!initialized) { completion(NO); return; }
    CefCookie cookie;
    CefString(&cookie.name) = name.UTF8String;
    CefString(&cookie.value) = value.UTF8String;
    CefString(&cookie.domain) = domain.UTF8String;
    CefString(&cookie.path) = path.UTF8String;
    cookie.secure = secure;
    cookie.httponly = httpOnly;
    cookie.has_expires = expires != nil;
    if (expires) cookie.expires.val = (int64_t)((expires.timeIntervalSince1970 + 11644473600.0) * 1000000.0);
    cookie.same_site = sameSite == 0 ? CEF_COOKIE_SAME_SITE_NO_RESTRICTION :
                       sameSite == 1 ? CEF_COOKIE_SAME_SITE_LAX_MODE :
                       sameSite == 2 ? CEF_COOKIE_SAME_SITE_STRICT_MODE : CEF_COOKIE_SAME_SITE_UNSPECIFIED;
    auto manager = CefCookieManager::GetGlobalManager(nullptr);
    if (!manager || !manager->SetCookie(url.absoluteString.UTF8String, cookie, new SetCookieResult(completion))) completion(NO);
}

+ (void)flushCookies:(void (^)(BOOL))completion {
    if (!initialized) { completion(NO); return; }
    auto manager = CefCookieManager::GetGlobalManager(nullptr);
    if (!manager || !manager->FlushStore(new FlushCookieResult(completion))) completion(NO);
}

- (void)evaluateFillScript:(NSString *)script completion:(void (^)(BOOL))completion {
    if (!_browser) { completion(NO); return; }
    if (_fill) _fill->finish(false);
    CefRefPtr<FillResult> observer = new FillResult(completion);
    _fill = observer;
    observer->registration = _browser->GetHost()->AddDevToolsMessageObserver(observer);
    auto parameters = CefDictionaryValue::Create();
    parameters->SetString("expression", script.UTF8String);
    parameters->SetBool("returnByValue", true);
    observer->messageID = _browser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.evaluate", parameters);
    if (!observer->messageID) observer->finish(false);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        observer->finish(false);
    });
}

- (instancetype)init {
    self = [super init];
    if (self) _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    return self;
}

- (void)load:(NSURL *)url {
    if (!_browser) {
        if (!initialized) {
            if (self.onChange) self.onChange(url, @"", NO, NO, NO, @"Chromium could not start.");
            return;
        }
        _client = new PageClient(self, url);
        CefWindowInfo window;
        window.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
        window.SetAsChild((__bridge CefWindowHandle)self.view, CefRect(0, 0, NSWidth(self.view.bounds),
                                                                       NSHeight(self.view.bounds)));
        CefBrowserSettings settings;
        _browser = CefBrowserHost::CreateBrowserSync(window, _client, url.absoluteString.UTF8String,
                                                     settings, nullptr, nullptr);
        if (!_browser) {
            if (self.onChange) self.onChange(url, @"", NO, NO, NO, @"Chromium could not open a page.");
        } else {
            _client->publish(_browser);
        }
        return;
    }
    _client->navigate(_browser, url);
}

- (void)goBack { if (_browser) _browser->GoBack(); }
- (void)goForward { if (_browser) _browser->GoForward(); }
- (void)reload { if (_browser) _browser->Reload(); }
- (void)stop { if (_browser) _browser->StopLoad(); }
- (void)close {
    if (_fill) { _fill->finish(false); _fill = nullptr; }
    self.onChange = nil;
    if (_browser) {
        _browser->GetHost()->CloseBrowser(true);
        _browser = nullptr;
        _client = nullptr;
    }
}
@end
