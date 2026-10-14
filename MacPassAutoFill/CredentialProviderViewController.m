#import <AppKit/AppKit.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <LocalAuthenticationEmbeddedUI/LocalAuthenticationEmbeddedUI.h>
#import "../AutoFillShared/MPAutoFillTransport.h"
#import "../AutoFillShared/MPAutoFillDomain.h"
#import "MPAutoFillRequestState.h"
#import "MPAutoFillPickerView.h"
#import <math.h>

// One owner authentication covers "Show all entries" and the following fill
// within the same request, for at most this long.
static const NSTimeInterval MPAuthenticationReuseInterval = 60;

static NSMutableDictionary *MPMessage(NSString *operation, NSString *request) {
  return [@{@"version": @1, @"request": request, @"operation": operation} mutableCopy];
}

// The search the host runs: a longer query is cut before the character at the
// limit. The host's matches then include all of the full query's, and the
// picker narrows them locally.
static NSString *MPHostQuery(NSString *query) {
  if(query.length <= MPAutoFillMaximumQueryLength) return query;
  return [query substringToIndex:[query rangeOfComposedCharacterSequenceAtIndex:MPAutoFillMaximumQueryLength].location];
}

// Database access stays in the signed host. This target has no KeePassKit.
// The request state is the single source of truth; the picker view only
// renders it, and control states are derived from it in updateControls.
API_AVAILABLE(macos(13.0))
@interface MPCredentialProviderViewController : ASCredentialProviderViewController <MPAutoFillPickerViewDelegate>
@property (nonatomic, strong) MPAutoFillRequestState *requestState;
@property MPAutoFillPickerView *pickerView;
@property BOOL appeared;
@end

@implementation MPCredentialProviderViewController

- (MPAutoFillRequestState *)requestState {
  if(!_requestState) _requestState = [[MPAutoFillRequestState alloc] init];
  return _requestState;
}

- (void)loadView {
  self.pickerView = [[MPAutoFillPickerView alloc] initWithDelegate:self];
  self.view = self.pickerView;
  [self showMessage:MPAutoFillLocalized(@"AUTOFILL_EXT_CONNECTING", @"Connecting to MacPass…")];
}

- (void)viewDidAppear {
  [super viewDidAppear];
  self.appeared = YES;
  [self startWhenVisible];
}

- (void)viewDidDisappear {
  [super viewDidDisappear];
  self.appeared = NO;
  [self cancel:nil];
}

#pragma mark Presentation

- (void)showMode:(MPAutoFillPickerMode)mode {
  self.pickerView.mode = mode;
  [self updateControls];
}

- (void)showMessage:(NSString *)message {
  self.pickerView.status = message;
  [self showMode:MPAutoFillPickerModeMessage];
}

- (void)updateControls {
  MPAutoFillRequestState *state = self.requestState;
  self.pickerView.interactive = !state.busy;
  self.pickerView.fillEnabled = self.canFill;
  self.pickerView.unlockEnabled = self.canUnlock;
  // The checkbox only reflects the scope the host actually serves.
  self.pickerView.showsAllEntries = state.showAll;
  // The panel fits the visible controls, including a status that wraps.
  NSSize size = self.pickerView.preferredSize;
  if(self.pickerView && !NSEqualSizes(self.preferredContentSize, size)) self.preferredContentSize = size;
}

// The entry a fill acts on. A selected system suggestion counts only while the
// host still lists it as Safari showed it.
- (NSDictionary *)selectedEntry {
  MPAutoFillRequestState *state = self.requestState;
  if(!state.record) return nil;
  for(NSDictionary *entry in state.entries) {
    if(![entry[@"record"] isEqual:state.record]) continue;
    if(state.fillSelectedIdentity && (![entry[@"host"] isEqual:state.identityHost] || ![entry[@"user"] isEqual:state.identityUser])) return nil;
    return entry;
  }
  return nil;
}

- (BOOL)canFill {
  MPAutoFillRequestState *state = self.requestState;
  return !state.finished && !state.busy && state.grantAvailable && [self.selectedEntry[@"available"] boolValue];
}

- (BOOL)canUnlock {
  MPAutoFillRequestState *state = self.requestState;
  return !state.finished && !state.busy && state.grantAvailable && [state.catalogStatus isEqual:MPAutoFillStatusLocked];
}

