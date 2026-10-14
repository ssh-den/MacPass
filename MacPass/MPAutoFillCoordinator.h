#import "MPAutoFillServer.h"

@class MPDocument;

FOUNDATION_EXPORT NSString *const MPAutoFillEnabledPreference;
FOUNDATION_EXPORT NSString *const MPAutoFillDocumentsChangedNotification;

// Serves only the active (most recently focused) unlocked database. Locked,
// conflicting and background databases contribute no metadata.
API_AVAILABLE(macos(13.0))
@interface MPAutoFillCoordinator : MPAutoFillServer
// Always returns a coordinator. It listens while the preference is on, and
// otherwise only as long as identities published earlier must be cleared.
+ (instancetype)start;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults NS_DESIGNATED_INITIALIZER;
// Ends secret delivery at once, then clears identities this instance may have
// published and stops. Call only while listening; otherwise there is nothing to clear.
- (void)prepareForTerminationWithCompletion:(void (^)(void))completion;
// The database an AutoFill activation should bring forward: the one of a pending
// unlock handoff, else the active one. Raising any other would switch databases.
- (MPDocument *)documentToReveal;
@end
