#import <XCTest/XCTest.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import "MPAppDelegate.h"
#import "../MacPassAutoFill/MPAutoFillRequestState.h"
#import "../MacPassAutoFill/MPAutoFillPickerView.h"
#import "../AutoFillShared/MPAutoFillTransport.h"
#import <math.h>

// The extension source is also compiled into this test target. No hosted
// extensionContext, system authentication or IPC is invoked by these checks.
API_AVAILABLE(macos(13.0))
@interface MPCredentialProviderViewController : ASCredentialProviderViewController
- (void)cancel:(id)sender;
- (void)acceptCatalogReply:(NSDictionary *)reply;
- (void)handoff:(id)sender;
- (void)fill:(id)sender;
- (void)openMacPass:(id)sender;
- (void)openHostURL:(NSURL *)url;
- (void)yieldToHost;
- (void)refreshVisibleCatalog;
- (void)exchangeOperation:(NSString *)operation completion:(void (^)(NSDictionary *))completion;
- (void)exchangeMessage:(NSDictionary *)message completion:(void (^)(NSDictionary *))completion;
- (void)filterEntries:(id)sender;
- (void)pickerViewQueryDidChange:(MPAutoFillPickerView *)view;
- (void)toggleAllEntries:(id)sender;
- (LAContext *)newAuthenticationContext;
- (NSView *)newAuthenticationViewForContext:(LAContext *)context;
- (void)useSystemAuthentication:(id)sender;
- (void)openSubscriptionForRequest:(NSString *)request completion:(void (^)(MPAutoFillStream *))completion;
- (void)handleSubscriptionEvent:(NSString *)event;
- (void)subscriptionDisconnected:(MPAutoFillStream *)stream;
- (void)scheduleRequestDeadline;
- (void)startWhenVisible;
+ (void)cancelGrantForRequest:(NSString *)request;
@property (readonly) MPAutoFillRequestState *requestState;
@property MPAutoFillPickerView *pickerView;
@property BOOL appeared;
@end

@interface MPAutoFillPickerView (Testing)
@property (readonly) NSStackView *content;
- (NSAlert *)confirmationForEntry:(NSDictionary *)entry services:(NSArray<NSDictionary *> *)services;
@end

@interface MPAppDelegate (Testing)
@property (nonatomic) NSInteger startupState;
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls;
@end

@interface MPAutoFillContextSpy : NSObject
@property NSUInteger cancellationCount;
@property NSUInteger completionCount;
@property NSError *lastError;
@property ASPasswordCredential *credential;
- (void)cancelRequestWithError:(NSError *)error;
- (void)completeRequestWithSelectedCredential:(ASPasswordCredential *)credential completionHandler:(void (^)(BOOL))completionHandler;
@end
@implementation MPAutoFillContextSpy
- (void)cancelRequestWithError:(NSError *)error { self.cancellationCount++; self.lastError = error; }
- (void)completeRequestWithSelectedCredential:(ASPasswordCredential *)credential completionHandler:(void (^)(BOOL))completionHandler {
  self.completionCount++; self.credential = credential;
}
@end

static NSString *MPCancelledGrant;

@interface MPAutoFillStreamSpy : MPAutoFillStream
@property NSUInteger closeCount;
@property (copy) void (^messageHandler)(NSDictionary *);
@property (copy) void (^closeHandler)(void);
@end
@implementation MPAutoFillStreamSpy
- (void)startWithMessageHandler:(void (^)(NSDictionary *))messageHandler closeHandler:(void (^)(void))closeHandler {
  self.messageHandler = messageHandler; self.closeHandler = closeHandler;
}
- (void)close { if(!self.closeCount) { self.closeCount++; if(self.closeHandler) self.closeHandler(); } }
@end

// Records grant cancellations instead of sending them to a MacPass that may
// be running on this Mac.
API_AVAILABLE(macos(13.0))
@interface MPAutoFillTestController : MPCredentialProviderViewController
@property MPAutoFillContextSpy *contextSpy;
@end
@implementation MPAutoFillTestController
- (ASCredentialProviderExtensionContext *)extensionContext { return (id)self.contextSpy; }
+ (void)cancelGrantForRequest:(NSString *)request { MPCancelledGrant = request; }
- (void)acceptCatalogReply:(NSDictionary *)reply {
  // Legacy public fixtures predate the deadline field; model a real host grant.
  if(MPAutoFillStatusIssuesGrant(reply[@"status"]) && !reply[@"deadline"]) {
    NSMutableDictionary *catalog = reply.mutableCopy;
    catalog[@"deadline"] = @(NSProcessInfo.processInfo.systemUptime + 90);
    reply = catalog;
  }
  [super acceptCatalogReply:reply];
}
- (void)openSubscriptionForRequest:(NSString *)request completion:(void (^)(MPAutoFillStream *))completion {
  completion([[MPAutoFillStreamSpy alloc] initWithSocket:-1]);
}
@end

API_AVAILABLE(macos(13.0))
@interface MPAutoFillLateCatalogControllerSpy : MPAutoFillTestController
@property (copy) void (^pendingReply)(NSDictionary *);
@property NSDictionary *message;
@end
@implementation MPAutoFillLateCatalogControllerSpy
- (void)exchangeMessage:(NSDictionary *)message completion:(void (^)(NSDictionary *))completion { self.message = message; self.pendingReply = completion; }
@end

API_AVAILABLE(macos(13.0))
@interface MPAutoFillHandshakeControllerSpy : MPAutoFillLateCatalogControllerSpy
@property (copy) void (^pendingSubscription)(MPAutoFillStream *);
@property NSUInteger subscriptionCount;
@end
@implementation MPAutoFillHandshakeControllerSpy
- (void)openSubscriptionForRequest:(NSString *)request completion:(void (^)(MPAutoFillStream *))completion {
  self.subscriptionCount++; self.pendingSubscription = completion;
}
@end

@interface MPAutoFillAuthenticationSpy : LAContext
@property NSUInteger evaluationCount;
@property LAPolicy requestedPolicy;
@property BOOL invalidated;
@property BOOL embeddedAvailable;
@property (weak) NSView *authenticationView;
@property BOOL embeddedAtEvaluation;
@property (copy) void (^pendingAuthentication)(BOOL, NSError *);
@end
@implementation MPAutoFillAuthenticationSpy
- (BOOL)canEvaluatePolicy:(LAPolicy)policy error:(NSError **)error { return self.embeddedAvailable; }
- (void)evaluatePolicy:(LAPolicy)policy localizedReason:(NSString *)reason reply:(void (^)(BOOL, NSError *))reply {
  self.evaluationCount++;
  self.requestedPolicy = policy;
  self.embeddedAtEvaluation = self.authenticationView.superview != nil;
  self.pendingAuthentication = reply;
}
- (void)invalidate { self.invalidated = YES; }
@end

API_AVAILABLE(macos(13.0))
@interface MPAutoFillUnsupportedServiceIdentifier : ASCredentialServiceIdentifier
@end
@implementation MPAutoFillUnsupportedServiceIdentifier
- (ASCredentialServiceIdentifierType)type { return (ASCredentialServiceIdentifierType)99; }
@end

API_AVAILABLE(macos(13.0))
@interface MPAutoFillSilentControllerSpy : MPAutoFillTestController
@property NSDictionary *catalog;
@property NSDictionary *credentialReply;
@property NSUInteger viewLoadCount;
@property NSUInteger credentialRequestCount;
@property NSString *credentialRecord;
@property BOOL deferCredential;
@property (copy) void (^pendingReply)(NSDictionary *);
@property MPAutoFillAuthenticationSpy *authenticationSpy;
@property BOOL deferCatalog;
@property (copy) void (^pendingCatalogReply)(NSDictionary *);
@property NSDictionary *lastCatalogMessage;
@property NSUInteger catalogRequestCount;
@property NSUInteger filterCount;
@property BOOL embeddedUnavailable;
@end
@implementation MPAutoFillSilentControllerSpy
- (void)loadView { self.viewLoadCount++; [super loadView]; }
- (LAContext *)newAuthenticationContext {
  self.authenticationSpy = [[MPAutoFillAuthenticationSpy alloc] init];
  self.authenticationSpy.embeddedAvailable = !self.embeddedUnavailable;
  return self.authenticationSpy;
}
- (NSView *)newAuthenticationViewForContext:(LAContext *)context {
  NSView *view = [[NSView alloc] initWithFrame:NSZeroRect];
  ((MPAutoFillAuthenticationSpy *)context).authenticationView = view;
  return view;
}
- (void)exchangeOperation:(NSString *)operation completion:(void (^)(NSDictionary *))completion {
  if([operation isEqual:@"credential"]) {
    self.credentialRequestCount++;
    self.credentialRecord = self.requestState.record;
    if(self.deferCredential) self.pendingReply = completion;
    else completion(self.credentialReply);
  }
}
- (void)exchangeMessage:(NSDictionary *)message completion:(void (^)(NSDictionary *))completion {
  if([message[@"operation"] isEqual:@"catalog"]) {
    self.lastCatalogMessage = message;
    self.catalogRequestCount++;
    if(self.deferCatalog) self.pendingCatalogReply = completion;
    else completion(self.catalog);
  }
}
- (void)filterEntries:(id)sender { self.filterCount++; [super filterEntries:sender]; }
@end

// Records the other-site confirmation instead of showing its sheet.
API_AVAILABLE(macos(13.0))
@interface MPAutoFillConfirmationPickerSpy : MPAutoFillPickerView
@property NSUInteger confirmationCount;
@property NSDictionary *confirmedEntry;
@property NSArray *confirmedServices;
@property (copy) void (^pendingConfirmation)(BOOL);
@end
@implementation MPAutoFillConfirmationPickerSpy
- (void)confirmFillOfEntry:(NSDictionary *)entry forServices:(NSArray *)services completion:(void (^)(BOOL))completion {
  self.confirmationCount++; self.confirmedEntry = entry; self.confirmedServices = services; self.pendingConfirmation = completion;
}
// Like ending the sheet, which answers Cancel.
- (void)cancelConfirmation {
  void (^completion)(BOOL) = self.pendingConfirmation;
  self.pendingConfirmation = nil;
  if(completion) completion(NO);
}
@end

API_AVAILABLE(macos(13.0))
@interface MPAutoFillOtherSiteControllerSpy : MPAutoFillSilentControllerSpy
@property (readonly) MPAutoFillConfirmationPickerSpy *picker;
@end
@implementation MPAutoFillOtherSiteControllerSpy
- (void)loadView {
  [super loadView];
  self.pickerView = [[MPAutoFillConfirmationPickerSpy alloc] initWithDelegate:(id)self];
  self.view = self.pickerView;
}
- (MPAutoFillConfirmationPickerSpy *)picker { return (MPAutoFillConfirmationPickerSpy *)self.pickerView; }
@end

