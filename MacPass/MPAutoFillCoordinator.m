#import "MPAutoFillCoordinator.h"
#import "MPDocument.h"
#import "MPDocumentWindowController.h"
#import "../AutoFillShared/MPAutoFillDomain.h"
#import "../AutoFillShared/MPAutoFillTransport.h"
#import <AuthenticationServices/AuthenticationServices.h>

NSString *const MPAutoFillEnabledPreference = @"NativeAutoFillEnabled";
NSString *const MPAutoFillDocumentsChangedNotification = @"MacPass.AutoFill.DocumentsChanged";
// Internal state, not a setting. NO only after an empty publication or a clear
// succeeded, so a launch with the feature off normally leaves the store alone.
static NSString *const MPAutoFillIndexMayHoldIdentitiesKey = @"NativeAutoFillIndexMayHoldIdentities";
// Edits are coalesced; requests and locking never wait for this delay.
static const NSTimeInterval MPAutoFillRefreshDelay = 0.5;
static const NSTimeInterval MPAutoFillRetryInterval = 60;
// The unlock view appears only if MacPass becomes frontmost within this time.
static const NSTimeInterval MPAutoFillUnlockInterval = 15;
// Values containing braces that one resolution may parse.
static const NSUInteger MPResolutionBudget = 2048;
static void *MPAutoFillEnabledContext = &MPAutoFillEnabledContext;

@interface MPAutoFillCoordinator ()
@property NSUserDefaults *defaults;
@property NSString *session;
@property NSMapTable<MPDocument *, NSString *> *documentIdentifiers;
@property NSMutableDictionary<NSString *, NSDictionary *> *metadata;
@property NSArray<NSDictionary *> *catalog;
@property (weak) MPDocument *lastActiveDocument;
@property NSString *catalogDocument;
@property NSString *catalogStatus;
@property BOOL enabled;
// Terminal: no catalog, no publication, no credentials.
@property BOOL quitting;
@property BOOL catalogDirty;
@property NSUInteger refreshGeneration;
@property NSTimer *expirationTimer;
@property BOOL retryScheduled;
// The identity store must be written: changed catalog, failed write, takeover.
@property BOOL indexDirty;
@property BOOL indexBusy;
@property (nonatomic) BOOL indexMayHoldIdentities;
@property NSTimeInterval unlockDeadline;
@property (weak) MPDocument *unlockDocument;
@property (copy) void (^pendingTermination)(void);
@end

@implementation MPAutoFillCoordinator

+ (instancetype)start {
  MPAutoFillCoordinator *coordinator = [[self alloc] init];
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  // Every edit, undo and redo reaches updateChangeCount:, which MPDocument posts.
  for(NSString *name in @[MPAutoFillDocumentsChangedNotification, MPDocumentDidLockDatabaseNotification,
                        MPDocumentDidUnlockDatabaseNotification, MPDocumentDidRevertNotification, NSWindowDidBecomeMainNotification]) {
    [center addObserver:coordinator selector:@selector(documentsChanged:) name:name object:nil];
  }
  [center addObserver:coordinator selector:@selector(applicationDidBecomeActive:) name:NSApplicationDidBecomeActiveNotification object:nil];
  // Also replaces identities a crash left behind.
  [coordinator refreshCatalog];
  return coordinator;
}

- (instancetype)init {
  return [self initWithDefaults:NSUserDefaults.standardUserDefaults];
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
  if((self = [super init])) {
    _defaults = defaults;
    _session = NSUUID.UUID.UUIDString;
    _documentIdentifiers = [NSMapTable weakToStrongObjectsMapTable];
    _metadata = NSMutableDictionary.dictionary;
    _catalog = @[];
    _catalogDirty = YES;
    _enabled = [defaults boolForKey:MPAutoFillEnabledPreference];
    _indexDirty = _enabled || [defaults boolForKey:MPAutoFillIndexMayHoldIdentitiesKey];
    [defaults addObserver:self forKeyPath:MPAutoFillEnabledPreference options:0 context:MPAutoFillEnabledContext];
  }
  return self;
}

