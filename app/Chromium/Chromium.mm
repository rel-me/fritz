#import "Chromium.h"

#include "include/cef_app.h"
#include "include/cef_client.h"
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
    self.onChange = nil;
    if (_browser) {
        _browser->GetHost()->CloseBrowser(true);
        _browser = nullptr;
        _client = nullptr;
    }
}
@end