#pragma mark Request lifecycle

- (void)beginForIdentity:(ASPasswordCredentialIdentity *)identity {
  [self resetForIdentity:identity];
  [self startWhenVisible];
}

- (void)resetForIdentity:(ASPasswordCredentialIdentity *)identity {
  [self abandonGrant];
  NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
  [workspace addObserver:self selector:@selector(cancel:) name:NSWorkspaceWillSleepNotification object:nil];
  BOOL valid = [self.requestState beginForIdentity:identity];
  [self.pickerView clearQuery];
  [self showMessage:MPAutoFillLocalized(@"AUTOFILL_EXT_CONNECTING", @"Connecting to MacPass…")];
  if(!valid) [self finishWithError:ASExtensionErrorCodeCredentialIdentityNotFound];
}

- (void)startWhenVisible {
  if(!self.appeared || self.requestState.started || !self.requestState.requestIdentifier || self.requestState.finished) return;
  self.requestState.started = YES;
  NSUInteger generation = self.requestState.generation;
  NSString *request = NSUUID.UUID.UUIDString;
  __weak MPCredentialProviderViewController *weakSelf = self;
  [self openSubscriptionForRequest:request completion:^(MPAutoFillStream *stream) {
    MPCredentialProviderViewController *controller = weakSelf;
    if(![controller.requestState acceptsGeneration:generation]) { [stream close]; return; }
    if(!stream) { [controller invalidateCatalogAccess]; [controller showUnavailable]; return; }
    controller.requestState.subscription = stream;
    __weak MPAutoFillStream *weakStream = stream;
    [stream startWithMessageHandler:^(NSDictionary *message) {
      MPCredentialProviderViewController *current = weakSelf;
      if(current.requestState.subscription != weakStream || current.requestState.finished) return;
      if(![message[@"version"] isEqual:@1] || ![message[@"request"] isEqual:request] ||
         ![@[MPAutoFillEventInvalidate, MPAutoFillEventCatalogChanged] containsObject:message[@"event"]]) {
        [current subscriptionDisconnected:weakStream]; return;
      }
      [current handleSubscriptionEvent:message[@"event"]];
    } closeHandler:^{ [weakSelf subscriptionDisconnected:weakStream]; }];
    // The host acknowledged registration before this first snapshot request.
    [controller requestCatalog];
  }];
}

- (void)openSubscriptionForRequest:(NSString *)request completion:(void (^)(MPAutoFillStream *))completion {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *error = nil;
    MPAutoFillStream *stream = MPAutoFillSubscribe(request, &error);
    MPAutoFillLogError(@"subscription", error);
    dispatch_async(dispatch_get_main_queue(), ^{ completion(stream); });
  });
}

- (void)invalidateCatalogAccess {
  [self cancelCurrentGrant];
  [self.requestState invalidateAccess];
  [self.pickerView cancelConfirmation];
  self.pickerView.authenticationView = nil;
  [self.pickerView clearQuery];
  [self clearCatalogRows];
  [self showMessage:MPAutoFillLocalized(@"AUTOFILL_EXT_CONNECTING", @"Connecting to MacPass…")];
}

- (void)subscriptionDisconnected:(MPAutoFillStream *)stream {
  if(!stream || self.requestState.subscription != stream) return;
  self.requestState.subscription = nil;
  [stream close];
  [self invalidateCatalogAccess];
  [self showUnavailable];
}

- (void)handleSubscriptionEvent:(NSString *)event {
  if([event isEqual:MPAutoFillEventInvalidate]) [self invalidateCatalogAccess];
  self.requestState.pendingCatalogRefresh = YES;
  [self refreshVisibleCatalog];
}

- (void)refreshVisibleCatalog {
  if(self.requestState.finished || !self.appeared || !self.requestState.subscription) return;
  if(self.requestState.busy || self.requestState.refreshingCatalog) { self.requestState.pendingCatalogRefresh = YES; return; }
  [self expireAuthenticatedScopeIfNeeded];
  self.requestState.pendingCatalogRefresh = NO;
  [self requestCatalog];
}