- (void)dealloc {
  [_defaults removeObserver:self forKeyPath:MPAutoFillEnabledPreference context:MPAutoFillEnabledContext];
  [NSNotificationCenter.defaultCenter removeObserver:self]; // Registered in +start.
}

- (BOOL)indexMayHoldIdentities { return [self.defaults boolForKey:MPAutoFillIndexMayHoldIdentitiesKey]; }
- (void)setIndexMayHoldIdentities:(BOOL)value {
  if(value != self.indexMayHoldIdentities) [self.defaults setBool:value forKey:MPAutoFillIndexMayHoldIdentitiesKey];
}

#pragma mark Listener and change tracking

// Listens while enabled. While disabled, only until earlier identities are
// cleared: new requests see "disabled", but the store keeps a single writer.
- (void)updateServer {
  if(self.quitting) return;
  BOOL needed = self.enabled || (self.indexDirty && self.indexMayHoldIdentities);
  if(needed && !self.isListening) {
    // While another MacPass instance listens, this one tries again on its next
    // change or activation. Taking over the listener also takes over the
    // identity store: publish this instance's records.
    if([self startServer]) self.indexDirty = YES;
  }
  else if(!needed && self.isListening) [self stopServer];
}

// Retries a failed store write without spinning on a busy store.
- (void)scheduleRetry {
  if(self.retryScheduled || self.quitting) return;
  self.retryScheduled = YES;
  __weak MPAutoFillCoordinator *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MPAutoFillRetryInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    MPAutoFillCoordinator *coordinator = weakSelf;
    coordinator.retryScheduled = NO;
    [coordinator updateServer];
    [coordinator publishIndex];
  });
}

- (void)documentsChanged:(NSNotification *)notification {
  if(!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self documentsChanged:notification]; }); return;
  }
  if([notification.name isEqual:NSWindowDidBecomeMainNotification]) {
    id document = [[notification.object windowController] document];
    if(![document isKindOfClass:MPDocument.class] || document == self.lastActiveDocument) return;
    self.lastActiveDocument = document;
  }
  [self setNeedsRefresh];
  // Availability changes must not wait for the ordinary metadata debounce.
  if([self availabilityHasChanged]) [self prepareForRequest];
}

// Coalesces bursts of edits into one rebuild after a short pause.
- (void)setNeedsRefresh {
  self.catalogDirty = YES;
  if(self.quitting) return;
  NSUInteger generation = ++self.refreshGeneration;
  __weak MPAutoFillCoordinator *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MPAutoFillRefreshDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    MPAutoFillCoordinator *coordinator = weakSelf;
    if(coordinator.refreshGeneration == generation) [coordinator prepareForRequest];
  });
}

- (void)prepareForRequest {
  if(self.catalogDirty) [self refreshCatalog];
  else [self publishIndex];
}

