#import "MPAutoFillRequestState.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import "../AutoFillShared/MPAutoFillDomain.h"
#import "../AutoFillShared/MPAutoFillTransport.h"

@interface MPAutoFillRequestState ()
@property (readwrite) NSUInteger generation;
@property (readwrite) BOOL finished;
@end

@implementation MPAutoFillRequestState

- (instancetype)init {
  if((self = [super init])) _services = @[];
  return self;
}

+ (BOOL)isWebServiceIdentifier:(ASCredentialServiceIdentifier *)identifier {
  // App IDs and future identifier types must never be interpreted as DNS names.
  return identifier && (identifier.type == ASCredentialServiceIdentifierTypeDomain || identifier.type == ASCredentialServiceIdentifierTypeURL);
}

+ (NSArray<NSDictionary *> *)servicesForIdentifiers:(NSArray<ASCredentialServiceIdentifier *> *)identifiers {
  NSMutableArray *services = NSMutableArray.array;
  for(ASCredentialServiceIdentifier *identifier in identifiers) {
    NSDictionary *service = [self isWebServiceIdentifier:identifier] ? MPAutoFillNormalizedService(identifier.identifier) : nil;
    if(service && ![services containsObject:service] && services.count < 16) [services addObject:service];
  }
  return services;
}

- (BOOL)beginForIdentity:(ASPasswordCredentialIdentity *)identity {
  NSAssert(NSThread.isMainThread, @"AutoFill request state must stay on the main thread");
  [self discard];
  self.finished = NO;
  self.started = NO;
  self.didProcessFirstCatalog = NO;
  self.requestIdentifier = NSUUID.UUID.UUIDString;
  self.record = identity.recordIdentifier;
  self.fillSelectedIdentity = identity != nil;
  if(!identity) return YES;
  if(![self.class isWebServiceIdentifier:identity.serviceIdentifier]) return NO;
  // A saved identity's service is not the current browser URL.
  self.identityHost = MPAutoFillNormalizedHost(identity.serviceIdentifier.identifier);
  self.identityUser = identity.user;
  return self.record.length > 0 && self.record.length <= 512 && self.identityHost.length > 0;
}

- (BOOL)acceptsGeneration:(NSUInteger)generation {
  return self.requestIdentifier != nil && !self.finished && self.generation == generation;
}

- (void)clearEntries {
  self.entries = nil;
  self.moreEntries = NO;
}

- (void)advanceGeneration {
  NSAssert(NSThread.isMainThread, @"AutoFill request state must stay on the main thread");
  self.generation++;
}

- (BOOL)ownerAuthenticated {
  return !self.finished && self.authenticatedUntil > NSProcessInfo.processInfo.systemUptime;
}

- (BOOL)grantAvailable {
  return !self.finished && self.hasGrant && self.grantDeadline > NSProcessInfo.processInfo.systemUptime;
}

- (BOOL)finish {
  NSAssert(NSThread.isMainThread, @"AutoFill request state must stay on the main thread");
  if(self.finished) return NO;
  self.finished = YES;
  self.busy = NO;
  [self releaseResources];
  return YES;
}

- (void)clearAuthentication {
  LAContext *context = self.authenticationContext;
  self.authenticationContext = nil; // Ignore invalidate's late reply.
  self.authenticationEmbedded = NO;
  [context invalidate];
}

// Subscription, deadlines and authentication; shared by finish and discard.
- (void)releaseResources {
  MPAutoFillStream *stream = self.subscription;
  self.subscription = nil; // Detach before close; ignore even an inline callback.
  [stream close];
  [self invalidateAccess];
}

- (void)invalidateAccess {
  [self advanceGeneration];
  [self.deadlineTimer invalidate]; self.deadlineTimer = nil;
  [self clearAuthentication];
  self.afterAuthentication = nil;
  self.authenticatedUntil = 0;
  self.restorePickerOnCancel = NO;
  self.grantDeadline = 0;
  self.hasGrant = NO;
  [self clearEntries];
  self.catalogStatus = nil;
  self.showAll = NO;
  self.busy = NO;
  self.refreshingCatalog = NO;
  self.pendingCatalogRefresh = NO;
  self.didProcessFirstCatalog = YES; // External changes never auto-fill.
  // Retain a system suggestion as request input, never a manual row selection.
  if(!self.fillSelectedIdentity) self.record = nil;
}

- (void)discard {
  [self releaseResources];
  self.requestIdentifier = nil;
  self.record = nil;
  self.services = @[];
  self.identityHost = nil;
  self.identityUser = nil;
}

- (void)dealloc { [self releaseResources]; }
@end