- (BOOL)expireAuthenticatedScopeIfNeeded {
  if(!self.requestState.showAll || self.requestState.ownerAuthenticated) return NO;
  self.requestState.showAll = NO;
  // A credential already being issued keeps its generation; outstanding
  // catalogs are rejected while busy and refreshed on returning to the picker.
  if(!self.requestState.busy) {
    [self.requestState advanceGeneration];
    self.requestState.refreshingCatalog = NO;
  }
  [self clearCatalogRows];
  [self updateControls];
  return YES;
}

// No periodic refresh: only the actual host grant deadline and owner-auth lease.
- (void)scheduleRequestDeadline {
  MPAutoFillRequestState *state = self.requestState;
  [state.deadlineTimer invalidate]; state.deadlineTimer = nil;
  if(state.finished || !state.subscription) return;
  NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  NSTimeInterval due = state.grantDeadline;
  if(state.authenticatedUntil > now) due = due ? MIN(due, state.authenticatedUntil) : state.authenticatedUntil;
  if(!due) return;
  __weak MPCredentialProviderViewController *weakSelf = self;
  state.deadlineTimer = [NSTimer timerWithTimeInterval:MAX(0.001, due - now) repeats:NO block:^(NSTimer *timer) {
    MPCredentialProviderViewController *controller = weakSelf;
    if(controller.requestState.finished || controller.requestState.deadlineTimer != timer) return;
    controller.requestState.deadlineTimer = nil;
    BOOL grantExpired = controller.requestState.grantDeadline > 0 && controller.requestState.grantDeadline <= NSProcessInfo.processInfo.systemUptime;
    if(grantExpired) {
      controller.requestState.hasGrant = NO;
      controller.requestState.grantDeadline = 0;
      [controller updateControls];
    }
    BOOL scopeExpired = [controller expireAuthenticatedScopeIfNeeded];
    if(grantExpired || scopeExpired) [controller refreshVisibleCatalog];
    else [controller scheduleRequestDeadline];
  }];
  [NSRunLoop.mainRunLoop addTimer:state.deadlineTimer forMode:NSRunLoopCommonModes];
}

- (void)refreshPendingCatalogWhenIdle {
  if(self.requestState.pendingCatalogRefresh) [self refreshVisibleCatalog];
  [self scheduleRequestDeadline];
}

- (void)clearCatalogRows {
  [self.requestState clearEntries];
  [self.pickerView showEntries:@[] selecting:nil];
}

// Fetches a catalog under a new request ID. The displayed selection and its
// grant stay usable meanwhile; the reply replaces them only while the picker is
// idle. A grant that is not adopted is released.
- (void)requestCatalog {
  self.requestState.refreshingCatalog = YES;
  NSString *request = NSUUID.UUID.UUIDString;
  NSMutableDictionary *message = MPMessage(MPAutoFillOperationCatalog, request);
  // Without authentication the host only returns the selected record or the
  // accounts of the requesting site. "all" is sent only after owner authentication.
  if(self.requestState.fillSelectedIdentity) { if(self.requestState.record) message[@"record"] = self.requestState.record; }
  else {
    // Next to "all", the services only put the site's accounts first.
    message[@"services"] = self.requestState.services ?: @[];
    if(self.requestState.showAll) message[@"scope"] = @"all";
    // The host lists a bounded number of accounts, so it runs the search.
    NSString *query = MPHostQuery(self.pickerView.query);
    if(query.length) message[@"query"] = query;
  }
  NSUInteger generation = self.requestState.generation;
  __weak MPCredentialProviderViewController *weakSelf = self;
  Class controllerClass = self.class;
  [self exchangeMessage:message completion:^(NSDictionary *reply) {
    MPCredentialProviderViewController *controller = weakSelf;
    if(![controller.requestState acceptsGeneration:generation] || controller.requestState.busy) {
      if(MPAutoFillStatusIssuesGrant(reply[@"status"])) [controllerClass cancelGrantForRequest:request];
      if(controller.requestState.generation == generation) {
        controller.requestState.refreshingCatalog = NO;
        controller.requestState.pendingCatalogRefresh = YES;
      }
      return;
    }
    controller.requestState.refreshingCatalog = NO;
    [controller cancelCurrentGrant];
    controller.requestState.requestIdentifier = request;
    [controller acceptCatalogReply:reply];
    if(controller.requestState.pendingCatalogRefresh) [controller refreshVisibleCatalog];
  }];
}