// Expired entries leave the catalog without a model edit.
- (void)scheduleExpirationRefreshAt:(NSDate *)date {
  [self.expirationTimer invalidate];
  self.expirationTimer = nil;
  if(!date || self.quitting) return;
  __weak MPAutoFillCoordinator *weakSelf = self;
  // A wall-clock timer, so it also fires late after sleep rather than never.
  self.expirationTimer = [[NSTimer alloc] initWithFireDate:[date dateByAddingTimeInterval:1] interval:0 repeats:NO block:^(NSTimer *timer) {
    [weakSelf setNeedsRefresh];
  }];
  [NSRunLoop.mainRunLoop addTimer:self.expirationTimer forMode:NSRunLoopCommonModes];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
  if(context == MPAutoFillEnabledContext) [self enabledPreferenceChanged];
  else [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)enabledPreferenceChanged {
  dispatch_async(dispatch_get_main_queue(), ^{
    BOOL enabled = [self.defaults boolForKey:MPAutoFillEnabledPreference];
    if(self.enabled == enabled || self.quitting) return;
    self.enabled = enabled;
    self.indexDirty = YES;
    [self updateServer];
    [self refreshCatalog];
  });
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
  [self showPendingUnlock];
  // E.g. the provider was just turned on in System Settings.
  [self publishIndex];
}

#pragma mark Catalog

- (NSArray<MPDocument *> *)openDocuments { return NSDocumentController.sharedDocumentController.documents; }

// The most recently focused document window; with none, the frontmost one.
- (MPDocument *)activeDocument {
  NSArray *documents = self.openDocuments;
  MPDocument *document = self.lastActiveDocument;
  if(document && [documents containsObject:document]) return document;
  for(NSWindow *window in NSApp.orderedWindows) {
    id candidate = window.windowController.document;
    if(candidate && [documents containsObject:candidate]) return candidate;
  }
  return documents.count == 1 ? documents.firstObject : nil;
}

- (NSString *)providerStatus {
  if(!self.enabled || self.quitting) return MPAutoFillStatusDisabled;
  MPDocument *document = self.activeDocument;
  if(!document) return MPAutoFillStatusNoDocuments;
  if(document.encrypted) return MPAutoFillStatusLocked;
  if(document.autoFillUnavailable) return MPAutoFillStatusConflict;
  return MPAutoFillStatusReady;
}

// Shared by notifications and rebuilds: this is the only comparison that ends
// access when the active database/status changes, including locked-to-locked switches.
- (BOOL)availabilityHasChanged {
  MPDocument *document = self.activeDocument;
  NSString *documentID = document ? [self identifierForDocument:document] : nil;
  NSString *status = self.providerStatus;
  return !(documentID == self.catalogDocument || [documentID isEqual:self.catalogDocument]) || ![status isEqual:self.catalogStatus];
}

// KeePass leaves unknown {TOKENS} literal, so literal braces are valid password
// characters. Reject only what MacPass would substitute, plus interactive and
// one-time values even where they stay unresolved. The read-only, non-interactive
// KeePassKit pass has no side effects (no OTP counter update, no pick dialogs);
// its result is used for detection only, never filled.
- (BOOL)containsPlaceholder:(NSString *)value entry:(KPKEntry *)entry {
  if([value rangeOfString:@"{"].location == NSNotFound) return NO;
  static NSRegularExpression *dynamic;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ dynamic = [NSRegularExpression regularExpressionWithPattern:@"\\{(PICKCHARS|PICKFIELD|TOTP|TIMEOTP|HMACOTP)[^{}]*\\}" options:NSRegularExpressionCaseInsensitive error:nil]; });
  if([dynamic firstMatchInString:value options:0 range:NSMakeRange(0, value.length)]) return YES;
  NSString *evaluated = [value kpk_finalValueForEntry:entry options:KPKCommandEvaluationOptionSkipUserInteraction | KPKCommandEvaluationOptionReadOnly];
  return ![evaluated isEqualToString:value];
}