API_AVAILABLE(macos(13.0))
@interface MPAutoFillControllerSpy : MPAutoFillTestController
@property NSUInteger fillCount;
@property NSURL *openedHostURL;
@property NSUInteger yieldCount;
@property NSUInteger cancellationCountAtOpen;
@property NSUInteger unlockCount;
@property NSUInteger cancellationCountAtUnlock;
@property BOOL deferExchange;
@property (copy) void (^pendingExchange)(NSDictionary *);
@end
@implementation MPAutoFillControllerSpy
- (void)yieldToHost { self.yieldCount++; }
- (void)openHostURL:(NSURL *)url {
  self.openedHostURL = url;
  self.cancellationCountAtOpen = self.contextSpy.cancellationCount;
}
- (void)fill:(id)sender { self.fillCount++; }
- (void)exchangeOperation:(NSString *)operation completion:(void (^)(NSDictionary *))completion {
  if(![operation isEqual:@"unlock"]) return;
  self.unlockCount++;
  self.cancellationCountAtUnlock = self.contextSpy.cancellationCount;
  if(self.deferExchange) self.pendingExchange = completion;
  else completion(@{@"status": @"accepted"});
}
@end

@interface MPAutoFillAppDelegateSpy : MPAppDelegate
@property NSUInteger revealCount;
@property NSString *openedFile;
@end
@implementation MPAutoFillAppDelegateSpy
- (void)revealAutoFillApplication { self.revealCount++; }
- (BOOL)application:(NSApplication *)application openFile:(NSString *)filename { self.openedFile = filename; return YES; }
// The real handler would reopen the last database or show the welcome window.
- (void)_applicationDidFinishLaunchingAndDidRestoreWindows {}
@end

API_AVAILABLE(macos(13.0))
@interface MPTestAutoFillExtension : XCTestCase
@end

@implementation MPTestAutoFillExtension

- (void)setUp {
  MPCancelledGrant = nil;
}

- (ASPasswordCredentialIdentity *)testIdentity {
  return [ASPasswordCredentialIdentity identityWithServiceIdentifier:
    [[ASCredentialServiceIdentifier alloc] initWithIdentifier:@"localhost" type:ASCredentialServiceIdentifierTypeDomain]
    user:@"public-test" recordIdentifier:@"test-record"];
}

// A locked database sends no metadata, only a grant for the unlock handoff.
- (NSDictionary *)catalogLocked:(BOOL)locked {
  if(locked) return @{@"status": @"locked", @"entries": @[]};
  return @{@"status": @"ready",
           @"entries": @[@{@"record": @"test-record", @"title": @"Test", @"user": @"public-test", @"host": @"localhost",
                           @"port": @"", @"database": @"Test database", @"available": @YES}]};
}

- (MPAutoFillSilentControllerSpy *)silentControllerLocked:(BOOL)locked {
  MPAutoFillSilentControllerSpy *controller = [[MPAutoFillSilentControllerSpy alloc] init];
  controller.contextSpy = [[MPAutoFillContextSpy alloc] init];
  controller.catalog = [self catalogLocked:locked];
  controller.credentialReply = @{@"status": @"ready", @"user": @"public-test", @"password": @"public-password"};
  return controller;
}

- (MPAutoFillSilentControllerSpy *)manualController {
  MPAutoFillSilentControllerSpy *controller = [self silentControllerLocked:NO];
  [controller loadView];
  [controller prepareCredentialListForServiceIdentifiers:@[[[ASCredentialServiceIdentifier alloc] initWithIdentifier:@"localhost" type:ASCredentialServiceIdentifierTypeDomain]]];
  controller.requestState.subscription = [[MPAutoFillStreamSpy alloc] initWithSocket:-1];
  [controller acceptCatalogReply:controller.catalog];
  return controller;
}

- (MPAutoFillControllerSpy *)controllerForSelectedIdentity:(BOOL)selected {
  MPAutoFillControllerSpy *controller = [[MPAutoFillControllerSpy alloc] init];
  controller.contextSpy = [[MPAutoFillContextSpy alloc] init];
  [controller loadView];
  if(selected) [controller prepareInterfaceToProvideCredentialForIdentity:self.testIdentity];
  else [controller prepareCredentialListForServiceIdentifiers:@[[[ASCredentialServiceIdentifier alloc] initWithIdentifier:@"localhost" type:ASCredentialServiceIdentifierTypeDomain]]];
  return controller;
}

- (void)drainAuthenticationCallback {
  XCTestExpectation *done = [self expectationWithDescription:@"Authentication callback handled"];
  dispatch_async(dispatch_get_main_queue(), ^{ [done fulfill]; });
  [self waitForExpectationsWithTimeout:1 handler:nil];
}

// Simulate an explicit catalog-change event without a real signed host.
- (void)refresh:(MPCredentialProviderViewController *)controller {
  if(!controller.requestState.subscription) controller.requestState.subscription = [[MPAutoFillStreamSpy alloc] initWithSocket:-1];
  [controller refreshVisibleCatalog];
}

#pragma mark Request state

- (void)testExtensionCancellationCompletesExactlyOnce {
  MPAutoFillControllerSpy *controller = [[MPAutoFillControllerSpy alloc] init];
  controller.contextSpy = [[MPAutoFillContextSpy alloc] init];
  [controller cancel:nil];
  [controller cancel:nil];
  XCTAssertEqual(controller.contextSpy.cancellationCount, 1U);
}

- (void)testRequestStateBeginDropsPreviousRequestAndInvalidatesItsResources {
  MPAutoFillRequestState *state = [[MPAutoFillRequestState alloc] init];
  XCTAssertTrue([state beginForIdentity:self.testIdentity]);
  NSUInteger generation = state.generation;
  NSString *request = state.requestIdentifier;
  MPAutoFillAuthenticationSpy *authentication = [[MPAutoFillAuthenticationSpy alloc] init];
  NSTimer *timer = [NSTimer timerWithTimeInterval:60 repeats:YES block:^(NSTimer *t) {}];
  state.authenticationContext = authentication; state.deadlineTimer = timer;
  MPAutoFillStreamSpy *stream = [[MPAutoFillStreamSpy alloc] initWithSocket:-1];
  state.subscription = stream;
  state.hasGrant = YES; state.entries = @[@{}]; state.services = @[@{}];
  state.authenticatedUntil = NSProcessInfo.processInfo.systemUptime + 60;
  state.afterAuthentication = ^{}; state.showAll = YES; state.busy = YES; state.moreEntries = YES;
  XCTAssertTrue(state.ownerAuthenticated);
  XCTAssertTrue([state beginForIdentity:nil]);
  XCTAssertFalse(state.moreEntries);
  XCTAssertFalse([state acceptsGeneration:generation]);
  XCTAssertNotEqualObjects(state.requestIdentifier, request);
  XCTAssertTrue(authentication.invalidated); XCTAssertFalse(timer.valid);
  XCTAssertEqual(stream.closeCount, 1U); XCTAssertNil(state.subscription);
  XCTAssertNil(state.authenticationContext); XCTAssertNil(state.deadlineTimer);
  XCTAssertNil(state.afterAuthentication); XCTAssertFalse(state.hasGrant); XCTAssertNil(state.record);
  XCTAssertNil(state.entries); XCTAssertEqual(state.services.count, 0U);
  XCTAssertFalse(state.showAll); XCTAssertFalse(state.busy); XCTAssertFalse(state.ownerAuthenticated);
}

- (void)testRequestStateFinishIsTerminalAndExpiresAuthentication {
  MPAutoFillRequestState *state = [[MPAutoFillRequestState alloc] init];
  XCTAssertTrue([state beginForIdentity:self.testIdentity]);
  NSUInteger generation = state.generation;
  state.authenticatedUntil = NSProcessInfo.processInfo.systemUptime + 60;
  state.afterAuthentication = ^{};
  MPAutoFillAuthenticationSpy *authentication = [[MPAutoFillAuthenticationSpy alloc] init];
  NSTimer *timer = [NSTimer timerWithTimeInterval:60 repeats:YES block:^(NSTimer *t) {}];
  state.authenticationContext = authentication; state.deadlineTimer = timer;
  MPAutoFillStreamSpy *stream = [[MPAutoFillStreamSpy alloc] initWithSocket:-1];
  state.subscription = stream;
  XCTAssertTrue([state finish]); XCTAssertFalse([state finish]);
  XCTAssertTrue(authentication.invalidated); XCTAssertFalse(timer.valid);
  XCTAssertNil(state.authenticationContext); XCTAssertNil(state.deadlineTimer);
  XCTAssertFalse([state acceptsGeneration:generation]);
  XCTAssertFalse([state acceptsGeneration:state.generation]);
  XCTAssertFalse(state.ownerAuthenticated); XCTAssertNil(state.afterAuthentication);
  [state discard];
  XCTAssertEqual(stream.closeCount, 1U); XCTAssertNil(state.subscription);
  XCTAssertNil(state.requestIdentifier); XCTAssertNil(state.record);
  XCTAssertTrue([state beginForIdentity:nil]);
  generation = state.generation;
  [state discard];
  XCTAssertFalse([state acceptsGeneration:generation]);
}

#pragma mark Catalog scope

- (void)testCatalogRequestCarriesOnlyTheRequestedService {
  MPAutoFillSilentControllerSpy *controller = [self silentControllerLocked:NO];
  [controller loadView];
  [controller prepareCredentialListForServiceIdentifiers:@[[[ASCredentialServiceIdentifier alloc] initWithIdentifier:@"https://www.Example.com:8443/login" type:ASCredentialServiceIdentifierTypeURL]]];
  controller.appeared = YES;
  [self refresh:controller];
  XCTAssertEqualObjects(controller.lastCatalogMessage[@"services"], (@[@{@"host": @"www.example.com", @"port": @"8443"}]));
  XCTAssertNil(controller.lastCatalogMessage[@"scope"]);
  XCTAssertNil(controller.lastCatalogMessage[@"record"]);
}