- (void)acceptCatalogReply:(NSDictionary *)reply {
  if(self.requestState.finished) return;
  NSString *status = [reply[@"status"] isKindOfClass:NSString.class] ? reply[@"status"] : nil;
  BOOL sameStatus = [self.requestState.catalogStatus isEqual:status];
  // A selected suggestion starts authentication only from the first reply;
  // an unlock elsewhere updates the panel but never fills by itself.
  BOOL firstCatalog = !self.requestState.didProcessFirstCatalog;
  self.requestState.didProcessFirstCatalog = YES;
  self.requestState.catalogStatus = status;
  self.requestState.hasGrant = MPAutoFillStatusIssuesGrant(status);
  self.requestState.grantDeadline = self.requestState.hasGrant && [reply[@"deadline"] isKindOfClass:NSNumber.class] ? [reply[@"deadline"] doubleValue] : 0;
  if(self.requestState.hasGrant && (!isfinite(self.requestState.grantDeadline) || !self.requestState.grantAvailable)) {
    [self cancelCurrentGrant]; self.requestState.grantDeadline = 0;
    [self clearCatalogRows]; [self scheduleRequestDeadline]; [self showUnavailable]; return;
  }
  [self scheduleRequestDeadline];
  if([@[MPAutoFillStatusDisabled, MPAutoFillStatusNoDocuments, MPAutoFillStatusConflict, MPAutoFillStatusTooLarge] containsObject:status]) {
    [self clearCatalogRows];
    NSString *message = MPAutoFillLocalized(@"AUTOFILL_EXT_NO_DATABASE", @"Open and unlock a database in MacPass, then select the suggestion again.");
    if([status isEqual:MPAutoFillStatusDisabled]) message = MPAutoFillLocalized(@"AUTOFILL_EXT_DISABLED", @"Enable Password AutoFill in MacPass Settings → Integration, then select the suggestion again.");
    if([status isEqual:MPAutoFillStatusConflict]) message = MPAutoFillLocalized(@"AUTOFILL_EXT_CONFLICT", @"Resolve the database's external file change in MacPass, then select the suggestion again.");
    if([status isEqual:MPAutoFillStatusTooLarge]) message = MPAutoFillLocalized(@"AUTOFILL_EXT_TOO_LARGE", @"Too many entries to show here. Select a suggestion for this website, or copy the password in MacPass.");
    [self showMessage:message];
    return;
  }
  if([status isEqual:MPAutoFillStatusLocked]) {
    // A locked database sends no entries, only a grant for the unlock handoff.
    [self clearCatalogRows];
    self.pickerView.status = MPAutoFillLocalized(@"AUTOFILL_EXT_LOCKED", @"The active MacPass database is locked. Unlock it, then select the suggestion again.");
    [self showMode:MPAutoFillPickerModeUnlock];
    return;
  }
  NSArray *entries = [reply[@"entries"] isKindOfClass:NSArray.class] ? reply[@"entries"] : nil;
  if(![status isEqual:MPAutoFillStatusReady] || !entries) { [self clearCatalogRows]; [self showUnavailable]; return; }
  NSMutableArray *valid = NSMutableArray.array;
  for(NSDictionary *entry in entries) {
    if(![entry isKindOfClass:NSDictionary.class]) continue;
    BOOL correct = YES;
    for(NSString *key in @[@"record", @"title", @"user", @"host", @"database"]) correct &= [entry[key] isKindOfClass:NSString.class];
    if(correct) [valid addObject:entry];
  }
  BOOL more = [reply[@"more"] isEqual:@YES];
  // The new grant is adopted even if metadata did not change; the table is
  // not rebuilt when only the grant was renewed.
  if(sameStatus && [self.requestState.entries isEqual:valid] && self.requestState.moreEntries == more) { [self updateControls]; return; }
  self.requestState.entries = valid;
  self.requestState.moreEntries = more;
  if(!self.requestState.fillSelectedIdentity) { [self showPicker]; return; }
  NSDictionary *selected = self.selectedEntry;
  if(!selected) {
    [self.pickerView showEntries:@[] selecting:nil];
    [self showMessage:MPAutoFillLocalized(@"AUTOFILL_EXT_OUTDATED", @"This suggestion is outdated. Select the current MacPass suggestion again.")];
    return;
  }
  [self.pickerView showEntries:@[selected] selecting:selected[@"record"]];
  [self showMode:MPAutoFillPickerModeSelected];
  [self updateSelection:selected];
  if(firstCatalog && self.canFill) [self fill:nil];
}

