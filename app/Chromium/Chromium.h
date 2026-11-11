#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FritzChromiumApplication : NSApplication
+ (void)prepare;
+ (BOOL)startBrowserWithDataDirectory:(NSURL *)directory NS_SWIFT_NAME(startBrowser(dataDirectory:));
+ (BOOL)finishBrowserShutdown:(void (^)(void))completion;
@end

typedef void (^FritzChromiumChange)(NSURL *_Nullable url, NSString *title, BOOL loading,
                                    BOOL back, BOOL forward, NSString *_Nullable error);

NS_SWIFT_UI_ACTOR
@interface FritzChromiumPage : NSObject
@property(nonatomic, readonly) NSView *view;
@property(nonatomic, copy, nullable) FritzChromiumChange onChange;
+ (void)setCookieWithURL:(NSURL *)url name:(NSString *)name value:(NSString *)value
                  domain:(NSString *)domain path:(NSString *)path secure:(BOOL)secure
                httpOnly:(BOOL)httpOnly expires:(NSDate *_Nullable)expires sameSite:(NSInteger)sameSite
              completion:(void (^)(BOOL))completion NS_SWIFT_NAME(setCookie(url:name:value:domain:path:secure:httpOnly:expires:sameSite:completion:));
+ (void)flushCookies:(void (^)(BOOL))completion;
- (void)evaluateFillScript:(NSString *)script completion:(void (^)(BOOL))completion;
- (void)load:(NSURL *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stop;
- (void)close;
@end

NS_ASSUME_NONNULL_END