- (void)testNonWebServiceIdentifiersNeverBecomeHostRequests {
  ASCredentialServiceIdentifier *unsupported = [[MPAutoFillUnsupportedServiceIdentifier alloc] initWithIdentifier:@"example.com" type:ASCredentialServiceIdentifierTypeDomain];
  ASCredentialServiceIdentifier *domain = [[ASCredentialServiceIdentifier alloc] initWithIdentifier:@"Example.com" type:ASCredentialServiceIdentifierTypeDomain];
  ASCredentialServiceIdentifier *url = [[ASCredentialServiceIdentifier alloc] initWithIdentifier:@"https://example.com:8443/login" type:ASCredentialServiceIdentifierTypeURL];
  XCTAssertFalse([MPAutoFillRequestState isWebServiceIdentifier:unsupported]);
  NSArray *services = [MPAutoFillRequestState servicesForIdentifiers:@[unsupported, domain, domain, url]];
  XCTAssertEqualObjects(services, (@[@{@"host": @"example.com", @"port": @""}, @{@"host": @"example.com", @"port": @"8443"}]));
  MPAutoFillSilentControllerSpy *controller = [self silentControllerLocked:NO];
  [controller loadView];
  [controller prepareCredentialListForServiceIdentifiers:@[unsupported]];
  controller.appeared = YES;
  [self refresh:controller];
  XCTAssertEqualObjects(controller.lastCatalogMessage[@"services"], @[]);
  ASPasswordCredentialIdentity *identity = [ASPasswordCredentialIdentity identityWithServiceIdentifier:unsupported user:@"public-test" recordIdentifier:@"test-record"];
  [controller prepareInterfaceToProvideCredentialForIdentity:identity];
  XCTAssertEqual(controller.contextSpy.lastError.code, ASExtensionErrorCodeCredentialIdentityNotFound);
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  XCTAssertNil(controller.authenticationSpy);
}

- (void)testShowAllRequiresAuthenticationAndCoversTheFollowingFill {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  controller.appeared = YES;
  controller.pickerView.allEntriesButton.state = NSControlStateValueOn;
  [controller toggleAllEntries:nil];
  MPAutoFillAuthenticationSpy *authentication = controller.authenticationSpy;
  XCTAssertEqual(authentication.evaluationCount, 1U);
  XCTAssertEqual(controller.pickerView.allEntriesButton.state, NSControlStateValueOff);
  XCTAssertFalse(controller.requestState.showAll);
  XCTAssertNil(controller.lastCatalogMessage[@"scope"]);
  authentication.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  XCTAssertTrue(controller.requestState.showAll);
  XCTAssertEqualObjects(controller.lastCatalogMessage[@"scope"], @"all");
  // Only to put the site's accounts first.
  XCTAssertEqualObjects(controller.lastCatalogMessage[@"services"], (@[@{@"host": @"localhost", @"port": @""}]));
  XCTAssertTrue(MPAutoFillValidateRequest(controller.lastCatalogMessage));
  XCTAssertEqual(controller.pickerView.allEntriesButton.state, NSControlStateValueOn);
  XCTAssertFalse(controller.pickerView.scrollView.hidden);
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  [controller fill:nil];
  XCTAssertEqual(controller.authenticationSpy, authentication); // No second prompt.
  XCTAssertEqual(controller.credentialRequestCount, 1U);
  XCTAssertEqual(controller.contextSpy.completionCount, 1U);
  authentication.pendingAuthentication = nil;
}

- (void)testShowAllCancellationRestoresTheScopedPicker {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  controller.appeared = YES;
  controller.pickerView.allEntriesButton.state = NSControlStateValueOn;
  [controller toggleAllEntries:nil];
  XCTAssertTrue(controller.pickerView.scrollView.hidden);
  controller.authenticationSpy.pendingAuthentication(NO, [NSError errorWithDomain:LAErrorDomain code:LAErrorUserCancel userInfo:nil]);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.contextSpy.cancellationCount, 0U);
  XCTAssertFalse(controller.pickerView.scrollView.hidden);
  XCTAssertFalse(controller.requestState.showAll);
  XCTAssertEqual(controller.pickerView.allEntriesButton.state, NSControlStateValueOff);
  XCTAssertTrue(controller.pickerView.fillButton.enabled);
  [self refresh:controller];
  XCTAssertNil(controller.lastCatalogMessage[@"scope"]);
  XCTAssertNotNil(controller.lastCatalogMessage[@"services"]);
  controller.authenticationSpy.pendingAuthentication = nil;
}

#pragma mark Other-site confirmation

// "Show all" is authenticated and another site's account is selected.
- (MPAutoFillOtherSiteControllerSpy *)otherSiteController {
  MPAutoFillOtherSiteControllerSpy *controller = [[MPAutoFillOtherSiteControllerSpy alloc] init];
  controller.contextSpy = [[MPAutoFillContextSpy alloc] init];
  NSMutableArray *entries = [[self catalogLocked:NO][@"entries"] mutableCopy];
  [entries addObject:@{@"record": @"other-record", @"title": @"Other", @"user": @"other-user", @"host": @"other.example",
                       @"port": @"", @"database": @"Test database", @"available": @YES}];
  controller.catalog = @{@"status": @"ready", @"entries": entries};
  controller.credentialReply = @{@"status": @"ready", @"user": @"other-user", @"password": @"other-password"};
  [controller loadView];
  [controller prepareCredentialListForServiceIdentifiers:@[[[ASCredentialServiceIdentifier alloc] initWithIdentifier:@"localhost" type:ASCredentialServiceIdentifierTypeDomain]]];
  controller.appeared = YES;
  controller.requestState.subscription = [[MPAutoFillStreamSpy alloc] initWithSocket:-1];
  [controller acceptCatalogReply:controller.catalog];
  XCTAssertEqual(controller.pickerView.entries.count, 1U);
  [controller toggleAllEntries:nil];
  controller.authenticationSpy.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  controller.authenticationSpy.pendingAuthentication = nil;
  XCTAssertEqual(controller.pickerView.entries.count, 2U);
  [controller.pickerView.table selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
  XCTAssertEqualObjects(controller.requestState.record, @"other-record");
  XCTAssertTrue(controller.pickerView.fillButton.enabled);
  return controller;
}

- (void)testOtherSiteFillWaitsForConfirmationAndCancelKeepsThePicker {
  MPAutoFillOtherSiteControllerSpy *controller = self.otherSiteController;
  MPAutoFillAuthenticationSpy *authentication = controller.authenticationSpy;
  [controller fill:nil];
  [controller fill:nil]; // Return again while the dialog is open.
  XCTAssertEqual(controller.picker.confirmationCount, 1U);
  XCTAssertEqualObjects(controller.picker.confirmedEntry[@"host"], @"other.example");
  XCTAssertEqualObjects(controller.picker.confirmedServices, (@[@{@"host": @"localhost", @"port": @""}]));
  XCTAssertFalse(controller.pickerView.fillButton.enabled);
  controller.picker.pendingConfirmation(NO);
  controller.picker.pendingConfirmation = nil;
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  XCTAssertEqual(controller.authenticationSpy, authentication);
  XCTAssertEqual(authentication.evaluationCount, 1U);
  XCTAssertEqual(controller.contextSpy.completionCount, 0U);
  XCTAssertEqual(controller.contextSpy.cancellationCount, 0U);
  XCTAssertTrue(controller.pickerView.fillButton.enabled);
  XCTAssertEqualObjects(controller.requestState.record, @"other-record");
}

- (void)testConfirmedOtherSiteFillUsesTheShowAllAuthenticationOnce {
  MPAutoFillOtherSiteControllerSpy *controller = self.otherSiteController;
  MPAutoFillAuthenticationSpy *authentication = controller.authenticationSpy;
  [controller fill:nil];
  controller.picker.pendingConfirmation(YES);
  controller.picker.pendingConfirmation = nil;
  XCTAssertEqual(controller.authenticationSpy, authentication); // No second prompt within the lease.
  XCTAssertEqual(authentication.evaluationCount, 1U);
  XCTAssertEqual(controller.credentialRequestCount, 1U);
  XCTAssertEqualObjects(controller.credentialRecord, @"other-record");
  XCTAssertEqual(controller.contextSpy.completionCount, 1U);
  XCTAssertEqualObjects(controller.contextSpy.credential.user, @"other-user");
  XCTAssertFalse(controller.requestState.ownerAuthenticated); // The fill ended the request and its lease.
}

- (void)testAuthenticationExpiringDuringConfirmationRequiresANewPrompt {
  MPAutoFillOtherSiteControllerSpy *controller = self.otherSiteController;
  MPAutoFillAuthenticationSpy *authentication = controller.authenticationSpy;
  [controller fill:nil];
  controller.requestState.authenticatedUntil = NSProcessInfo.processInfo.systemUptime - 1;
  [controller.requestState.deadlineTimer fire];
  XCTAssertFalse(controller.requestState.showAll);
  XCTAssertEqual(controller.pickerView.entries.count, 0U);
  controller.picker.pendingConfirmation(YES);
  controller.picker.pendingConfirmation = nil;
  XCTAssertNotEqual(controller.authenticationSpy, authentication);
  XCTAssertEqual(controller.authenticationSpy.evaluationCount, 1U);
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  controller.authenticationSpy.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.credentialRequestCount, 1U);
  XCTAssertEqualObjects(controller.credentialRecord, @"other-record");
  XCTAssertEqual(controller.contextSpy.completionCount, 1U);
  controller.authenticationSpy.pendingAuthentication = nil;
}

- (void)testInvalidationClosesTheConfirmationAndIgnoresALateAnswer {
  MPAutoFillOtherSiteControllerSpy *controller = self.otherSiteController;
  MPAutoFillAuthenticationSpy *authentication = controller.authenticationSpy;
  [controller fill:nil];
  void (^answer)(BOOL) = controller.picker.pendingConfirmation;
  controller.deferCatalog = YES;
  [controller handleSubscriptionEvent:@"invalidate"];
  XCTAssertNil(controller.picker.pendingConfirmation);
  XCTAssertFalse(controller.requestState.ownerAuthenticated);
  XCTAssertFalse(controller.requestState.showAll);
  XCTAssertEqual(controller.pickerView.entries.count, 0U);
  answer(YES);
  XCTAssertEqual(controller.authenticationSpy, authentication);
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  XCTAssertEqual(controller.contextSpy.completionCount, 0U);
  controller.pendingCatalogReply = nil;
}