- (void)showPicker {
  [self showMode:MPAutoFillPickerModeList];
  [self filterEntries:nil];
}

- (void)showUnavailable {
  [self showMessage:MPAutoFillLocalized(@"AUTOFILL_EXT_UNAVAILABLE", @"Cannot connect securely to MacPass. Open MacPass, enable Password AutoFill in Settings → Integration and unlock a database, then select the suggestion again.")];
}

#pragma mark Picker

- (void)updateSelection:(NSDictionary *)entry {
  self.requestState.record = entry[@"record"];
  NSString *status = MPAutoFillLocalized(@"AUTOFILL_EXT_CHOOSE", @"Choose an account to fill from the active database.");
  if(!entry && !self.requestState.showAll) status = MPAutoFillLocalized(@"AUTOFILL_EXT_NO_MATCH", @"No accounts for this website in the active database. Use “Show all entries” to choose another account.");
  else if(!entry) status = MPAutoFillLocalized(@"AUTOFILL_EXT_NO_SEARCH_MATCH", @"No accounts match the search.");
  else if(![entry[@"available"] boolValue]) status = [entry[@"reason"] isKindOfClass:NSString.class] ? entry[@"reason"] : MPAutoFillLocalized(@"AUTOFILL_EXT_UNSUPPORTED", @"This entry uses an unsupported placeholder or reference.");
  else if(self.requestState.moreEntries) status = MPAutoFillLocalized(@"AUTOFILL_EXT_MORE", @"Not all accounts are listed. Refine the search to find the others.");
  self.pickerView.status = status;
  [self updateControls];
}

- (void)filterEntries:(id)sender {
  NSString *query = self.pickerView.query;
  NSMutableArray *visible = NSMutableArray.array;
  for(NSDictionary *entry in self.requestState.entries) {
    // Other sites' accounts are listed only after authentication.
    if(!self.requestState.showAll && !MPAutoFillEntryMatchesServices(entry, self.requestState.services)) continue;
    // Rows fetched for an earlier query never show what the current one excludes.
    if(!MPAutoFillEntryMatchesQuery(entry, query)) continue;
    [visible addObject:entry];
  }
  [self.pickerView showEntries:visible selecting:self.requestState.record];
  [self updateSelection:self.pickerView.selectedEntry];
}

- (void)pickerViewSelectionDidChange:(MPAutoFillPickerView *)view { [self updateSelection:view.selectedEntry]; }
// The listed rows narrow at once; the host then searches the whole scope. While
// a catalog is pending, further typing coalesces into one request for the
// latest query.
- (void)pickerViewQueryDidChange:(MPAutoFillPickerView *)view {
  [self filterEntries:nil];
  [self refreshVisibleCatalog];
}

- (void)toggleAllEntries:(id)sender {
  // A click asks for the other scope; the checkbox shows the served one again.
  BOOL wanted = !self.requestState.showAll;
  [self updateControls];
  if(self.requestState.finished || self.requestState.busy || self.requestState.fillSelectedIdentity) return;
  if(!wanted) { [self changeCatalogScopeToAll:NO]; return; }
  __weak MPCredentialProviderViewController *weakSelf = self;
  [self authenticateThen:^{ [weakSelf changeCatalogScopeToAll:YES]; } restoreOnCancel:YES];
}

- (void)changeCatalogScopeToAll:(BOOL)all {
  self.requestState.showAll = all;
  [self showPicker];
  // Discard any refresh for the previous scope and request the new one now.
  [self.requestState advanceGeneration];
  self.requestState.refreshingCatalog = NO;
  [self clearCatalogRows];
  [self refreshVisibleCatalog];
}

#pragma mark Host exchange

// Credential and unlock consume the current request's grant; a reply that
// arrives after the request moved on is dropped.
- (void)exchangeOperation:(NSString *)operation completion:(void (^)(NSDictionary *))completion {
  NSMutableDictionary *message = MPMessage(operation, self.requestState.requestIdentifier);
  if([operation isEqual:MPAutoFillOperationCredential] && self.requestState.record) message[@"record"] = self.requestState.record;
  NSUInteger generation = self.requestState.generation;
  __weak MPCredentialProviderViewController *weakSelf = self;
  [self exchangeMessage:message completion:^(NSDictionary *reply) {
    if([weakSelf.requestState acceptsGeneration:generation]) completion(reply);
  }];
}

