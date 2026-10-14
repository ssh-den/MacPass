#import <Foundation/Foundation.h>
#import <AuthenticationServices/AuthenticationServices.h>

@class LAContext;
@class MPAutoFillStream;

NS_ASSUME_NONNULL_BEGIN

// Main-thread request state only. No views, database access or credentials.
API_AVAILABLE(macos(13.0))
@interface MPAutoFillRequestState : NSObject
@property (copy, nullable) NSString *requestIdentifier;
// The host holds an unused grant for requestIdentifier (bound to this process).
@property BOOL hasGrant;
@property (copy, nullable) NSString *record;
@property (readonly) NSUInteger generation;
@property (readonly) BOOL finished;
@property BOOL started;
@property BOOL busy;
@property BOOL fillSelectedIdentity;
@property BOOL showAll;
@property (nullable) NSArray<NSDictionary *> *entries;
// The host matched more accounts than it listed in entries.
@property BOOL moreEntries;
@property NSArray<NSDictionary *> *services;
@property (copy, nullable) NSString *identityHost;
@property (copy, nullable) NSString *identityUser;
@property (nullable) LAContext *authenticationContext;
// The context evaluates in the embedded view, which offers the system fallback.
@property BOOL authenticationEmbedded;
@property (copy, nullable) void (^afterAuthentication)(void);
@property BOOL restorePickerOnCancel;
@property NSTimeInterval authenticatedUntil;
@property (readonly) BOOL ownerAuthenticated;
@property (nullable) MPAutoFillStream *subscription;
// One-shot for the earlier of owner-authentication expiry and host grant renewal.
@property (nullable) NSTimer *deadlineTimer;
@property NSTimeInterval grantDeadline;
@property (readonly) BOOL grantAvailable;
@property BOOL refreshingCatalog;
@property BOOL pendingCatalogRefresh;
@property BOOL didProcessFirstCatalog;
@property (copy, nullable) NSString *catalogStatus;

+ (BOOL)isWebServiceIdentifier:(ASCredentialServiceIdentifier *)identifier;
+ (NSArray<NSDictionary *> *)servicesForIdentifiers:(NSArray<ASCredentialServiceIdentifier *> *)identifiers;
- (BOOL)beginForIdentity:(nullable ASPasswordCredentialIdentity *)identity;
- (BOOL)acceptsGeneration:(NSUInteger)generation;
// Forgets the listed accounts and that the host held some back.
- (void)clearEntries;
- (void)advanceGeneration;
// Marks completion once and stops pending resources. Cancel/consume the grant first.
- (BOOL)finish;
- (void)clearAuthentication;
- (void)invalidateAccess;
- (void)discard;
@end

NS_ASSUME_NONNULL_END