- (void)testOtherSiteConfirmationDefaultsToCancel {
  MPAutoFillPickerView *picker = [[MPAutoFillPickerView alloc] initWithDelegate:(id)[[MPAutoFillControllerSpy alloc] init]];
  NSDictionary *entry = @{@"host": @"xn--bcher-kva.de", @"port": @""};
  NSArray *services = @[@{@"host": @"localhost", @"port": @"8765"}];
  NSAlert *alert = [picker confirmationForEntry:entry services:services];
  XCTAssertTrue([alert.informativeText containsString:@"localhost:8765"]);
  XCTAssertTrue([alert.informativeText containsString:@"xn--bcher-kva.de"]);
  // Return belongs to Cancel, the first button. Only the second one, Fill,
  // answers NSAlertSecondButtonReturn, which alone confirms.
  XCTAssertEqual(alert.buttons.count, 2U);
  XCTAssertEqualObjects(alert.buttons[0].title, MPAutoFillLocalized(@"AUTOFILL_EXT_CANCEL", @"Cancel"));
  XCTAssertEqualObjects(alert.buttons[0].keyEquivalent, @"\r");
  XCTAssertEqualObjects(alert.buttons[1].title, MPAutoFillLocalized(@"AUTOFILL_EXT_FILL", @"Fill password"));
  XCTAssertEqualObjects(alert.buttons[1].keyEquivalent, @"");
}

#pragma mark Locked database and handoff

- (void)testLockedCatalogShowsNoAccounts {
  MPAutoFillControllerSpy *controller = [self controllerForSelectedIdentity:NO];
  [controller acceptCatalogReply:[self catalogLocked:YES]];
  XCTAssertTrue(controller.pickerView.scrollView.hidden);
  XCTAssertTrue(controller.pickerView.search.hidden);
  XCTAssertNil(controller.requestState.entries);
  XCTAssertTrue(controller.requestState.hasGrant);
  XCTAssertTrue(controller.pickerView.handoffButton.enabled);
  XCTAssertFalse(controller.pickerView.fillButton.enabled);
}

- (void)testLockedCatalogOffersUnlockWithoutStartingAuthentication {
  MPAutoFillControllerSpy *controller = [self controllerForSelectedIdentity:YES];
  [controller acceptCatalogReply:[self catalogLocked:YES]];
  XCTAssertEqual(controller.fillCount, 0U);
  XCTAssertFalse(controller.pickerView.fillButton.enabled);
  XCTAssertTrue(controller.pickerView.handoffButton.enabled);
}

- (void)testUnlockedSelectedIdentityFillsButManualPickerWaits {
  MPAutoFillControllerSpy *direct = [self controllerForSelectedIdentity:YES];
  [direct acceptCatalogReply:[self catalogLocked:NO]];
  XCTAssertEqual(direct.fillCount, 1U);
  MPAutoFillControllerSpy *manual = [self controllerForSelectedIdentity:NO];
  [manual acceptCatalogReply:[self catalogLocked:NO]];
  XCTAssertEqual(manual.fillCount, 0U);
  XCTAssertTrue(manual.pickerView.fillButton.enabled);
  XCTAssertFalse(manual.pickerView.handoffButton.enabled);
  XCTAssertTrue(manual.pickerView.handoffButton.hidden);
}

- (void)testNoDatabaseHidesPickerAndReadyCatalogRestoresIt {
  MPAutoFillControllerSpy *controller = [self controllerForSelectedIdentity:NO];
  [controller acceptCatalogReply:@{@"status": @"noDocuments"}];
  XCTAssertFalse(controller.requestState.hasGrant);
  XCTAssertTrue(controller.pickerView.search.hidden);
  XCTAssertTrue(controller.pickerView.allEntriesButton.hidden);
  XCTAssertTrue(controller.pickerView.scrollView.hidden);
  XCTAssertTrue(controller.pickerView.fillButton.hidden);
  XCTAssertFalse(controller.pickerView.fillButton.enabled);
  XCTAssertEqual(controller.fillCount, 0U);
  [controller acceptCatalogReply:[self catalogLocked:NO]];
  XCTAssertTrue(controller.requestState.hasGrant);
  XCTAssertFalse(controller.pickerView.search.hidden);
  XCTAssertFalse(controller.pickerView.scrollView.hidden);
  XCTAssertFalse(controller.pickerView.fillButton.hidden);
  XCTAssertTrue(controller.pickerView.fillButton.enabled);
}

- (void)testHandoffDeliversUnlockBeforeEndingTheRequest {
  MPAutoFillControllerSpy *controller = [self controllerForSelectedIdentity:YES];
  [controller acceptCatalogReply:[self catalogLocked:YES]];
  [controller handoff:nil];
  XCTAssertEqual(controller.unlockCount, 1U);
  XCTAssertEqual(controller.cancellationCountAtUnlock, 0U); // The extension is still alive.
  XCTAssertEqual(controller.yieldCount, 1U);
  XCTAssertEqual(controller.contextSpy.cancellationCount, 1U);
  XCTAssertEqual(controller.cancellationCountAtOpen, 1U); // Safari's sheet ends before MacPass activates.
  XCTAssertEqualObjects(controller.openedHostURL.host, @"open");
  XCTAssertNil(MPCancelledGrant); // Consumed by the unlock request, no cancellation.
  [controller acceptCatalogReply:[self catalogLocked:NO]];
  XCTAssertEqual(controller.fillCount, 0U); // A late callback cannot resume it.
  [controller cancel:nil];
  XCTAssertEqual(controller.contextSpy.cancellationCount, 1U);
}

- (void)testHandoffIsSentOnceAndOpensMacPassWithoutAReply {
  MPAutoFillControllerSpy *controller = [self controllerForSelectedIdentity:YES];
  controller.deferExchange = YES;
  [controller acceptCatalogReply:[self catalogLocked:YES]];
  [controller handoff:nil];
  [controller handoff:nil];
  XCTAssertEqual(controller.unlockCount, 1U);
  XCTAssertFalse(controller.pickerView.handoffButton.enabled);
  XCTAssertEqual(controller.contextSpy.cancellationCount, 0U);
  XCTAssertNil(controller.openedHostURL);
  controller.pendingExchange(nil);
  XCTAssertEqual(controller.contextSpy.cancellationCount, 1U);
  XCTAssertNotNil(controller.openedHostURL);
  controller.pendingExchange = nil;
}

- (void)testOpenHostYieldsAndClosesRequestBeforeNativeURLOpen {
  MPAutoFillControllerSpy *controller = [self controllerForSelectedIdentity:NO];
  [controller acceptCatalogReply:@{@"status": @"noDocuments"}];
  [controller openMacPass:nil];
  XCTAssertEqual(controller.cancellationCountAtOpen, 1U);
  XCTAssertEqual(controller.yieldCount, 1U);
  XCTAssertEqualObjects(controller.openedHostURL.host, @"open");
  XCTAssertEqualObjects(controller.openedHostURL.scheme, [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".autofill"]);
  XCTAssertNil(controller.openedHostURL.query);
  XCTAssertEqual(controller.unlockCount, 0U);
  [controller openMacPass:nil];
  XCTAssertEqual(controller.contextSpy.cancellationCount, 1U);
  XCTAssertEqual(controller.yieldCount, 1U);
}

#pragma mark Host activation URL

- (NSURL *)activationURL:(NSString *)suffix {
  return [NSURL URLWithString:[NSString stringWithFormat:@"%@.autofill://open%@", NSBundle.mainBundle.bundleIdentifier, suffix]];
}

- (void)testColdActivationURLKeepsTheRegularStartup {
  MPAutoFillAppDelegateSpy *delegate = [[MPAutoFillAppDelegateSpy alloc] init];
  [delegate application:NSApp openURLs:@[[self activationURL:@""]]];
  XCTAssertEqual(delegate.revealCount, 0U); // Restoration and reopening the last database decide.
  XCTAssertNil(delegate.openedFile);
}

- (void)testWarmActivationURLRevealsWithoutTreatingParametersAsFiles {
  MPAutoFillAppDelegateSpy *delegate = [[MPAutoFillAppDelegateSpy alloc] init];
  delegate.startupState = 3; // Restored windows and finished launching.
  [delegate application:NSApp openURLs:@[[self activationURL:@"?file=/tmp/closed.kdbx"]]];
  XCTAssertEqual(delegate.revealCount, 0U);
  XCTAssertNil(delegate.openedFile);
  [delegate application:NSApp openURLs:@[[self activationURL:@""]]];
  XCTAssertEqual(delegate.revealCount, 1U);
  XCTAssertNil(delegate.openedFile);
}

- (void)testFileURLsStillUseExistingDocumentOpenPath {
  MPAutoFillAppDelegateSpy *delegate = [[MPAutoFillAppDelegateSpy alloc] init];
  [delegate application:NSApp openURLs:@[[NSURL fileURLWithPath:@"/tmp/user-selected.kdbx"]]];
  XCTAssertEqualObjects(delegate.openedFile, @"/tmp/user-selected.kdbx");
  XCTAssertEqual(delegate.revealCount, 0U);
}

#pragma mark Selected identities

- (void)testDirectIdentityNeverHandsSafariASecretBeforeAuthentication {
  MPAutoFillSilentControllerSpy *controller = [self silentControllerLocked:NO];
  [controller provideCredentialWithoutUserInteractionForIdentity:self.testIdentity];
  XCTAssertEqual(controller.viewLoadCount, 0U);
  XCTAssertNil(controller.authenticationSpy);
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  XCTAssertEqual(controller.contextSpy.completionCount, 0U);
  XCTAssertEqual(controller.contextSpy.cancellationCount, 1U);
  XCTAssertEqual(controller.contextSpy.lastError.code, ASExtensionErrorCodeUserInteractionRequired);
}

- (void)testRequestBasedCallbackAlsoRefusesEarlySecretDelivery {
  if(@available(macOS 14.0, *)) {
    MPAutoFillSilentControllerSpy *controller = [self silentControllerLocked:NO];
    ASPasswordCredentialRequest *request = [[ASPasswordCredentialRequest alloc] initWithCredentialIdentity:self.testIdentity];
    [controller provideCredentialWithoutUserInteractionForRequest:request];
    XCTAssertEqual(controller.viewLoadCount, 0U);
    XCTAssertEqual(controller.contextSpy.completionCount, 0U);
    XCTAssertEqual(controller.credentialRequestCount, 0U);
    XCTAssertEqual(controller.contextSpy.lastError.code, ASExtensionErrorCodeUserInteractionRequired);
  }
}

- (void)testDirectIdentityAuthenticatesBeforeFetchingLivePassword {
  MPAutoFillSilentControllerSpy *controller = [self silentControllerLocked:NO];
  [controller loadView];
  [controller prepareInterfaceToProvideCredentialForIdentity:self.testIdentity];
  [controller acceptCatalogReply:controller.catalog];
  XCTAssertEqual(controller.authenticationSpy.evaluationCount, 1U);
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  controller.authenticationSpy.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.contextSpy.completionCount, 1U);
  controller.authenticationSpy.pendingAuthentication = nil;
}