// The extension never writes the identity store: MacPass is its only writer and
// clears identities a crash left behind on its next launch. A clear from here
// could race a MacPass that starts and publishes in the meantime.
- (void)exchangeMessage:(NSDictionary *)message completion:(void (^)(NSDictionary *))completion {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      NSError *error = nil;
      NSDictionary *reply = MPAutoFillExchange(message, &error);
      MPAutoFillLogError(@"IPC", error);
      dispatch_async(dispatch_get_main_queue(), ^{ completion(reply); });
    }
  });
}

#pragma mark Fill

- (void)fill:(id)sender {
  if(!self.canFill) return;
  NSDictionary *entry = self.selectedEntry;
  if(self.requestState.fillSelectedIdentity || MPAutoFillEntryMatchesServices(entry, self.requestState.services)) {
    [self authenticateManualSelectionAndFetch];
    return;
  }
  self.requestState.busy = YES;
  [self updateControls];
  NSUInteger generation = self.requestState.generation;
  __weak MPCredentialProviderViewController *weakSelf = self;
  [self.pickerView confirmFillOfEntry:entry forServices:self.requestState.services completion:^(BOOL confirmed) {
    MPCredentialProviderViewController *controller = weakSelf;
    if(![controller.requestState acceptsGeneration:generation]) return;
    controller.requestState.busy = NO;
    [controller updateControls];
    if(confirmed) [controller authenticateManualSelectionAndFetch];
    [controller refreshPendingCatalogWhenIdle];
  }];
}

- (LAContext *)newAuthenticationContext { return [[LAContext alloc] init]; }

- (NSView *)newAuthenticationViewForContext:(LAContext *)context {
  return [[LAAuthenticationView alloc] initWithContext:context];
}

- (void)authenticateManualSelectionAndFetch {
  if(self.requestState.finished || self.requestState.busy || !self.requestState.grantAvailable || !self.requestState.record) return;
  __weak MPCredentialProviderViewController *weakSelf = self;
  [self authenticateThen:^{ [weakSelf fetchSelectedCredential]; } restoreOnCancel:NO];
}

- (void)authenticateThen:(void (^)(void))action restoreOnCancel:(BOOL)restore {
  if(self.requestState.finished || self.requestState.busy) return;
  if(self.requestState.ownerAuthenticated) { action(); return; }
  self.requestState.busy = YES;
  self.requestState.afterAuthentication = action;
  self.requestState.restorePickerOnCancel = restore;
  LAContext *context = [self newAuthenticationContext];
  // An embedded view handles biometrics/Watch, not the macOS-password fallback.
  // Keep password entry in a standard system dialog on an unpaired context.
  BOOL embedded = [context canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometricsOrWatch error:NULL];
  [self evaluateOwnerAuthentication:context embedded:embedded];
}

- (void)useSystemAuthentication:(id)sender {
  if(self.requestState.finished || !self.requestState.busy || !self.requestState.authenticationEmbedded) return;
  [self clearAuthentication];
  [self evaluateOwnerAuthentication:[self newAuthenticationContext] embedded:NO];
}