// Only {REF:<field>@I:<uuid>} is resolved: the form KeePass writes when it
// duplicates an entry with references. A search reference (@T, @U, @P, @A, @N,
// @O) depends on KeePassKit's search order and makes the value unavailable.
// Command, OTP and interactive placeholders never execute here. visiting holds
// the references being resolved; the budget bounds the values that need parsing.
- (NSString *)resolveValue:(NSString *)value entry:(KPKEntry *)entry secrets:(BOOL)secrets visiting:(NSMutableSet *)visiting budget:(NSUInteger *)budget {
  if(!value) return @"";
  if([value rangeOfString:@"{"].location == NSNotFound) return value;
  if(value.length > 65536 || visiting.count > 10 || *budget == 0) return nil;
  (*budget)--;
  static NSRegularExpression *references;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ references = [NSRegularExpression regularExpressionWithPattern:@"\\{REF:([TUPANI])@([TUPANIO]):([^}]*)\\}" options:NSRegularExpressionCaseInsensitive error:nil]; });
  NSArray<NSTextCheckingResult *> *matches = [references matchesInString:value options:0 range:NSMakeRange(0, value.length)];
  NSMutableString *unparsed = [value mutableCopy];
  for(NSTextCheckingResult *match in matches.reverseObjectEnumerator) [unparsed replaceCharactersInRange:match.range withString:@""];
  if([self containsPlaceholder:unparsed entry:entry]) return nil;
  if(matches.count == 0) return value;
  NSDictionary *fields = @{@"T": kKPKTitleKey, @"U": kKPKUsernameKey, @"P": kKPKPasswordKey, @"A": kKPKURLKey, @"N": kKPKNotesKey};
  NSMutableString *result = [value mutableCopy];
  for(NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
    NSString *wanted = [[value substringWithRange:[match rangeAtIndex:1]] uppercaseString];
    NSString *search = [[value substringWithRange:[match rangeAtIndex:2]] uppercaseString];
    NSString *criteria = [value substringWithRange:[match rangeAtIndex:3]];
    if(![search isEqual:@"I"]) return nil;
    // Metadata must never turn a password/notes reference into a system identity.
    if(!secrets && [@[@"P", @"N"] containsObject:wanted]) return nil;
    NSUUID *uuid = criteria.length == 32 ? [[NSUUID alloc] initWithUndelemittedUUIDString:criteria] : [[NSUUID alloc] initWithUUIDString:criteria];
    KPKEntry *target = uuid ? [entry.tree.root entryForUUID:uuid] : nil;
    if(!target || target.isTrashed || target.timeInfo.isExpired) return nil;
    NSString *key = [NSString stringWithFormat:@"%@:%@", target.uuid.UUIDString, wanted];
    if([visiting containsObject:key]) return nil;
    [visiting addObject:key];
    NSString *replacement = [wanted isEqual:@"I"] ? target.uuid.UUIDString : [self resolveValue:[target valueForAttributeWithKey:fields[wanted]] entry:target secrets:secrets visiting:visiting budget:budget];
    [visiting removeObject:key];
    if(!replacement) return nil;
    [result replaceCharactersInRange:match.range withString:replacement];
    if(result.length > 65536) return nil;
  }
  // Substitution can join fragments into a new placeholder or reference, e.g.
  // "{TOT" from a source and "P}" after the reference; apply the same rules again.
  return [self containsPlaceholder:result entry:entry] ? nil : result;
}

// Always resolved against the live tree, so a fill never uses an older value.
- (NSString *)value:(NSString *)value entry:(KPKEntry *)entry secrets:(BOOL)secrets {
  NSUInteger budget = MPResolutionBudget;
  return [self resolveValue:value entry:entry secrets:secrets visiting:NSMutableSet.set budget:&budget];
}

// The catalog and the final fill apply the same rule. Groups with searching
// disabled (KeePass semantics) never take part; the catalog gets that from
// enumerating searchableChildEntries, a single entry is looked up in it.
- (BOOL)isFillable:(KPKEntry *)entry {
  return entry && !entry.isTrashed && !entry.timeInfo.isExpired && !entry.isUserTemplate && entry.password.length > 0;
}

// The rest of that rule, on resolved values: user, host and port as the picker
// shows them, and the password only if user, URL and a non-empty password resolve.
- (NSDictionary *)fillValuesForEntry:(KPKEntry *)entry {
  NSString *user = [self value:entry.username entry:entry secrets:NO];
  NSString *url = [self value:entry.url entry:entry secrets:NO];
  NSString *password = [self value:entry.password entry:entry secrets:YES];
  NSDictionary *service = MPAutoFillNormalizedService(url ?: @"") ?: @{@"host": @"", @"port": @""};
  NSMutableDictionary *values = [@{@"user": user ?: @"", @"host": service[@"host"], @"port": service[@"port"]} mutableCopy];
  if(user && url && password.length) values[@"password"] = password;
  return values;
}