- (void)testLockDuringDirectIdentityAuthenticationCannotDeliverPassword {
  MPAutoFillSilentControllerSpy *controller = [self silentControllerLocked:NO];
  [controller loadView];
  [controller prepareInterfaceToProvideCredentialForIdentity:self.testIdentity];
  [controller acceptCatalogReply:controller.catalog];
  controller.credentialReply = @{@"status": @"locked"};
  controller.authenticationSpy.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.contextSpy.completionCount, 0U);
  XCTAssertEqual(controller.contextSpy.cancellationCount, 1U);
  controller.authenticationSpy.pendingAuthentication = nil;
}

- (void)testCancelledAuthenticatedRequestCannotCompleteLater {
  MPAutoFillSilentControllerSpy *controller = [self silentControllerLocked:NO];
  controller.deferCredential = YES;
  [controller loadView];
  [controller prepareInterfaceToProvideCredentialForIdentity:self.testIdentity];
  [controller acceptCatalogReply:controller.catalog];
  controller.authenticationSpy.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  [controller cancel:nil];
  controller.pendingReply(controller.credentialReply);
  controller.pendingReply(controller.credentialReply);
  XCTAssertEqual(controller.contextSpy.completionCount, 0U);
  XCTAssertEqual(controller.contextSpy.cancellationCount, 1U);
  controller.pendingReply = nil;
  controller.authenticationSpy.pendingAuthentication = nil;
}

- (void)testAuthenticatedSuccessCompletesExactlyOnce {
  MPAutoFillSilentControllerSpy *controller = [self silentControllerLocked:NO];
  controller.deferCredential = YES;
  [controller loadView];
  [controller prepareInterfaceToProvideCredentialForIdentity:self.testIdentity];
  [controller acceptCatalogReply:controller.catalog];
  controller.authenticationSpy.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  controller.pendingReply(controller.credentialReply);
  controller.pendingReply(controller.credentialReply);
  [controller cancel:nil];
  XCTAssertEqual(controller.contextSpy.completionCount, 1U);
  XCTAssertEqual(controller.contextSpy.cancellationCount, 0U);
  XCTAssertNil(MPCancelledGrant); // The fill consumed the grant.
  controller.pendingReply = nil;
  controller.authenticationSpy.pendingAuthentication = nil;
}

// A suggestion whose username or website no longer matches its entry.
- (void)testOutdatedIdentityCannotStartAuthentication {
  for(NSArray *outdated in @[@[@"localhost", @"old-user"], @[@"other.example", @"public-test"]]) {
    MPAutoFillSilentControllerSpy *controller = [self silentControllerLocked:NO];
    ASPasswordCredentialIdentity *identity = [ASPasswordCredentialIdentity identityWithServiceIdentifier:
      [[ASCredentialServiceIdentifier alloc] initWithIdentifier:outdated[0] type:ASCredentialServiceIdentifierTypeDomain]
      user:outdated[1] recordIdentifier:@"test-record"];
    [controller loadView];
    [controller prepareInterfaceToProvideCredentialForIdentity:identity];
    [controller acceptCatalogReply:controller.catalog];
    XCTAssertEqual(controller.credentialRequestCount, 0U, @"%@", outdated);
    XCTAssertEqual(controller.contextSpy.completionCount, 0U, @"%@", outdated);
    XCTAssertNil(controller.authenticationSpy, @"%@", outdated);
    XCTAssertTrue(controller.pickerView.fillButton.hidden, @"%@", outdated);
  }
}

- (void)testDomainIdentityCanFillEntryWithPort {
  MPAutoFillSilentControllerSpy *controller = [self silentControllerLocked:NO];
  NSMutableDictionary *entry = [controller.catalog[@"entries"][0] mutableCopy];
  entry[@"port"] = @"8443";
  controller.catalog = @{@"status": @"ready", @"entries": @[entry]};
  [controller loadView];
  [controller prepareInterfaceToProvideCredentialForIdentity:self.testIdentity];
  [controller acceptCatalogReply:controller.catalog];
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  XCTAssertEqual(controller.contextSpy.completionCount, 0U);
  XCTAssertEqual(controller.authenticationSpy.evaluationCount, 1U);
  controller.authenticationSpy.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.credentialRequestCount, 1U);
  XCTAssertEqual(controller.contextSpy.completionCount, 1U);
  controller.authenticationSpy.pendingAuthentication = nil;
}

#pragma mark Manual selection and authentication

- (void)testManualSelectionFetchesOnlyAfterOwnerAuthentication {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  [controller fill:nil];
  [controller fill:nil];
  XCTAssertEqual(controller.authenticationSpy.evaluationCount, 1U);
  XCTAssertEqual(controller.authenticationSpy.requestedPolicy, LAPolicyDeviceOwnerAuthentication);
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  XCTAssertFalse(controller.pickerView.footer.hidden);
  XCTAssertFalse(controller.pickerView.titleLabel.hidden);
  XCTAssertTrue(controller.authenticationSpy.embeddedAtEvaluation);
  XCTAssertFalse(controller.pickerView.authenticationContainer.hidden);
  XCTAssertFalse(controller.pickerView.systemAuthenticationButton.hidden);
  XCTAssertTrue(controller.pickerView.scrollView.hidden);
  controller.authenticationSpy.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.credentialRequestCount, 1U);
  XCTAssertEqual(controller.contextSpy.completionCount, 1U);
  XCTAssertTrue(controller.authenticationSpy.invalidated);
  XCTAssertNil(controller.pickerView.authenticationView);
  controller.authenticationSpy.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.credentialRequestCount, 1U);
  XCTAssertEqual(controller.contextSpy.completionCount, 1U);
  controller.authenticationSpy.pendingAuthentication = nil;
}

- (void)testManualAuthenticationCancellationNeverFetchesPassword {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  NSString *request = controller.requestState.requestIdentifier;
  [controller fill:nil];
  controller.authenticationSpy.pendingAuthentication(NO, [NSError errorWithDomain:LAErrorDomain code:LAErrorUserCancel userInfo:nil]);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  XCTAssertEqual(controller.contextSpy.completionCount, 0U);
  XCTAssertEqual(controller.contextSpy.cancellationCount, 1U);
  XCTAssertEqual(controller.contextSpy.lastError.code, ASExtensionErrorCodeUserCanceled);
  XCTAssertEqualObjects(MPCancelledGrant, request); // The unused grant is released.
  controller.authenticationSpy.pendingAuthentication = nil;
}

- (void)testClosingManualRequestInvalidatesAuthenticationAndIgnoresLateSuccess {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  [controller fill:nil];
  [controller cancel:nil];
  XCTAssertTrue(controller.authenticationSpy.invalidated);
  XCTAssertNil(controller.pickerView.authenticationView);
  XCTAssertTrue(controller.pickerView.authenticationContainer.hidden);
  controller.authenticationSpy.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  XCTAssertEqual(controller.contextSpy.completionCount, 0U);
  XCTAssertEqual(controller.contextSpy.cancellationCount, 1U);
  controller.authenticationSpy.pendingAuthentication = nil;
}

- (void)testSystemFallbackReplacesContextAndIgnoresLateEmbeddedSuccess {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  [controller fill:nil];
  MPAutoFillAuthenticationSpy *embedded = controller.authenticationSpy;
  NSString *request = controller.requestState.requestIdentifier;
  [controller useSystemAuthentication:nil];
  MPAutoFillAuthenticationSpy *fallback = controller.authenticationSpy;
  XCTAssertNotEqual(embedded, fallback);
  XCTAssertTrue(embedded.invalidated);
  XCTAssertFalse(fallback.embeddedAtEvaluation);
  XCTAssertEqual(fallback.requestedPolicy, LAPolicyDeviceOwnerAuthentication);
  XCTAssertNil(controller.pickerView.authenticationView);
  XCTAssertEqualObjects(controller.requestState.requestIdentifier, request);
  XCTAssertEqualObjects(controller.requestState.record, @"test-record");
  [controller useSystemAuthentication:nil]; // Repeated clicks cannot start another dialog.
  XCTAssertEqual(controller.authenticationSpy, fallback);
  embedded.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  fallback.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.credentialRequestCount, 1U);
  XCTAssertEqual(controller.contextSpy.completionCount, 1U);
  embedded.pendingAuthentication = nil; fallback.pendingAuthentication = nil;
}

- (void)testUnavailableEmbeddedAuthenticationUsesSystemOwnerPolicy {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  controller.embeddedUnavailable = YES;
  [controller fill:nil];
  XCTAssertNil(controller.pickerView.authenticationView);
  XCTAssertFalse(controller.authenticationSpy.embeddedAtEvaluation);
  XCTAssertEqual(controller.authenticationSpy.requestedPolicy, LAPolicyDeviceOwnerAuthentication);
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  controller.authenticationSpy.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.contextSpy.completionCount, 1U);
  controller.authenticationSpy.pendingAuthentication = nil;
}

- (void)testEmbeddedLockoutFallsBackWithoutIssuingPassword {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  [controller fill:nil];
  MPAutoFillAuthenticationSpy *embedded = controller.authenticationSpy;
  embedded.pendingAuthentication(NO, [NSError errorWithDomain:LAErrorDomain code:LAErrorBiometryLockout userInfo:nil]);
  [self drainAuthenticationCallback];
  XCTAssertTrue(embedded.invalidated);
  XCTAssertNotEqual(controller.authenticationSpy, embedded);
  XCTAssertFalse(controller.authenticationSpy.embeddedAtEvaluation);
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  XCTAssertEqual(controller.contextSpy.cancellationCount, 0U);
  controller.credentialReply = @{@"status": @"locked"};
  controller.authenticationSpy.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.contextSpy.completionCount, 0U);
  XCTAssertEqual(controller.contextSpy.cancellationCount, 1U);
  embedded.pendingAuthentication = nil; controller.authenticationSpy.pendingAuthentication = nil;
}

- (void)testSystemFallbackCancellationCannotBeCompletedByEitherContext {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  [controller fill:nil];
  MPAutoFillAuthenticationSpy *embedded = controller.authenticationSpy;
  [controller useSystemAuthentication:nil];
  MPAutoFillAuthenticationSpy *fallback = controller.authenticationSpy;
  fallback.pendingAuthentication(NO, [NSError errorWithDomain:LAErrorDomain code:LAErrorUserCancel userInfo:nil]);
  [self drainAuthenticationCallback];
  embedded.pendingAuthentication(YES, nil);
  fallback.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  XCTAssertEqual(controller.contextSpy.completionCount, 0U);
  XCTAssertEqual(controller.contextSpy.cancellationCount, 1U);
  XCTAssertTrue(fallback.invalidated);
  embedded.pendingAuthentication = nil; fallback.pendingAuthentication = nil;
}