- (void)evaluateOwnerAuthentication:(LAContext *)context embedded:(BOOL)embedded {
  if(self.requestState.finished) return;
  self.requestState.authenticationContext = context;
  self.requestState.authenticationEmbedded = embedded;
  context.touchIDAuthenticationAllowableReuseDuration = 0;
  self.pickerView.status = embedded ? MPAutoFillLocalized(@"AUTOFILL_EXT_CONFIRM", @"Confirm to continue.") : MPAutoFillLocalized(@"AUTOFILL_EXT_CONFIRM_SYSTEM", @"Confirm in the system authentication dialog.");
  self.pickerView.authenticationView = embedded ? [self newAuthenticationViewForContext:context] : nil;
  [self showMode:embedded ? MPAutoFillPickerModeEmbeddedAuthentication : MPAutoFillPickerModeSystemAuthentication];
  NSUInteger generation = self.requestState.generation;
  __weak MPCredentialProviderViewController *weakSelf = self;
  [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication localizedReason:MPAutoFillLocalized(@"AUTOFILL_EXT_AUTH_REASON", @"access your MacPass passwords") reply:^(BOOL success, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      MPCredentialProviderViewController *controller = weakSelf;
      if(![controller.requestState acceptsGeneration:generation] || controller.requestState.authenticationContext != context) return;
      [controller clearAuthentication];
      if(success) {
        controller.requestState.busy = NO;
        controller.requestState.authenticatedUntil = NSProcessInfo.processInfo.systemUptime + MPAuthenticationReuseInterval;
        void (^action)(void) = controller.requestState.afterAuthentication;
        controller.requestState.afterAuthentication = nil;
        if(action) action(); // A fill re-validates the live document in the host.
        [controller refreshPendingCatalogWhenIdle];
        return;
      }
      BOOL canceled = [error.domain isEqual:LAErrorDomain] &&
        (error.code == LAErrorUserCancel || error.code == LAErrorAppCancel || error.code == LAErrorSystemCancel);
      if(embedded && !canceled) {
        // Unavailable/locked-out biometrics and embedded fallback requests
        // still require system owner authentication; never issue on failure.
        [controller evaluateOwnerAuthentication:[controller newAuthenticationContext] embedded:NO];
      }
      else if(canceled && controller.requestState.restorePickerOnCancel) {
        controller.requestState.busy = NO;
        controller.requestState.afterAuthentication = nil;
        [controller showPicker];
        [controller refreshPendingCatalogWhenIdle];
      }
      else [controller finishWithError:canceled ? ASExtensionErrorCodeUserCanceled : ASExtensionErrorCodeFailed];
    });
  }];
}

- (void)fetchSelectedCredential {
  if(self.requestState.finished || self.requestState.busy || !self.requestState.grantAvailable || !self.requestState.record) return;
  if(!self.requestState.ownerAuthenticated) { [self finishWithError:ASExtensionErrorCodeUserInteractionRequired]; return; }
  self.requestState.busy = YES;
  [self updateControls];
  [self exchangeOperation:MPAutoFillOperationCredential completion:^(NSDictionary *reply) { [self completeWithCredentialReply:reply]; }];
}

- (void)completeWithCredentialReply:(NSDictionary *)reply {
  if(self.requestState.finished) return;
  if(![reply[@"status"] isEqual:MPAutoFillStatusReady] || ![reply[@"user"] isKindOfClass:NSString.class] || ![reply[@"password"] isKindOfClass:NSString.class]) {
    [self finishWithError:ASExtensionErrorCodeFailed];
    return;
  }
  ASPasswordCredential *credential = [ASPasswordCredential credentialWithUser:reply[@"user"] password:reply[@"password"]];
  self.requestState.hasGrant = NO; // Consumed; resource cleanup must not cancel it.
  if(![self.requestState finish]) return;
  [self abandonGrant];
  [self.extensionContext completeRequestWithSelectedCredential:credential completionHandler:nil];
}

#pragma mark Unlock handoff and completion

- (void)handoff:(id)sender {
  if(!self.canUnlock) return;
  self.requestState.busy = YES;
  [self updateControls];
  // Deliver the request while this request (and so the extension process) is
  // still alive. The host only records it and shows the unlock view once the
  // activation URL has brought MacPass forward, after the Safari sheet ended.
  [self exchangeOperation:MPAutoFillOperationUnlock completion:^(NSDictionary *reply) {
    self.requestState.hasGrant = NO; // consumed by the host
    self.requestState.busy = NO;
    [self openMacPass:nil];
  }];
}

- (void)cancelCurrentGrant {
  if(self.requestState.hasGrant) [self.class cancelGrantForRequest:self.requestState.requestIdentifier];
  self.requestState.hasGrant = NO;
}

+ (void)cancelGrantForRequest:(NSString *)request {
  if(!request) return;
  NSDictionary *message = MPMessage(MPAutoFillOperationCancel, request);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ MPAutoFillExchange(message, NULL); });
}

- (void)abandonGrant {
  [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self name:NSWorkspaceWillSleepNotification object:nil];
  [self clearAuthentication];
  [self cancelCurrentGrant];
  [self.requestState discard];
  [self.pickerView cancelConfirmation];
  [self clearCatalogRows];
}

- (void)clearAuthentication {
  [self.requestState clearAuthentication];
  self.pickerView.authenticationView = nil;
}