- (NSString *)identifierForDocument:(MPDocument *)document {
  NSString *identifier = [self.documentIdentifiers objectForKey:document];
  if(!identifier) {
    identifier = NSUUID.UUID.UUIDString;
    [self.documentIdentifiers setObject:identifier forKey:document];
  }
  return identifier;
}

- (void)refreshCatalog {
  NSAssert(NSThread.isMainThread, @"KeePassKit access must stay on the main thread");
  if(self.quitting) return;
  self.catalogDirty = NO;
  BOOL accessChanged = [self availabilityHasChanged];
  if(accessChanged) [self invalidateGrants];
  MPDocument *active = self.activeDocument;
  self.catalogDocument = active ? [self identifierForDocument:active] : nil;
  self.catalogStatus = self.providerStatus;
  NSDictionary *old = [self.metadata copy];
  NSMutableDictionary *updated = NSMutableDictionary.dictionary;
  NSArray *documents = self.openDocuments;
  for(MPDocument *document in self.documentIdentifiers.keyEnumerator.allObjects) {
    if(![documents containsObject:document]) [self.documentIdentifiers removeObjectForKey:document];
  }
  NSString *status = [self providerStatus];
  // Only the active unlocked database contributes. No titles, users, hosts or
  // database names of locked, conflicting or background databases are kept.
  MPDocument *document = [status isEqual:MPAutoFillStatusReady] ? self.activeDocument : nil;
  NSString *documentID = document ? [self identifierForDocument:document] : nil;
  NSString *database = document.displayName ?: @"";
  for(KPKEntry *entry in document.root.searchableChildEntries) {
    if(![self isFillable:entry]) continue;
    NSDictionary *values = [self fillValuesForEntry:entry];
    BOOL available = values[@"password"] != nil;
    NSString *record = [NSString stringWithFormat:@"%@/%@/%@", self.session, documentID, entry.uuid.UUIDString];
    NSMutableDictionary *item = [@{@"record": record, @"document": documentID, @"uuid": entry.uuid.UUIDString,
      @"title": entry.title ?: @"", @"user": values[@"user"], @"host": values[@"host"], @"port": values[@"port"],
      @"database": database, @"available": @(available)} mutableCopy];
    if(!available) item[@"reason"] = NSLocalizedStringWithDefaultValue(@"AUTOFILL_UNSUPPORTED_PLACEHOLDER", nil, NSBundle.mainBundle, @"This entry contains an unsupported placeholder or an unsafe/unresolved reference.", @"AutoFill picker explanation for an entry that cannot be filled");
    updated[record] = item;
  }
  // References may point at any entry, so any expiry can change eligibility.
  NSDate *nextExpiration = nil;
  for(KPKEntry *entry in document.tree.allEntries) {
    NSDate *date = entry.timeInfo.expires ? entry.timeInfo.expirationDate : nil;
    if(date.timeIntervalSinceNow > 0 && (!nextExpiration || [date compare:nextExpiration] == NSOrderedAscending)) nextExpiration = date;
  }
  [self scheduleExpirationRefreshAt:nextExpiration];
  self.metadata = updated;
  NSMutableArray *catalog = NSMutableArray.array;
  for(NSDictionary *metadata in updated.allValues) {
    NSMutableDictionary *item = [metadata mutableCopy];
    [item removeObjectsForKeys:@[@"uuid", @"document"]];
    [catalog addObject:[item copy]]; // Replies are encoded off the main queue.
  }
  self.catalog = [catalog sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"title" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)],
    [NSSortDescriptor sortDescriptorWithKey:@"user" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)]]];
  if(![old isEqual:updated]) {
    self.indexDirty = YES;
    if(!accessChanged) [self catalogDidChange];
  }
  [self publishIndex];
}

// The server prepares the catalog once per request, before any hook.
- (NSArray<NSDictionary *> *)catalogEntries {
  return self.quitting || !self.enabled ? @[] : self.catalog;
}