- (void)testSystemFallbackFailureDoesNotRetryOrFetch {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  controller.embeddedUnavailable = YES;
  [controller fill:nil];
  MPAutoFillAuthenticationSpy *fallback = controller.authenticationSpy;
  fallback.pendingAuthentication(NO, [NSError errorWithDomain:LAErrorDomain code:LAErrorAuthenticationFailed userInfo:nil]);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.authenticationSpy, fallback);
  XCTAssertEqual(fallback.evaluationCount, 1U);
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  XCTAssertEqual(controller.contextSpy.lastError.code, ASExtensionErrorCodeFailed);
  fallback.pendingAuthentication = nil;
}

- (void)testLockDuringManualAuthenticationPreventsCompletion {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  [controller fill:nil];
  controller.credentialReply = @{@"status": @"locked"};
  controller.authenticationSpy.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.credentialRequestCount, 1U);
  XCTAssertEqual(controller.contextSpy.completionCount, 0U);
  XCTAssertEqual(controller.contextSpy.cancellationCount, 1U);
  controller.authenticationSpy.pendingAuthentication = nil;
}

#pragma mark Catalog refresh

- (void)testHandshakePrecedesCatalogAndAbandonedHandshakeIsClosed {
  MPAutoFillHandshakeControllerSpy *controller = [[MPAutoFillHandshakeControllerSpy alloc] init];
  controller.contextSpy = [[MPAutoFillContextSpy alloc] init];
  [controller loadView]; controller.appeared = YES;
  [controller prepareCredentialListForServiceIdentifiers:@[]];
  [controller startWhenVisible];
  XCTAssertEqual(controller.subscriptionCount, 1U);
  XCTAssertNil(controller.message);
  void (^abandoned)(MPAutoFillStream *) = controller.pendingSubscription;
  [controller prepareCredentialListForServiceIdentifiers:@[]];
  MPAutoFillStreamSpy *old = [[MPAutoFillStreamSpy alloc] initWithSocket:-1];
  abandoned(old);
  XCTAssertEqual(old.closeCount, 1U);
  XCTAssertNil(controller.requestState.subscription);
  XCTAssertNil(controller.message);
  MPAutoFillStreamSpy *current = [[MPAutoFillStreamSpy alloc] initWithSocket:-1];
  controller.pendingSubscription(current);
  XCTAssertEqual(controller.requestState.subscription, current);
  XCTAssertEqualObjects(controller.message[@"operation"], @"catalog");
  [controller startWhenVisible];
  XCTAssertEqual(controller.subscriptionCount, 2U);
  [controller cancel:nil];
  XCTAssertEqual(current.closeCount, 1U);
  controller.pendingSubscription = nil; controller.pendingReply = nil;
}

- (void)testFailedHandshakeNeverRequestsCatalogOrReconnects {
  MPAutoFillHandshakeControllerSpy *controller = [[MPAutoFillHandshakeControllerSpy alloc] init];
  controller.contextSpy = [[MPAutoFillContextSpy alloc] init];
  [controller loadView]; controller.appeared = YES;
  [controller prepareCredentialListForServiceIdentifiers:@[]];
  controller.pendingSubscription(nil);
  [controller startWhenVisible]; [controller refreshVisibleCatalog];
  XCTAssertEqual(controller.subscriptionCount, 1U);
  XCTAssertNil(controller.message);
  XCTAssertNil(controller.requestState.subscription);
  XCTAssertNil(controller.requestState.entries);
  XCTAssertFalse(controller.requestState.hasGrant);
  controller.pendingSubscription = nil;
}

- (void)testInvalidationRejectsCredentialReplyIssuedBeforeTheEvent {
  MPAutoFillLateCatalogControllerSpy *controller = [[MPAutoFillLateCatalogControllerSpy alloc] init];
  controller.contextSpy = [[MPAutoFillContextSpy alloc] init];
  [controller loadView];
  [controller prepareCredentialListForServiceIdentifiers:@[]];
  controller.requestState.subscription = [[MPAutoFillStreamSpy alloc] initWithSocket:-1];
  controller.appeared = YES;
  __block BOOL accepted = NO;
  [controller exchangeOperation:@"credential" completion:^(NSDictionary *reply) { accepted = YES; }];
  void (^reply)(NSDictionary *) = controller.pendingReply;
  [controller handleSubscriptionEvent:@"invalidate"];
  reply(@{@"status": @"ready", @"user": @"public-test", @"password": @"public-fixture"});
  XCTAssertFalse(accepted);
  XCTAssertFalse(controller.requestState.hasGrant);
  XCTAssertEqual(controller.pickerView.entries.count, 0U);
  [controller cancel:nil]; controller.pendingReply = nil;
}

- (void)testInvalidGrantDeadlineFailsClosedAndDoesNotCreateATimer {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  for(id deadline in @[@0, @(NAN), @(INFINITY), NSNull.null]) {
    NSMutableDictionary *catalog = controller.catalog.mutableCopy;
    catalog[@"deadline"] = deadline;
    [controller acceptCatalogReply:catalog];
    XCTAssertFalse(controller.requestState.hasGrant);
    XCTAssertFalse(controller.pickerView.fillButton.enabled);
    XCTAssertEqual(controller.pickerView.entries.count, 0U);
    XCTAssertNil(controller.requestState.deadlineTimer);
  }
}

- (void)testInvalidationClearsBothCatalogsAndRejectsLateAuthenticationAndCatalog {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  controller.appeared = YES; controller.deferCatalog = YES;
  [self refresh:controller];
  void (^oldReply)(NSDictionary *) = controller.pendingCatalogReply;
  [controller fill:nil];
  MPAutoFillAuthenticationSpy *authentication = controller.authenticationSpy;
  NSUInteger generation = controller.requestState.generation;
  NSArray *services = controller.requestState.services;
  [controller handleSubscriptionEvent:@"invalidate"];
  XCTAssertGreaterThan(controller.requestState.generation, generation);
  XCTAssertTrue(authentication.invalidated);
  XCTAssertNil(controller.requestState.afterAuthentication);
  XCTAssertFalse(controller.requestState.ownerAuthenticated);
  XCTAssertFalse(controller.requestState.showAll);
  XCTAssertEqualObjects(controller.requestState.services, services);
  XCTAssertNil(controller.requestState.entries);
  XCTAssertEqual(controller.pickerView.entries.count, 0U);
  XCTAssertEqual(controller.pickerView.table.numberOfRows, 0);
  oldReply(controller.catalog);
  authentication.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  XCTAssertNil(controller.requestState.entries);
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  XCTAssertEqual(controller.contextSpy.completionCount, 0U);
  controller.pendingCatalogReply(controller.catalog);
  XCTAssertTrue(controller.pickerView.fillButton.enabled);
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  authentication.pendingAuthentication = nil; controller.pendingCatalogReply = nil;
}

- (void)testCatalogChangesDuringAuthenticationCoalesceWithoutCancellingIt {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  controller.appeared = YES;
  controller.requestState.subscription = [[MPAutoFillStreamSpy alloc] initWithSocket:-1];
  [controller toggleAllEntries:nil];
  MPAutoFillAuthenticationSpy *authentication = controller.authenticationSpy;
  NSUInteger generation = controller.requestState.generation;
  [controller handleSubscriptionEvent:@"catalogChanged"];
  [controller handleSubscriptionEvent:@"catalogChanged"];
  XCTAssertEqual(controller.requestState.generation, generation);
  XCTAssertFalse(authentication.invalidated);
  XCTAssertNil(controller.lastCatalogMessage);
  XCTAssertTrue(controller.requestState.pendingCatalogRefresh);
  authentication.pendingAuthentication(NO, [NSError errorWithDomain:LAErrorDomain code:LAErrorUserCancel userInfo:nil]);
  [self drainAuthenticationCallback];
  XCTAssertNotNil(controller.lastCatalogMessage);
  XCTAssertFalse(controller.requestState.pendingCatalogRefresh);
  XCTAssertFalse(controller.requestState.busy);
  authentication.pendingAuthentication = nil;
}

- (void)testDisconnectClearsRowsAndDoesNotReconnectOrAdoptOldStreamEvents {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  controller.appeared = YES;
  MPAutoFillStreamSpy *stream = [[MPAutoFillStreamSpy alloc] initWithSocket:-1];
  controller.requestState.subscription = stream;
  [controller subscriptionDisconnected:stream];
  XCTAssertEqual(stream.closeCount, 1U);
  XCTAssertNil(controller.requestState.subscription);
  XCTAssertNil(controller.requestState.entries);
  XCTAssertEqual(controller.pickerView.entries.count, 0U);
  XCTAssertFalse(controller.requestState.hasGrant);
  XCTAssertNil(controller.requestState.deadlineTimer);
  [controller refreshVisibleCatalog];
  XCTAssertNil(controller.lastCatalogMessage);
  MPAutoFillStreamSpy *replacement = [[MPAutoFillStreamSpy alloc] initWithSocket:-1];
  controller.requestState.subscription = replacement;
  [controller subscriptionDisconnected:stream];
  XCTAssertEqual(controller.requestState.subscription, replacement);
  [controller cancel:nil]; [controller cancel:nil];
  XCTAssertEqual(replacement.closeCount, 1U);
}

- (void)testScopeChangeKeepsOneSubscriptionAndAuthExpiryDropsAllRows {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  controller.appeared = YES;
  MPAutoFillStreamSpy *stream = [[MPAutoFillStreamSpy alloc] initWithSocket:-1];
  controller.requestState.subscription = stream;
  controller.requestState.authenticatedUntil = NSProcessInfo.processInfo.systemUptime + 60;
  [controller toggleAllEntries:nil];
  XCTAssertEqual(controller.requestState.subscription, stream);
  XCTAssertTrue(controller.requestState.showAll);
  NSTimer *expiry = controller.requestState.deadlineTimer;
  XCTAssertNotNil(expiry);
  controller.requestState.authenticatedUntil = NSProcessInfo.processInfo.systemUptime - 1;
  controller.deferCatalog = YES;
  [expiry fire];
  XCTAssertFalse(controller.requestState.showAll);
  XCTAssertNil(controller.requestState.entries);
  XCTAssertEqual(controller.pickerView.entries.count, 0U);
  XCTAssertNil(controller.lastCatalogMessage[@"scope"]);
  XCTAssertEqual(controller.requestState.subscription, stream);
  controller.pendingCatalogReply = nil;
}