- (void)finishWithError:(ASExtensionErrorCode)code {
  if(self.requestState.finished) return;
  [self cancelCurrentGrant];
  if(![self.requestState finish]) return;
  [self abandonGrant];
  [self.extensionContext cancelRequestWithError:[NSError errorWithDomain:ASExtensionErrorDomain code:code userInfo:nil]];
}

- (void)cancel:(id)sender { [self finishWithError:ASExtensionErrorCodeUserCanceled]; }

- (void)openMacPass:(id)sender {
  if(self.requestState.finished || self.requestState.busy) return;
  // Use the native, user-initiated URL-open path for both warm and cold starts.
  // Sandboxed callers cannot pass launch arguments; IPC alone cannot promise focus.
  NSURL *url = [self hostActivationURL];
  [self yieldToHost];
  [self cancel:nil];
  [self openHostURL:url];
}

- (NSURL *)hostActivationURL {
  return [NSURL URLWithString:[NSString stringWithFormat:@"%@.autofill://open", MPAutoFillAppIdentifier()]];
}

- (void)yieldToHost {
  if(@available(macOS 14.0, *)) [NSApp yieldActivationToApplicationWithBundleIdentifier:MPAutoFillAppIdentifier()];
}

// The containing app (…/MacPass.app/Contents/PlugIns/MacPassAutoFill.appex).
// It launches only when no MacPass runs; otherwise the running copy, which
// holds the unlock request, receives the URL even if it lives elsewhere.
- (void)openHostURL:(NSURL *)url {
  NSURL *appURL = NSBundle.mainBundle.bundleURL;
  for(NSUInteger i = 0; i < 3; i++) appURL = appURL.URLByDeletingLastPathComponent;
  if(![appURL.pathExtension isEqualToString:@"app"]) return;
  NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
  configuration.activates = YES;
  [NSWorkspace.sharedWorkspace openURLs:@[url] withApplicationAtURL:appURL configuration:configuration completionHandler:^(NSRunningApplication *application, NSError *error) {
    if(error) NSLog(@"AutoFill application open failed (%ld)", (long)error.code);
  }];
}

#pragma mark ASCredentialProviderViewController

- (void)prepareCredentialListForServiceIdentifiers:(NSArray<ASCredentialServiceIdentifier *> *)identifiers {
  [self resetForIdentity:nil];
  self.requestState.services = [MPAutoFillRequestState servicesForIdentifiers:identifiers];
  [self startWhenVisible];
}

// Safari can authenticate AFTER accepting a silent credential, leaving a
// password it already owns available even if MacPass locks in that interval.
// Keep the secret in MacPass until provider authentication and final validation.
- (void)provideCredentialWithoutUserInteractionForIdentity:(ASPasswordCredentialIdentity *)identity {
  [self resetForIdentity:identity];
  [self finishWithError:ASExtensionErrorCodeUserInteractionRequired];
}

- (void)prepareInterfaceToProvideCredentialForIdentity:(ASPasswordCredentialIdentity *)identity { [self beginForIdentity:identity]; }

- (void)provideCredentialWithoutUserInteractionForRequest:(id<ASCredentialRequest>)request API_AVAILABLE(macos(14.0)) {
  if(request.type != ASCredentialRequestTypePassword || ![request.credentialIdentity isKindOfClass:ASPasswordCredentialIdentity.class]) {
    [self resetForIdentity:nil]; [self finishWithError:ASExtensionErrorCodeCredentialIdentityNotFound]; return;
  }
  [self provideCredentialWithoutUserInteractionForIdentity:(ASPasswordCredentialIdentity *)request.credentialIdentity];
}

- (void)prepareInterfaceToProvideCredentialForRequest:(id<ASCredentialRequest>)request API_AVAILABLE(macos(14.0)) {
  if(request.type != ASCredentialRequestTypePassword || ![request.credentialIdentity isKindOfClass:ASPasswordCredentialIdentity.class]) {
    [self resetForIdentity:nil];
    [self finishWithError:ASExtensionErrorCodeCredentialIdentityNotFound]; return;
  }
  [self beginForIdentity:(ASPasswordCredentialIdentity *)request.credentialIdentity];
}

- (void)dealloc {
  [_requestState discard];
  [_pickerView cancelConfirmation];
  [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}
@end