- (NSDictionary *)credentialForRecord:(NSString *)record expecting:(NSDictionary *)binding {
  NSString *status = [self providerStatus];
  if(![status isEqual:MPAutoFillStatusReady]) return @{@"status": status};
  NSDictionary *item = self.metadata[record];
  MPDocument *document = self.activeDocument;
  // Records of a database that is no longer the active one are stale.
  if(!item || ![item[@"document"] isEqual:[self.documentIdentifiers objectForKey:document]]) return @{@"status": MPAutoFillStatusStale};
  KPKEntry *entry = [document findEntry:[[NSUUID alloc] initWithUUIDString:item[@"uuid"]]];
  if(![self isFillable:entry] || [document.root.searchableChildEntries indexOfObjectIdenticalTo:entry] == NSNotFound) return @{@"status": MPAutoFillStatusStale};
  NSDictionary *values = [self fillValuesForEntry:entry];
  // Compare the live entry with what the picker displayed: an edit, even one
  // without a model notification, cannot redirect the password to another site.
  if(!values[@"password"] || ![values[@"host"] isEqual:binding[@"host"]] ||
     ![values[@"port"] isEqual:binding[@"port"]] || ![values[@"user"] isEqual:binding[@"user"]]) return @{@"status": MPAutoFillStatusStale};
  return @{@"status": MPAutoFillStatusReady, @"user": values[@"user"], @"password": values[@"password"]};
}

#pragma mark Unlock handoff

- (BOOL)requestUnlock {
  MPDocument *document = self.activeDocument;
  if(!self.enabled || self.quitting || !document) return NO;
  // The extension ends the Safari request and then activates MacPass by URL.
  // Only then does the unlock view appear, so it never covers the Safari sheet.
  // Keep the database: activation must not pick another one.
  self.unlockDocument = document;
  self.unlockDeadline = NSProcessInfo.processInfo.systemUptime + MPAutoFillUnlockInterval;
  if(NSApp.active) [self showPendingUnlock];
  return YES;
}

- (MPDocument *)pendingUnlockDocument {
  MPDocument *document = self.unlockDocument;
  if(self.unlockDeadline < NSProcessInfo.processInfo.systemUptime || ![self.openDocuments containsObject:document]) return nil;
  return document;
}

- (MPDocument *)documentToReveal {
  return self.pendingUnlockDocument ?: self.activeDocument;
}

- (void)showPendingUnlock {
  MPDocument *document = self.pendingUnlockDocument;
  self.unlockDeadline = 0;
  self.unlockDocument = nil;
  if(!document || !self.enabled || self.quitting || document.autoFillUnavailable) return;
  [document showWindows];
  if(document.encrypted) {
    MPDocumentWindowController *controller = document.windowControllers.firstObject;
    [controller showPasswordInputWithMessage:NSLocalizedStringWithDefaultValue(@"AUTOFILL_UNLOCK_MESSAGE", nil, NSBundle.mainBundle, @"Unlock this database, then select the suggestion again.", @"Shown in the unlock view after an AutoFill handoff") attemptTouchID:NSApp.active];
  }
}

#pragma mark Identity store

- (ASCredentialIdentityStore *)identityStore { return ASCredentialIdentityStore.sharedStore; }