- (void)testSleepDisappearanceAndStateDeallocationUnsubscribe {
  for(NSUInteger path = 0; path < 3; path++) {
    MPAutoFillStreamSpy *stream = [[MPAutoFillStreamSpy alloc] initWithSocket:-1];
    @autoreleasepool {
      if(path == 2) {
        // AppKit may retain a loaded view controller for deferred layout. Test
        // deallocation of the actual resource owner without presentation lifetime.
        MPAutoFillRequestState *state = [[MPAutoFillRequestState alloc] init];
        state.subscription = stream;
        state = nil;
      }
      else {
        MPAutoFillSilentControllerSpy *controller = self.manualController;
        controller.requestState.subscription = stream;
        if(path == 0) [NSWorkspace.sharedWorkspace.notificationCenter postNotificationName:NSWorkspaceWillSleepNotification object:nil];
        else [controller viewDidDisappear];
        controller = nil;
      }
    }
    [self drainAuthenticationCallback];
    XCTAssertEqual(stream.closeCount, 1U, @"cleanup path %lu", (unsigned long)path);
  }
}

- (void)testVisibleLockedIdentityRefreshesWithoutAutomaticallyFillingAfterUnlock {
  MPAutoFillSilentControllerSpy *controller = [self silentControllerLocked:YES];
  [controller loadView];
  [controller prepareInterfaceToProvideCredentialForIdentity:self.testIdentity];
  [controller acceptCatalogReply:controller.catalog];
  XCTAssertTrue(controller.pickerView.fillButton.hidden);
  XCTAssertTrue(controller.pickerView.handoffButton.enabled);
  controller.appeared = YES;
  controller.catalog = [self catalogLocked:NO];
  [self refresh:controller];
  XCTAssertTrue(controller.pickerView.fillButton.enabled);
  XCTAssertFalse(controller.pickerView.fillButton.hidden);
  XCTAssertTrue(controller.pickerView.handoffButton.hidden);
  XCTAssertNil(controller.authenticationSpy);
  XCTAssertEqual(controller.credentialRequestCount, 0U);
}

