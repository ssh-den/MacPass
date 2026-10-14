#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MPAutoFillErrorDomain;
typedef NS_ENUM(NSInteger, MPAutoFillErrorCode) {
  MPAutoFillErrorConfiguration = 1,    // Team identifier missing or invalid
  MPAutoFillErrorSocketPath = 2,       // No App Group container or path too long
  MPAutoFillErrorPeerRejected = 3,     // Peer is not the expected signed MacPass code
  MPAutoFillErrorTransport = 4,
  MPAutoFillErrorMessage = 5,          // Malformed or oversized frame
  MPAutoFillErrorListenerOccupied = 6, // Another signed MacPass instance listens
  MPAutoFillErrorNoListener = 7,       // MacPass is not running or not serving
  MPAutoFillErrorClosed = 8            // Peer closed without sending anything
};

// Protocol values shared by MacPass and the extension.
FOUNDATION_EXPORT NSString *const MPAutoFillOperationCatalog;
FOUNDATION_EXPORT NSString *const MPAutoFillOperationCredential;
FOUNDATION_EXPORT NSString *const MPAutoFillOperationCancel;
FOUNDATION_EXPORT NSString *const MPAutoFillOperationUnlock;
FOUNDATION_EXPORT NSString *const MPAutoFillOperationSubscribe;
FOUNDATION_EXPORT NSString *const MPAutoFillStatusReady;
FOUNDATION_EXPORT NSString *const MPAutoFillStatusLocked;
FOUNDATION_EXPORT NSString *const MPAutoFillStatusConflict;
FOUNDATION_EXPORT NSString *const MPAutoFillStatusDisabled;
FOUNDATION_EXPORT NSString *const MPAutoFillStatusNoDocuments;
FOUNDATION_EXPORT NSString *const MPAutoFillStatusTooLarge;
FOUNDATION_EXPORT NSString *const MPAutoFillStatusStale;
FOUNDATION_EXPORT NSString *const MPAutoFillStatusUnavailable;
FOUNDATION_EXPORT NSString *const MPAutoFillStatusAccepted;
FOUNDATION_EXPORT NSString *const MPAutoFillStatusCancelled;
FOUNDATION_EXPORT NSString *const MPAutoFillStatusSubscribed;
// A catalog's optional search, in UTF-16 code units.
FOUNDATION_EXPORT const NSUInteger MPAutoFillMaximumQueryLength;
// Subscription events carry no data.
FOUNDATION_EXPORT NSString *const MPAutoFillEventInvalidate;
FOUNDATION_EXPORT NSString *const MPAutoFillEventCatalogChanged;

FOUNDATION_EXPORT NSString *MPAutoFillAppIdentifier(void);
// Only ready (fill) and locked (unlock handoff) catalogs leave a grant in the host.
FOUNDATION_EXPORT BOOL MPAutoFillStatusIssuesGrant(id _Nullable status);
// One socket per app identifier in the team's App Group container.
FOUNDATION_EXPORT NSURL * _Nullable MPAutoFillSocketURL(NSError **error);
// hardened: also require hardened runtime and no debugging. The host demands it
// of the extension, whose owner authentication it relies on.
FOUNDATION_EXPORT BOOL MPAutoFillValidatePeer(int socket, NSString *identifier, BOOL hardened, NSData * _Nullable * _Nullable auditToken, NSError **error);
FOUNDATION_EXPORT NSDictionary * _Nullable MPAutoFillReadMessage(int socket, NSError **error);
FOUNDATION_EXPORT BOOL MPAutoFillWriteMessage(int socket, NSDictionary *message, NSError **error);
// A length-prefixed frame, and a blocking write of what remains from offset.
FOUNDATION_EXPORT NSData * _Nullable MPAutoFillEncodeMessage(NSDictionary *message, NSError **error);
FOUNDATION_EXPORT BOOL MPAutoFillWriteFrame(int socket, NSData *frame, NSUInteger offset, NSError **error);
FOUNDATION_EXPORT BOOL MPAutoFillValidateRequest(NSDictionary *message);
FOUNDATION_EXPORT NSDictionary * _Nullable MPAutoFillExchange(NSDictionary *message, NSError **error);
FOUNDATION_EXPORT int MPAutoFillCreateListener(NSError **error);
FOUNDATION_EXPORT void MPAutoFillConfigureSocket(int socket);
// Logs codes and the failing phase only, never message contents.
FOUNDATION_EXPORT void MPAutoFillLogError(NSString *context, NSError * _Nullable error);

// Owns the descriptor from init onward. Call start after installing the owner;
// callbacks run on the main queue. Closing is idempotent and is unsubscribe.
@interface MPAutoFillStream : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithSocket:(int)socket;
- (void)startWithMessageHandler:(void (^)(NSDictionary *message))messageHandler
                 closeHandler:(void (^)(void))closeHandler;
- (void)sendMessage:(NSDictionary *)message;
- (void)close;
@end
// Connects/validates the host and waits for registration acknowledgement on a worker.
FOUNDATION_EXPORT MPAutoFillStream * _Nullable MPAutoFillSubscribe(NSString *request, NSError **error);

NS_ASSUME_NONNULL_END
