#import <Foundation/Foundation.h>

// Signed IPC broker for the AutoFill extension: listener, peer validation,
// catalog scoping and single-use grants. Subclasses supply the data.
API_AVAILABLE(macos(13.0))
@interface MPAutoFillServer : NSObject
@property (readonly, getter=isListening) BOOL listening;
// Idempotent; returns NO after stop or if the socket cannot be bound.
- (BOOL)startServer;
// Closes the listener and drops all grants. startServer may be called again.
- (void)stopServer;
// Terminal: closes the listener; no further credential delivery.
- (void)stop;
- (void)invalidateGrants;
- (void)catalogDidChange;

// Subclass hooks, called on the main queue. prepareForRequest runs once per
// ordinary request; subscriptions query no data. The other hooks never prepare again.
- (void)prepareForRequest;
// ready, locked, conflict, disabled or noDocuments. Entries only when ready.
- (NSString *)providerStatus;
// Metadata of all eligible records in listing order; never passwords. A
// catalog reply lists the first matches.
- (NSArray<NSDictionary *> *)catalogEntries;
// binding: the host, port and user the picker displayed for this record. The
// password is issued only while the live entry still matches them.
- (NSDictionary *)credentialForRecord:(NSString *)record expecting:(NSDictionary *)binding;
// Shows the active database's unlock view once MacPass is frontmost.
- (BOOL)requestUnlock;
@end