- (void)testManualRefreshPreservesSelectedAccountAndSearch {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  NSMutableDictionary *second = [controller.catalog[@"entries"][0] mutableCopy];
  second[@"record"] = @"second-record"; second[@"user"] = @"second-user";
  controller.catalog = @{@"status": @"ready", @"entries": @[controller.catalog[@"entries"][0], second]};
  [controller acceptCatalogReply:controller.catalog];
  [controller.pickerView.table selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
  controller.pickerView.search.stringValue = @"second";
  [controller filterEntries:nil]; // Model the search field's change notification.
  controller.appeared = YES;
  [self refresh:controller];
  XCTAssertEqualObjects(controller.requestState.record, @"second-record");
  XCTAssertEqualObjects(controller.pickerView.search.stringValue, @"second");
  XCTAssertEqual(controller.pickerView.entries.count, 1U);
  XCTAssertTrue(controller.pickerView.fillButton.enabled);
}

- (void)testBackgroundRefreshLeavesFillAndActiveGrantUsableWithoutRedrawingUnchangedData {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  controller.appeared = YES;
  controller.deferCatalog = YES;
  NSString *request = controller.requestState.requestIdentifier;
  NSUInteger filterCount = controller.filterCount;
  [self refresh:controller];
  XCTAssertTrue(controller.pickerView.fillButton.enabled);
  XCTAssertFalse(controller.pickerView.fillButton.hidden);
  XCTAssertTrue(controller.pickerView.handoffButton.hidden);
  XCTAssertEqualObjects(controller.requestState.requestIdentifier, request);
  XCTAssertTrue(controller.requestState.hasGrant);
  XCTAssertEqual(controller.filterCount, filterCount);
  controller.pendingCatalogReply(controller.catalog);
  XCTAssertTrue(controller.pickerView.fillButton.enabled);
  XCTAssertTrue(controller.pickerView.handoffButton.hidden);
  XCTAssertEqual(controller.filterCount, filterCount);
  XCTAssertTrue(controller.requestState.hasGrant);
  XCTAssertNotEqualObjects(controller.requestState.requestIdentifier, request);
  XCTAssertEqualObjects(MPCancelledGrant, request); // The replaced grant is released.
  controller.pendingCatalogReply = nil;
}

- (void)testRefreshReplyCannotReplaceGrantDuringAuthentication {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  controller.appeared = YES;
  controller.deferCatalog = YES;
  NSString *request = controller.requestState.requestIdentifier;
  [self refresh:controller];
  NSString *refresh = controller.lastCatalogMessage[@"request"];
  [controller fill:nil];
  XCTAssertEqual(controller.authenticationSpy.evaluationCount, 1U);
  controller.pendingCatalogReply(controller.catalog);
  XCTAssertEqualObjects(controller.requestState.requestIdentifier, request);
  XCTAssertTrue(controller.requestState.hasGrant);
  XCTAssertEqualObjects(MPCancelledGrant, refresh); // Only the unused refresh grant is released.
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  controller.authenticationSpy.pendingAuthentication(YES, nil);
  [self drainAuthenticationCallback];
  XCTAssertEqual(controller.credentialRequestCount, 1U);
  XCTAssertEqual(controller.contextSpy.completionCount, 1U);
  controller.pendingCatalogReply = nil;
  controller.authenticationSpy.pendingAuthentication = nil;
}

- (void)testLateRefreshAfterCancellationCannotRestorePickerOrGrant {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  controller.appeared = YES;
  controller.deferCatalog = YES;
  [self refresh:controller];
  NSUInteger filterCount = controller.filterCount;
  [controller cancel:nil];
  controller.pendingCatalogReply(controller.catalog);
  XCTAssertFalse(controller.requestState.hasGrant);
  XCTAssertNil(controller.requestState.entries);
  XCTAssertEqual(controller.filterCount, filterCount);
  XCTAssertEqual(controller.contextSpy.cancellationCount, 1U);
  XCTAssertEqual(controller.credentialRequestCount, 0U);
  controller.pendingCatalogReply = nil;
}

- (void)testLateInitialCatalogReplyCancelsItsUnusedGrant {
  MPAutoFillLateCatalogControllerSpy *controller = [[MPAutoFillLateCatalogControllerSpy alloc] init];
  controller.contextSpy = [[MPAutoFillContextSpy alloc] init];
  [controller loadView];
  controller.appeared = YES;
  [controller prepareCredentialListForServiceIdentifiers:@[]];
  NSString *request = controller.message[@"request"];
  XCTAssertNotNil(request);
  [controller cancel:nil];
  XCTAssertNil(MPCancelledGrant); // No grant was known when the request ended.
  controller.pendingReply(@{@"status": @"ready", @"entries": @[]});
  XCTAssertNil(controller.requestState.entries);
  XCTAssertEqualObjects(MPCancelledGrant, request);
  controller.pendingReply = nil;
}

- (void)testReadyCatalogIsRenewedOnlyBeforeItsGrantExpires {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  controller.appeared = YES;
  controller.requestState.subscription = [[MPAutoFillStreamSpy alloc] initWithSocket:-1];
  controller.requestState.grantDeadline = NSProcessInfo.processInfo.systemUptime + 90;
  [controller scheduleRequestDeadline];
  NSTimer *deadline = controller.requestState.deadlineTimer;
  XCTAssertNotNil(deadline);
  XCTAssertEqualWithAccuracy(deadline.fireDate.timeIntervalSinceNow, 90, 1);
  XCTAssertNil(controller.lastCatalogMessage);
  controller.requestState.grantDeadline = NSProcessInfo.processInfo.systemUptime - 1;
  [deadline fire];
  XCTAssertNotNil(controller.lastCatalogMessage);
  controller.lastCatalogMessage = nil;
  controller.catalog = [self catalogLocked:YES];
  [self refresh:controller];
  XCTAssertNotNil(controller.requestState.deadlineTimer); // Only the locked grant's deadline.
  XCTAssertEqual(controller.requestState.deadlineTimer.timeInterval, 0); // Non-repeating.
}

- (void)testRefreshAppliesLockChangeAndEnablesFillOnlyAfterExternalUnlock {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  controller.appeared = YES;
  controller.catalog = [self catalogLocked:YES];
  [self refresh:controller];
  XCTAssertFalse(controller.pickerView.fillButton.enabled);
  XCTAssertTrue(controller.pickerView.fillButton.hidden);
  XCTAssertTrue(controller.pickerView.handoffButton.enabled);
  XCTAssertFalse(controller.pickerView.handoffButton.hidden);
  controller.catalog = [self catalogLocked:NO];
  [self refresh:controller];
  XCTAssertTrue(controller.pickerView.fillButton.enabled);
  XCTAssertFalse(controller.pickerView.fillButton.hidden);
  XCTAssertTrue(controller.pickerView.handoffButton.hidden);
  XCTAssertNil(controller.authenticationSpy);
  XCTAssertEqual(controller.credentialRequestCount, 0U);
}

#pragma mark Search

- (void)search:(NSString *)query in:(MPAutoFillSilentControllerSpy *)controller {
  controller.pickerView.search.stringValue = query;
  [controller pickerViewQueryDidChange:controller.pickerView];
}

- (void)testSearchRunsInTheHostAndCoalescesWhileACatalogIsPending {
  self.continueAfterFailure = NO; // A missing request must not call a nil reply.
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  controller.appeared = YES;
  controller.deferCatalog = YES;
  NSUInteger requests = controller.catalogRequestCount;
  [self search:@"pu" in:controller];
  XCTAssertEqual(controller.catalogRequestCount, requests + 1);
  XCTAssertEqualObjects(controller.lastCatalogMessage[@"query"], @"pu");
  XCTAssertEqualObjects(controller.lastCatalogMessage[@"services"], (@[@{@"host": @"localhost", @"port": @""}]));
  XCTAssertTrue(MPAutoFillValidateRequest(controller.lastCatalogMessage));
  // Typing while the host searches: one follow-up, for the latest query.
  for(NSString *query in @[@"pub", @"publ", @"public"]) [self search:query in:controller];
  XCTAssertEqual(controller.catalogRequestCount, requests + 1);
  void (^reply)(NSDictionary *) = controller.pendingCatalogReply;
  controller.pendingCatalogReply = nil;
  reply(controller.catalog);
  XCTAssertEqual(controller.catalogRequestCount, requests + 2);
  XCTAssertEqualObjects(controller.lastCatalogMessage[@"query"], @"public");
  controller.pendingCatalogReply(controller.catalog);
  XCTAssertEqual(controller.catalogRequestCount, requests + 2);
  XCTAssertTrue(controller.pickerView.fillButton.enabled);
  // An empty search asks for the whole scope again.
  [self search:@"" in:controller];
  XCTAssertEqual(controller.catalogRequestCount, requests + 3);
  XCTAssertNil(controller.lastCatalogMessage[@"query"]);
  controller.pendingCatalogReply = nil;
}

// The host gets at most 256 UTF-16 units, cut before a character that would
// cross the limit. It may then list more than the full query matches; the
// picker shows only what the full query matches.
- (void)testLongSearchIsCutAtACharacterBoundaryAndNarrowedLocally {
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  controller.appeared = YES;
  NSString *limit = [@"" stringByPaddingToLength:256 withString:@"a" startingAtIndex:0];
  NSString *head = [limit substringToIndex:255];
  NSMutableDictionary *entry = [controller.catalog[@"entries"][0] mutableCopy];
  entry[@"title"] = limit;
  controller.catalog = @{@"status": @"ready", @"entries": @[entry]};
  // The thumbs-up with a skin tone is one character of four UTF-16 units.
  NSArray *cases = @[@[limit, limit, @1], @[[limit stringByAppendingString:@"b"], limit, @0], @[[head stringByAppendingString:@"\U0001F44D\U0001F3FDb"], head, @0]];
  for(NSArray *item in cases) {
    [self search:item[0] in:controller];
    XCTAssertEqualObjects(controller.lastCatalogMessage[@"query"], item[1]);
    XCTAssertTrue(MPAutoFillValidateRequest(controller.lastCatalogMessage));
    XCTAssertEqual(controller.pickerView.entries.count, [item[2] unsignedIntegerValue], @"%lu", (unsigned long)[item[0] length]);
  }
}

- (void)testSelectedSuggestionNeverSendsASearch {
  MPAutoFillSilentControllerSpy *controller = [self silentControllerLocked:NO];
  [controller loadView];
  [controller prepareInterfaceToProvideCredentialForIdentity:self.testIdentity];
  controller.pickerView.search.stringValue = @"public";
  controller.appeared = YES;
  [self refresh:controller];
  XCTAssertEqualObjects(controller.lastCatalogMessage[@"record"], @"test-record");
  XCTAssertNil(controller.lastCatalogMessage[@"query"]);
  XCTAssertTrue(MPAutoFillValidateRequest(controller.lastCatalogMessage));
  controller.authenticationSpy.pendingAuthentication = nil;
}

- (void)testHeldBackAccountsAreReportedAndOlderRepliesFollowTheCurrentSearch {
  self.continueAfterFailure = NO; // A missing request must not call a nil reply.
  MPAutoFillSilentControllerSpy *controller = self.manualController;
  controller.appeared = YES;
  NSDictionary *first = controller.catalog[@"entries"][0];
  NSMutableDictionary *second = [first mutableCopy], *third = [first mutableCopy];
  second[@"record"] = @"second-record"; second[@"user"] = @"second-user";
  third[@"record"] = @"third-record"; third[@"user"] = @"third-user";
  NSDictionary *partial = @{@"status": @"ready", @"entries": @[first, second], @"more": @YES};
  NSString *more = MPAutoFillLocalized(@"AUTOFILL_EXT_MORE", @"Not all accounts are listed. Refine the search to find the others.");
  [controller acceptCatalogReply:partial];
  XCTAssertTrue(controller.requestState.moreEntries);
  XCTAssertEqualObjects(controller.pickerView.status, more);
  // The rows narrow at once, before the host answers.
  controller.deferCatalog = YES;
  [self search:@"second" in:controller];
  XCTAssertEqualObjects([controller.pickerView.entries valueForKey:@"record"], @[@"second-record"]);
  // A reply for an earlier, broader search shows only the current matches.
  controller.pendingCatalogReply(@{@"status": @"ready", @"entries": @[first, second, third], @"more": @YES});
  XCTAssertEqualObjects([controller.pickerView.entries valueForKey:@"record"], @[@"second-record"]);
  XCTAssertEqualObjects(controller.pickerView.status, more);
  XCTAssertTrue(controller.pickerView.fillButton.enabled);
  // A complete list restores the regular status.
  [self refresh:controller];
  XCTAssertEqualObjects(controller.lastCatalogMessage[@"query"], @"second");
  controller.pendingCatalogReply(@{@"status": @"ready", @"entries": @[second]});
  XCTAssertFalse(controller.requestState.moreEntries);
  XCTAssertEqualObjects(controller.pickerView.status, MPAutoFillLocalized(@"AUTOFILL_EXT_CHOOSE", @"Choose an account to fill from the active database."));
  // Invalidation forgets held-back accounts with the rows and the search.
  [controller acceptCatalogReply:partial];
  XCTAssertTrue(controller.requestState.moreEntries);
  [controller handleSubscriptionEvent:MPAutoFillEventInvalidate];
  XCTAssertFalse(controller.requestState.moreEntries);
  XCTAssertEqualObjects(controller.pickerView.query, @"");
  XCTAssertNil(controller.lastCatalogMessage[@"query"]);
  controller.pendingCatalogReply = nil;
}

#pragma mark Panel layout

// Each mode is as tall as its visible controls: 20 pt margins, 12 pt between
// rows and no empty row, also with a status that wraps.
- (void)testPanelsFitTheirVisibleControls {
  MPAutoFillPickerView *picker = [[MPAutoFillPickerView alloc] initWithDelegate:(id)[[MPAutoFillControllerSpy alloc] init]];
  NSString *wrapping = [@"" stringByPaddingToLength:300 withString:@"A status that wraps. " startingAtIndex:0];
  for(NSString *status in @[@"Choose an account.", wrapping]) {
    for(MPAutoFillPickerMode mode = MPAutoFillPickerModeMessage; mode <= MPAutoFillPickerModeSystemAuthentication; mode++) {
      picker.status = status;
      picker.authenticationView = mode == MPAutoFillPickerModeEmbeddedAuthentication ? [[NSView alloc] initWithFrame:NSZeroRect] : nil;
      picker.mode = mode;
      NSSize size = picker.preferredSize;
      picker.frame = (NSRect){NSZeroPoint, size};
      [picker layoutSubtreeIfNeeded];
      NSMutableArray<NSValue *> *rows = NSMutableArray.array;
      for(NSView *view in picker.content.arrangedSubviews) {
        NSRect row = [view.superview convertRect:[view alignmentRectForFrame:view.frame] toView:picker];
        if(!view.hidden && !NSIsEmptyRect(row)) [rows addObject:[NSValue valueWithRect:row]];
      }
      NSString *context = [NSString stringWithFormat:@"mode %ld, %lu characters", (long)mode, (unsigned long)status.length];
      XCTAssertGreaterThan(rows.count, 0U, @"%@", context);
      XCTAssertEqualWithAccuracy(size.height - NSMaxY(rows.firstObject.rectValue), 20, 1, @"%@", context);
      XCTAssertEqualWithAccuracy(NSMinY(rows.lastObject.rectValue), 20, 1, @"%@", context);
      for(NSUInteger index = 1; index < rows.count; index++) {
        XCTAssertEqualWithAccuracy(NSMinY(rows[index - 1].rectValue) - NSMaxY(rows[index].rectValue), 12, 1, @"%@, row %lu", context, (unsigned long)index);
      }
    }
  }
}

// The buttons share one row in the macOS order: alternatives at the leading
// edge, Cancel and then the default button at the trailing edge. Longer titles
// widen the panel instead of overflowing it.
- (void)testButtonsShareOneRowInTheMacOSOrder {
  MPAutoFillPickerView *picker = [[MPAutoFillPickerView alloc] initWithDelegate:(id)[[MPAutoFillControllerSpy alloc] init]];
  NSButton *cancel = [picker.footer.views filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"keyEquivalent == %@", @"\e"]].firstObject;
  XCTAssertNotNil(cancel);
  NSDictionary<NSNumber *, NSArray<NSButton *> *> *rows = @{
    @(MPAutoFillPickerModeMessage): @[picker.openButton, cancel],
    @(MPAutoFillPickerModeUnlock): @[picker.openButton, cancel, picker.handoffButton],
    @(MPAutoFillPickerModeList): @[picker.openButton, cancel, picker.fillButton],
    @(MPAutoFillPickerModeSelected): @[picker.openButton, cancel, picker.fillButton],
    @(MPAutoFillPickerModeEmbeddedAuthentication): @[picker.systemAuthenticationButton, cancel],
  };
  for(NSString *suffix in @[@"", @" with a much longer localized title"]) {
    for(NSButton *button in picker.footer.views) button.title = [button.title stringByAppendingString:suffix];
    for(NSNumber *mode in rows) {
      picker.authenticationView = mode.integerValue == MPAutoFillPickerModeEmbeddedAuthentication ? [[NSView alloc] initWithFrame:NSZeroRect] : nil;
      picker.mode = mode.integerValue;
      NSSize size = picker.preferredSize;
      picker.frame = (NSRect){NSZeroPoint, size};
      [picker layoutSubtreeIfNeeded];
      NSMutableArray<NSButton *> *visible = NSMutableArray.array;
      for(NSButton *button in picker.footer.views) if(!button.hidden) [visible addObject:button];
      NSRect (^rect)(NSButton *) = ^NSRect(NSButton *button) { return [button.superview convertRect:[button alignmentRectForFrame:button.frame] toView:picker]; };
      [visible sortUsingComparator:^NSComparisonResult(NSButton *a, NSButton *b) { return [@(NSMinX(rect(a))) compare:@(NSMinX(rect(b)))]; }];
      NSString *context = [NSString stringWithFormat:@"mode %@, title suffix \"%@\"", mode, suffix];
      XCTAssertEqualObjects(visible, rows[mode], @"%@", context);
      XCTAssertEqualWithAccuracy(NSMinX(rect(visible.firstObject)), 20, 1, @"%@", context);
      XCTAssertEqualWithAccuracy(size.width - NSMaxX(rect(visible.lastObject)), 20, 1, @"%@", context);
      for(NSUInteger index = 1; index < visible.count; index++) {
        XCTAssertEqualWithAccuracy(NSMidY(rect(visible[index])), NSMidY(rect(visible[0])), 1, @"%@", context);
        XCTAssertLessThanOrEqual(NSMaxX(rect(visible[index - 1])), NSMinX(rect(visible[index])), @"%@", context);
      }
      // Return goes to the trailing default button, Escape to Cancel.
      XCTAssertEqualObjects(visible.lastObject.keyEquivalent, visible.count == 3 ? @"\r" : @"\e", @"%@", context);
    }
  }
}
@end