- (void)publishIndex {
  if(self.quitting || self.indexBusy || !self.indexDirty) return;
  // Nothing to publish and nothing left to clear: never touch the store.
  if(!self.enabled && !self.indexMayHoldIdentities) {
    self.indexDirty = NO;
    [self updateServer];
    return;
  }
  // The store is shared by all copies of MacPass; only the listening one writes it.
  [self updateServer];
  if(!self.isListening) return;
  self.indexBusy = YES;
  __weak MPAutoFillCoordinator *weakSelf = self;
  [self.identityStore getCredentialIdentityStoreStateWithCompletion:^(ASCredentialIdentityStoreState *state) {
    dispatch_async(dispatch_get_main_queue(), ^{
      MPAutoFillCoordinator *coordinator = weakSelf;
      if(!coordinator) return;
      if(coordinator.quitting || !coordinator.isListening) {
        [coordinator didPublishIdentities:NO success:NO error:nil];
        return;
      }
      if(!state.enabled) {
        // macOS empties the store while the provider is off. Publication resumes
        // on the next request, activation or change once it is on again.
        coordinator.indexBusy = NO;
        coordinator.indexMayHoldIdentities = NO;
        coordinator.indexDirty = coordinator.enabled;
        [coordinator updateServer];
        [coordinator finishPendingTermination];
        return;
      }
      // Read the current catalog after the async state query: a database might
      // have locked or changed while the query was in flight.
      [coordinator prepareForRequest];
      NSMutableArray<ASPasswordCredentialIdentity *> *identities = NSMutableArray.array;
      for(NSDictionary *item in coordinator.metadata.allValues) {
        if(![item[@"available"] boolValue] || [item[@"host"] length] == 0) continue;
        [identities addObject:[ASPasswordCredentialIdentity identityWithServiceIdentifier:
          [[ASCredentialServiceIdentifier alloc] initWithIdentifier:item[@"host"] type:ASCredentialServiceIdentifierTypeDomain]
          user:item[@"user"] recordIdentifier:item[@"record"]]];
      }
      coordinator.indexDirty = NO;
      BOOL publishing = identities.count > 0;
      if(publishing) coordinator.indexMayHoldIdentities = YES;
      void (^completion)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf didPublishIdentities:publishing success:success error:error]; });
      };
      if(@available(macOS 14.0, *)) [coordinator.identityStore replaceCredentialIdentityEntries:identities completion:completion];
      else [coordinator.identityStore replaceCredentialIdentitiesWithIdentities:identities completion:completion];
    });
  }];
}

- (void)didPublishIdentities:(BOOL)publishing success:(BOOL)success error:(NSError *)error {
  self.indexBusy = NO;
  if(success && !publishing) self.indexMayHoldIdentities = NO;
  if(!success) {
    if(error) NSLog(@"AutoFill index update failed (%ld)", (long)error.code);
    // Retried later instead of spinning on a busy store.
    self.indexDirty = YES;
    [self scheduleRetry];
  }
  if([self finishPendingTermination]) return;
  if(success) [self publishIndex]; // Changes that arrived during the write.
  [self updateServer];
}

#pragma mark Termination

- (void)stop {
  self.quitting = YES;
  [self.metadata removeAllObjects];
  self.catalog = @[];
  [self.expirationTimer invalidate];
  self.expirationTimer = nil;
  [super stop];
}

- (void)prepareForTerminationWithCompletion:(void (^)(void))completion {
  // Stop secret delivery at once, but keep the listener until the store is
  // cleared, so no successor publishes identities this cleanup would erase.
  self.quitting = YES;
  [self invalidateGrants];
  [self.metadata removeAllObjects];
  self.catalog = @[];
  self.pendingTermination = completion;
  if(!self.indexBusy) [self finishPendingTermination];
}

- (BOOL)finishPendingTermination {
  void (^completion)(void) = self.pendingTermination;
  if(!completion) return NO;
  self.pendingTermination = nil;
  void (^finish)(void) = ^{
    [self stop];
    completion();
  };
  // Any store request keeps Apple's per-app helper, and so the app, alive for
  // about 3 s. Skip it when nothing this instance owns can be left over.
  if(!self.isListening || !self.indexMayHoldIdentities) { finish(); return YES; }
  [self.identityStore removeAllCredentialIdentitiesWithCompletion:^(BOOL success, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if(success) self.indexMayHoldIdentities = NO;
      else NSLog(@"AutoFill shutdown index cleanup failed (%ld)", (long)error.code);
      finish();
    });
  }];
  return YES;
}
@end
