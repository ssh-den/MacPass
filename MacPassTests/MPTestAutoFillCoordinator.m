#import <XCTest/XCTest.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import "../MacPass/MPAutoFillCoordinator.h"
#import "MPDocument.h"
#import "../AutoFillShared/MPAutoFillDomain.h"
#import "../AutoFillShared/MPAutoFillTransport.h"
#import "../MacPassAutoFill/MPAutoFillPickerView.h"
#import "../MacPassAutoFill/MPAutoFillRequestState.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import <sys/socket.h>
#import <arpa/inet.h>

static NSString *const MPTestAutoFillSuite = @"MacPassTests.AutoFill";

@interface MPDocument (AutoFillTesting)
@property (atomic) BOOL lockedForFileChange;
@property (nonatomic) BOOL autoFillMergePending;
@end

@interface MPAutoFillServer (Testing)
@property NSMutableDictionary<NSString *, NSDictionary *> *grants;
- (NSDictionary *)replyToMessage:(NSDictionary *)message owner:(NSData *)owner;
- (void)answerMessage:(NSDictionary *)message owner:(NSData *)owner socket:(int)fd error:(NSError **)error;
- (void)revokeGrant:(NSDictionary *)grant request:(NSString *)request;
- (BOOL)subscribeRequest:(NSString *)request socket:(int)fd;
@property NSMutableDictionary<NSString *, MPAutoFillStream *> *subscribers;
@end

@interface MPAutoFillCoordinator (Testing)
@property BOOL enabled;
@property BOOL quitting;
@property BOOL indexDirty;
@property BOOL indexBusy;
@property BOOL indexMayHoldIdentities;
@property (weak) MPDocument *lastActiveDocument;
@property NSMutableDictionary<NSString *, NSDictionary *> *metadata;
@property NSTimer *expirationTimer;
@property NSTimeInterval unlockDeadline;
- (void)publishIndex;
- (void)refreshCatalog;
- (void)documentsChanged:(NSNotification *)notification;
- (void)enabledPreferenceChanged;
- (void)applicationDidBecomeActive:(NSNotification *)notification;
- (void)didPublishIdentities:(BOOL)publishing success:(BOOL)success error:(NSError *)error;
@end

@interface MPAutoFillTestDocument : MPDocument
@property BOOL testLocked;
@property BOOL testConflict;
@end
@implementation MPAutoFillTestDocument
- (BOOL)encrypted { return self.testLocked; }
- (BOOL)autoFillUnavailable { return self.testConflict; }
@end

// Exercise the real publication flow without touching the user's system store.
@interface MPAutoFillIdentityStoreSpy : NSObject
@property (getter=isEnabled) BOOL enabled;
@property NSUInteger stateRequestCount;
@property NSUInteger replacementCount;
@property NSUInteger removalCount;
@property NSArray *identities;
@property BOOL deferState;
@property (copy) void (^pendingState)(ASCredentialIdentityStoreState *);
@property (copy) void (^pendingReplacement)(BOOL, NSError *);
@property (copy) void (^pendingRemoval)(BOOL, NSError *);
@end
@implementation MPAutoFillIdentityStoreSpy
- (void)getCredentialIdentityStoreStateWithCompletion:(void (^)(ASCredentialIdentityStoreState *))completion {
  self.stateRequestCount++;
  if(self.deferState) self.pendingState = completion;
  else completion((id)self);
}
- (void)replaceCredentialIdentityEntries:(NSArray *)identities completion:(void (^)(BOOL, NSError *))completion {
  self.replacementCount++;
  self.identities = identities;
  self.pendingReplacement = completion;
}
- (void)replaceCredentialIdentitiesWithIdentities:(NSArray *)identities completion:(void (^)(BOOL, NSError *))completion {
  [self replaceCredentialIdentityEntries:identities completion:completion];
}
- (void)removeAllCredentialIdentitiesWithCompletion:(void (^)(BOOL, NSError *))completion {
  self.removalCount++;
  self.pendingRemoval = completion;
}
@end

// Never binds the real socket or writes the system identity store.
API_AVAILABLE(macos(13.0))
@interface MPAutoFillTestCoordinator : MPAutoFillCoordinator
@property NSArray *documents;
@property MPAutoFillIdentityStoreSpy *store;
@property BOOL testListening;
@property BOOL canStart;
@end
@implementation MPAutoFillTestCoordinator
- (NSArray *)openDocuments { return self.documents ?: @[]; }
- (ASCredentialIdentityStore *)identityStore { return (id)self.store; }
- (BOOL)isListening { return self.testListening; }
- (BOOL)startServer { self.testListening = self.canStart; return self.testListening; }
- (void)stopServer { [super stopServer]; self.testListening = NO; }
@end

// Captures the catalog instead of publishing it, for catalog/grant tests.
API_AVAILABLE(macos(13.0))
@interface MPAutoFillCatalogCoordinator : MPAutoFillTestCoordinator
@property NSArray *published;
@property NSUInteger invalidationCount;
@property NSUInteger catalogChangeCount;
@end
@implementation MPAutoFillCatalogCoordinator
- (void)publishIndex { self.published = self.metadata.allValues; }
- (void)invalidateGrants { [super invalidateGrants]; self.invalidationCount++; }
- (void)catalogDidChange { [super catalogDidChange]; self.catalogChangeCount++; }
@end

// Keeps a pending unlock handoff instead of showing windows.
API_AVAILABLE(macos(13.0))
@interface MPAutoFillUnlockCoordinator : MPAutoFillCatalogCoordinator
@end
@implementation MPAutoFillUnlockCoordinator
- (void)showPendingUnlock {}
@end

// The server's grant handling with a fixed public entry.
API_AVAILABLE(macos(13.0))
@interface MPAutoFillServerStub : MPAutoFillServer
@property NSString *status;
@end
@implementation MPAutoFillServerStub
- (NSString *)providerStatus { return self.status ?: @"ready"; }
- (NSArray *)catalogEntries {
  return @[@{@"record": @"test-record", @"title": @"Test", @"user": @"public-test", @"host": @"localhost",
             @"port": @"", @"database": @"Test database", @"available": @YES}];
}
- (NSDictionary *)credentialForRecord:(NSString *)record expecting:(NSDictionary *)binding {
  if(![self.providerStatus isEqual:@"ready"]) return @{@"status": self.providerStatus};
  return @{@"status": @"ready", @"user": binding[@"user"], @"password": @"public-password"};
}
@end

// Listed accounts over the 1 MiB frame limit, even at 100 of them.
API_AVAILABLE(macos(13.0))
@interface MPAutoFillLargeServerStub : MPAutoFillServerStub
@end
@implementation MPAutoFillLargeServerStub
- (NSArray *)catalogEntries {
  NSString *title = [@"" stringByPaddingToLength:12 * 1024 withString:@"x" startingAtIndex:0];
  NSMutableArray *entries = NSMutableArray.array;
  for(NSUInteger index = 0; index < 120; index++) {
    [entries addObject:@{@"record": [NSString stringWithFormat:@"record-%lu", (unsigned long)index], @"title": [title stringByAppendingFormat:@"%lu", (unsigned long)index],
                         @"user": @"public-test", @"host": @"localhost", @"port": @"", @"database": @"Test database", @"available": @YES}];
  }
  return entries;
}
@end

// The server's listing and search over a given catalog.
API_AVAILABLE(macos(13.0))
@interface MPAutoFillManyServerStub : MPAutoFillServerStub
@property NSArray *entries;
@end
@implementation MPAutoFillManyServerStub
- (NSArray *)catalogEntries { return self.entries; }
@end

// The extension's view controller; its source is also compiled into this target.
API_AVAILABLE(macos(13.0))
@interface MPCredentialProviderViewController : ASCredentialProviderViewController
@property BOOL appeared;
@property MPAutoFillPickerView *pickerView;
@property (readonly) MPAutoFillRequestState *requestState;
- (void)fill:(id)sender;
- (void)handoff:(id)sender;
- (void)cancel:(id)sender;
- (void)toggleAllEntries:(id)sender;
- (void)refreshVisibleCatalog;
- (void)pickerViewQueryDidChange:(MPAutoFillPickerView *)view;
- (void)openSubscriptionForRequest:(NSString *)request completion:(void (^)(MPAutoFillStream *))completion;
@end

// Confirms another site's fill at once instead of showing the sheet.
API_AVAILABLE(macos(13.0))
@interface MPAutoFillConfirmingPicker : MPAutoFillPickerView
@property NSDictionary *confirmedEntry;
@end
@implementation MPAutoFillConfirmingPicker
- (void)confirmFillOfEntry:(NSDictionary *)entry forServices:(NSArray *)services completion:(void (^)(BOOL))completion {
  self.confirmedEntry = entry;
  completion(YES);
}
@end

@interface MPAutoFillLoopbackContext : NSObject
@property ASPasswordCredential *credential;
@property NSError *error;
@end
@implementation MPAutoFillLoopbackContext
- (void)completeRequestWithSelectedCredential:(ASPasswordCredential *)credential completionHandler:(void (^)(BOOL))handler { self.credential = credential; }
- (void)cancelRequestWithError:(NSError *)error { self.error = error; }
@end

// Owner authentication the user confirms at once, in the system dialog.
@interface MPAutoFillConfirmingContext : LAContext
@end
@implementation MPAutoFillConfirmingContext
- (BOOL)canEvaluatePolicy:(LAPolicy)policy error:(NSError **)error { return NO; }
- (void)evaluatePolicy:(LAPolicy)policy localizedReason:(NSString *)reason reply:(void (^)(BOOL, NSError *))reply { reply(YES, nil); }
@end

static MPAutoFillServer *MPLoopbackServer API_AVAILABLE(macos(13.0));
static NSData *MPLoopbackOwner;

// The real extension and a real coordinator. Only the listener and the peer
// check, which need two signed processes, are bypassed: each message is framed
// over a socket pair and answered by the server's worker path.
API_AVAILABLE(macos(13.0))
@interface MPAutoFillLoopbackController : MPCredentialProviderViewController
@property MPAutoFillLoopbackContext *context;
@property NSMutableArray<NSDictionary *> *messages;
@property NSMutableArray<NSDictionary *> *replies;
@property NSURL *openedURL;
@property BOOL deferNextCatalog;
@property NSDictionary *heldCatalog;
@property (copy) void (^heldCatalogCompletion)(NSDictionary *);
@end
@implementation MPAutoFillLoopbackController
- (ASCredentialProviderExtensionContext *)extensionContext { return (id)self.context; }
- (LAContext *)newAuthenticationContext { return [[MPAutoFillConfirmingContext alloc] init]; }
- (void)yieldToHost {}
- (void)openHostURL:(NSURL *)url { self.openedURL = url; }
+ (void)cancelGrantForRequest:(NSString *)request {
  [MPLoopbackServer replyToMessage:@{@"version": @1, @"request": request, @"operation": @"cancel"} owner:MPLoopbackOwner];
}
- (void)openSubscriptionForRequest:(NSString *)request completion:(void (^)(MPAutoFillStream *))completion {
  int sockets[2];
  if(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) { completion(nil); return; }
  MPAutoFillConfigureSocket(sockets[1]);
  if(![MPLoopbackServer subscribeRequest:request socket:sockets[0]]) {
    close(sockets[0]); close(sockets[1]); completion(nil); return;
  }
  int client = sockets[1];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSDictionary *ack = MPAutoFillReadMessage(client, NULL);
    MPAutoFillStream *stream = nil;
    if([ack[@"status"] isEqual:@"subscribed"] && [ack[@"request"] isEqual:request]) stream = [[MPAutoFillStream alloc] initWithSocket:client];
    else close(client);
    dispatch_async(dispatch_get_main_queue(), ^{ completion(stream); });
  });
}
- (void)exchangeMessage:(NSDictionary *)message completion:(void (^)(NSDictionary *))completion {
  [self.messages addObject:message];
  BOOL hold = self.deferNextCatalog && [message[@"operation"] isEqual:@"catalog"];
  if(hold) self.deferNextCatalog = NO;
  MPAutoFillServer *server = MPLoopbackServer;
  NSData *owner = MPLoopbackOwner;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSDictionary *reply = nil;
    int sockets[2];
    if(MPAutoFillValidateRequest(message) && socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0) {
      MPAutoFillConfigureSocket(sockets[0]); MPAutoFillConfigureSocket(sockets[1]);
      // The extension reads while the host writes, as over the real socket: a
      // catalog can exceed the socket buffer.
      __block NSDictionary *received = nil;
      dispatch_group_t reading = dispatch_group_create();
      int client = sockets[1];
      dispatch_group_async(reading, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ received = MPAutoFillReadMessage(client, NULL); });
      [server answerMessage:message owner:owner socket:sockets[0] error:NULL];
      shutdown(sockets[0], SHUT_WR); // No reply ends the read at once.
      dispatch_group_wait(reading, DISPATCH_TIME_FOREVER);
      reply = received;
      close(sockets[0]); close(sockets[1]);
      if(![reply[@"request"] isEqual:message[@"request"]]) reply = nil;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      if(reply) [self.replies addObject:reply];
      if(hold) { self.heldCatalog = reply; self.heldCatalogCompletion = completion; }
      else completion(reply);
    });
  });
}
@end

API_AVAILABLE(macos(13.0))
@interface MPTestAutoFillCoordinator : XCTestCase
@property NSUserDefaults *defaults;
@property NSData *owner;
@end
@implementation MPTestAutoFillCoordinator

- (void)setUp {
  // A private suite: tests never change the app's real AutoFill state.
  self.defaults = [[NSUserDefaults alloc] initWithSuiteName:MPTestAutoFillSuite];
  [self.defaults removePersistentDomainForName:MPTestAutoFillSuite];
  [self.defaults setBool:YES forKey:MPAutoFillEnabledPreference];
  self.owner = [@"owner" dataUsingEncoding:NSUTF8StringEncoding];
}

- (void)tearDown {
  MPLoopbackServer = nil;
  [self.defaults removePersistentDomainForName:MPTestAutoFillSuite];
}

- (MPAutoFillTestDocument *)document {
  return [[MPAutoFillTestDocument alloc] initWithType:@"" error:nil];
}
- (KPKEntry *)entryIn:(MPDocument *)document {
  return [self entryIn:document group:document.root];
}
- (KPKEntry *)entryIn:(MPDocument *)document group:(KPKGroup *)group {
  KPKEntry *entry = [document.tree createEntry:group];
  entry.title = @"Public test"; entry.username = @"user"; entry.password = @"public-secret"; entry.url = @"https://Example.COM/login";
  [entry addToGroup:group];
  return entry;
}

- (id)configure:(MPAutoFillTestCoordinator *)coordinator documents:(NSArray *)documents {
  coordinator.documents = documents;
  coordinator.store = [[MPAutoFillIdentityStoreSpy alloc] init];
  coordinator.store.enabled = YES;
  coordinator.testListening = YES;
  coordinator.canStart = YES;
  return coordinator;
}
- (MPAutoFillCatalogCoordinator *)coordinator:(NSArray *)documents {
  return [self configure:[[MPAutoFillCatalogCoordinator alloc] initWithDefaults:self.defaults] documents:documents];
}
- (MPAutoFillTestCoordinator *)publisher:(NSArray *)documents {
  return [self configure:[[MPAutoFillTestCoordinator alloc] initWithDefaults:self.defaults] documents:documents];
}

// The catalog as a request sees it: the server prepares before any hook.
- (NSArray<NSDictionary *> *)entries:(MPAutoFillCoordinator *)coordinator {
  [coordinator prepareForRequest];
  return coordinator.catalogEntries;
}

// What the extension sends after the picker displayed the record.
- (NSDictionary *)credential:(MPAutoFillCoordinator *)coordinator record:(NSString *)record {
  for(NSDictionary *item in [self entries:coordinator]) {
    if([item[@"record"] isEqual:record]) return [coordinator credentialForRecord:record expecting:item];
  }
  return [coordinator credentialForRecord:record expecting:@{}];
}

- (NSDictionary *)catalog:(MPAutoFillServer *)server request:(NSString *)request {
  return [server replyToMessage:@{@"request": request, @"operation": @"catalog", @"scope": @"all"} owner:self.owner];
}

- (NSDictionary *)fetch:(NSString *)record request:(NSString *)request from:(MPAutoFillServer *)server {
  return [server replyToMessage:@{@"request": request, @"operation": @"credential", @"record": record} owner:self.owner];
}

- (void)drainMainQueue {
  XCTestExpectation *done = [self expectationWithDescription:@"Main queue drained"];
  dispatch_async(dispatch_get_main_queue(), ^{ [done fulfill]; });
  [self waitForExpectationsWithTimeout:1 handler:nil];
}

#pragma mark Domain

- (void)testExactHostsIDNAndIP {
  XCTAssertEqualObjects(MPAutoFillNormalizedHost(@"HTTPS://EXAMPLE.COM.:443/login"), @"example.com");
  XCTAssertNotEqualObjects(MPAutoFillNormalizedHost(@"evil-example.com"), MPAutoFillNormalizedHost(@"example.com"));
  XCTAssertNotEqualObjects(MPAutoFillNormalizedHost(@"example.com.evil.test"), MPAutoFillNormalizedHost(@"example.com"));
  XCTAssertEqualObjects(MPAutoFillNormalizedHost(@"https://bücher.de/path"), @"xn--bcher-kva.de");
  XCTAssertEqualObjects(MPAutoFillNormalizedHost(@"http://127.0.0.1:8765"), @"127.0.0.1");
  XCTAssertEqualObjects(MPAutoFillNormalizedHost(@"https://[2001:0db8:0:0:0:0:0:1]/"), @"2001:db8::1");
  XCTAssertEqualObjects(MPAutoFillNormalizedHost(@"2001:db8::1"), @"2001:db8::1");
  for(NSString *invalid in @[@"javascript:alert(1)", @"https://user:pass@example.com", @"example.com evil.test", @"127.1", @"a..example.com",
    @"https://", @"https:///login", @"http://?q=x", @"https://:443", @"https://example.com:0", @"https://example.com:65536",
    @"ftp://example.com", @"file://example.com/login", @"blob:https://example.com/id", @"wss://example.com"]) {
    XCTAssertNil(MPAutoFillNormalizedService(invalid), @"%@", invalid);
    XCTAssertEqualObjects(MPAutoFillNormalizedHost(invalid), @"", @"%@", invalid);
  }
  // The scheme is not part of a site: an http page gets the host's accounts.
  XCTAssertEqualObjects(MPAutoFillNormalizedService(@"http://example.com/login"), MPAutoFillNormalizedService(@"https://example.com"));
}

// The server sends a password frame's start on the main queue and the rest later.
- (void)testFrameWrittenInParts {
  int sockets[2];
  XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
  MPAutoFillConfigureSocket(sockets[0]); MPAutoFillConfigureSocket(sockets[1]);
  NSDictionary *message = @{@"version": @1, @"request": NSUUID.UUID.UUIDString, @"status": @"ready", @"password": @"public-password"};
  NSData *frame = MPAutoFillEncodeMessage(message, NULL);
  XCTAssertNotNil(frame);
  XCTAssertEqual(send(sockets[0], frame.bytes, 3, MSG_DONTWAIT), 3);
  XCTAssertTrue(MPAutoFillWriteFrame(sockets[0], frame, 3, NULL));
  XCTAssertEqualObjects(MPAutoFillReadMessage(sockets[1], NULL), message);
  XCTAssertFalse(MPAutoFillWriteFrame(sockets[0], frame, frame.length + 1, NULL));
  close(sockets[0]); close(sockets[1]);
}

- (void)testBlockingReadAndWriteRejectInvalidFrames {
  int sockets[2];
  XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
  close(sockets[0]);
  NSError *error = nil;
  XCTAssertNil(MPAutoFillReadMessage(sockets[1], &error));
  XCTAssertEqual(error.code, MPAutoFillErrorClosed, @"An empty connection is a silent close");
  close(sockets[1]);

  uint32_t tooLarge = htonl(1024 * 1024 + 1), malformedLength = htonl(3), partialLength = htonl(8);
  NSMutableData *malformed = [NSMutableData dataWithBytes:&malformedLength length:4];
  [malformed appendBytes:"\xff\xfe\xfd" length:3];
  for(NSData *bytes in @[[NSData dataWithBytes:&tooLarge length:4], malformed]) {
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
    MPAutoFillConfigureSocket(sockets[0]); MPAutoFillConfigureSocket(sockets[1]);
    XCTAssertEqual(send(sockets[0], bytes.bytes, bytes.length, 0), (ssize_t)bytes.length);
    XCTAssertNil(MPAutoFillReadMessage(sockets[1], NULL));
    close(sockets[0]); close(sockets[1]);
  }

  XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
  MPAutoFillConfigureSocket(sockets[1]);
  XCTAssertEqual(send(sockets[0], &partialLength, 4, 0), 4);
  close(sockets[0]);
  error = nil;
  XCTAssertNil(MPAutoFillReadMessage(sockets[1], &error));
  XCTAssertEqual(error.code, MPAutoFillErrorTransport, @"A cut-off frame is a transport error");
  close(sockets[1]);

  XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
  MPAutoFillConfigureSocket(sockets[0]);
  NSString *large = [@"" stringByPaddingToLength:1024 * 1024 + 1 withString:@"x" startingAtIndex:0];
  XCTAssertFalse(MPAutoFillWriteMessage(sockets[0], @{@"value": large}, NULL));
  close(sockets[0]); close(sockets[1]);
}

#pragma mark Subscription transport

- (void)testStreamReadsFragmentedAndCoalescedFramesInOrderAndClosesOnce {
  int sockets[2]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
  MPAutoFillStream *stream = [[MPAutoFillStream alloc] initWithSocket:sockets[0]];
  XCTestExpectation *messages = [self expectationWithDescription:@"Ordered frames"];
  messages.expectedFulfillmentCount = 2;
  XCTestExpectation *closed = [self expectationWithDescription:@"EOF"];
  NSMutableArray *received = NSMutableArray.array;
  [stream startWithMessageHandler:^(NSDictionary *message) { [received addObject:message[@"event"]]; [messages fulfill]; }
                    closeHandler:^{ [closed fulfill]; }];
  NSData *first = MPAutoFillEncodeMessage(@{@"event": @"invalidate"}, NULL);
  NSData *second = MPAutoFillEncodeMessage(@{@"event": @"catalogChanged"}, NULL);
  XCTAssertEqual(send(sockets[1], first.bytes, 2, 0), 2);
  NSMutableData *rest = [[first subdataWithRange:NSMakeRange(2, first.length - 2)] mutableCopy];
  [rest appendData:second];
  XCTAssertEqual(send(sockets[1], rest.bytes, rest.length, 0), (ssize_t)rest.length);
  shutdown(sockets[1], SHUT_WR);
  [self waitForExpectationsWithTimeout:2 handler:nil];
  XCTAssertEqualObjects(received, (@[@"invalidate", @"catalogChanged"]));
  [stream close]; [stream close]; close(sockets[1]);
}

- (void)testStreamRejectsOversizedMalformedAndCutOffFrames {
  uint32_t tooLarge = htonl(1024 * 1024 + 1), malformedLength = htonl(1), partialLength = htonl(10);
  NSMutableData *malformed = [NSMutableData dataWithBytes:&malformedLength length:4];
  [malformed appendBytes:"x" length:1];
  for(NSData *bytes in @[[NSData dataWithBytes:&tooLarge length:4], malformed, [NSData dataWithBytes:&partialLength length:4]]) {
    int sockets[2]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
    MPAutoFillStream *stream = [[MPAutoFillStream alloc] initWithSocket:sockets[0]];
    XCTestExpectation *closed = [self expectationWithDescription:@"Reject frame"];
    [stream startWithMessageHandler:^(NSDictionary *message) { XCTFail(@"Invalid frame was delivered"); } closeHandler:^{ [closed fulfill]; }];
    XCTAssertEqual(send(sockets[1], bytes.bytes, bytes.length, 0), (ssize_t)bytes.length);
    shutdown(sockets[1], SHUT_WR);
    [self waitForExpectationsWithTimeout:2 handler:nil];
    close(sockets[1]);
  }
}

- (void)testStreamIdleHasNoTransferTimeoutAndWriteStallDoes {
  int sockets[2]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
  MPAutoFillStream *stream = [[MPAutoFillStream alloc] initWithSocket:sockets[0]];
  __block BOOL didClose = NO;
  XCTestExpectation *idle = [self expectationWithDescription:@"Idle channel survives 5s"];
  [stream startWithMessageHandler:^(NSDictionary *message) {} closeHandler:^{ didClose = YES; }];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [idle fulfill]; });
  [self waitForExpectationsWithTimeout:8 handler:nil];
  XCTAssertFalse(didClose);
  [stream close]; close(sockets[1]);
  // A peer that never reads cannot hold resources indefinitely.
  XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
  int smallBuffer = 4096; setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &smallBuffer, sizeof(smallBuffer));
  MPAutoFillStream *stalled = [[MPAutoFillStream alloc] initWithSocket:sockets[0]];
  XCTestExpectation *closed = [self expectationWithDescription:@"Write deadline"];
  [stalled startWithMessageHandler:^(NSDictionary *message) {} closeHandler:^{ [closed fulfill]; }];
  [stalled sendMessage:@{@"data": [NSMutableData dataWithLength:900 * 1024]}];
  [self waitForExpectationsWithTimeout:7 handler:nil];
  close(sockets[1]);
}

- (void)testStreamBoundsPendingOutput {
  int sockets[2]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
  int smallBuffer = 4096; setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &smallBuffer, sizeof(smallBuffer));
  MPAutoFillStream *stream = [[MPAutoFillStream alloc] initWithSocket:sockets[0]];
  XCTestExpectation *closed = [self expectationWithDescription:@"Output bounded"];
  [stream startWithMessageHandler:^(NSDictionary *message) {} closeHandler:^{ [closed fulfill]; }];
  NSDictionary *message = @{@"data": [NSMutableData dataWithLength:600 * 1024]};
  [stream sendMessage:message]; [stream sendMessage:message];
  [self waitForExpectationsWithTimeout:2 handler:nil];
  close(sockets[1]);
}

- (void)testStreamBoundsPendingMainQueueMessages {
  int sockets[2]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
  MPAutoFillStream *stream = [[MPAutoFillStream alloc] initWithSocket:sockets[0]];
  XCTestExpectation *closed = [self expectationWithDescription:@"Bound event delivery"];
  __block NSUInteger received = 0;
  [stream startWithMessageHandler:^(NSDictionary *message) { received++; } closeHandler:^{ [closed fulfill]; }];
  NSData *frame = MPAutoFillEncodeMessage(@{@"event": @"invalidate"}, NULL);
  NSMutableData *burst = NSMutableData.data;
  for(NSUInteger index = 0; index < 40; index++) [burst appendData:frame];
  XCTAssertLessThan(burst.length, 4096U); // One read dispatch, no delivery acknowledgements yet.
  XCTAssertEqual(send(sockets[1], burst.bytes, burst.length, 0), (ssize_t)burst.length);
  [self waitForExpectationsWithTimeout:2 handler:nil];
  XCTAssertEqual(received, 32U);
  close(sockets[1]);
}

// Drains the peer until EOF; NO if its descriptor stays open past the timeout.
- (BOOL)peerSeesClose:(int)fd {
  MPAutoFillConfigureSocket(fd);
  uint8_t buffer[16384];
  for(;;) {
    ssize_t count = recv(fd, buffer, sizeof(buffer), 0);
    if(count == 0) return YES;
    if(count < 0 && errno != EINTR) return NO;
  }
}

// The descriptor closes after all of its sources, including a writer with
// pending output, and also for a stream that never started.
- (void)testStreamClosesDescriptorAfterItsSources {
  int sockets[2]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
  int smallBuffer = 4096; setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &smallBuffer, sizeof(smallBuffer));
  MPAutoFillStream *stream = [[MPAutoFillStream alloc] initWithSocket:sockets[0]];
  [stream startWithMessageHandler:^(NSDictionary *message) {} closeHandler:^{}];
  [stream sendMessage:@{@"data": [NSMutableData dataWithLength:64 * 1024]}]; // Leaves a writer source.
  [stream close];
  XCTAssertTrue([self peerSeesClose:sockets[1]]);
  close(sockets[1]);
  XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
  [[[MPAutoFillStream alloc] initWithSocket:sockets[0]] close];
  XCTAssertTrue([self peerSeesClose:sockets[1]]);
  close(sockets[1]);
}

- (void)testSubscribersAreBoundedGrantFreeAndRemovedOnEOF {
  MPAutoFillCatalogCoordinator *server = [self coordinator:@[]];
  NSMutableArray *clients = NSMutableArray.array;
  for(NSUInteger index = 0; index < 9; index++) {
    int sockets[2]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
    NSString *request = NSUUID.UUID.UUIDString;
    BOOL accepted = [server subscribeRequest:request socket:sockets[0]];
    if(index < 8) {
      XCTAssertTrue(accepted);
      MPAutoFillConfigureSocket(sockets[1]);
      NSDictionary *ack = MPAutoFillReadMessage(sockets[1], NULL); // Writer runs independently of main.
      XCTAssertEqualObjects(ack[@"status"], @"subscribed");
      XCTAssertEqualObjects(ack[@"request"], request);
      XCTAssertFalse([server subscribeRequest:request socket:-1]);
      [clients addObject:@(sockets[1])];
    }
    else { XCTAssertFalse(accepted); close(sockets[0]); close(sockets[1]); }
  }
  XCTAssertEqual(server.subscribers.count, 8U);
  XCTAssertEqual(server.grants.count, 0U);
  for(NSNumber *fd in clients) close(fd.intValue);
  [self waitUntil:^BOOL{ return server.subscribers.count == 0; }];
}

- (void)testRepeatedRequestFinishClosesRealStreamExactlyOnce {
  MPAutoFillRequestState *state = [[MPAutoFillRequestState alloc] init];
  for(NSUInteger iteration = 0; iteration < 10; iteration++) {
    [state beginForIdentity:nil];
    int sockets[2]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
    MPAutoFillConfigureSocket(sockets[1]);
    state.subscription = [[MPAutoFillStream alloc] initWithSocket:sockets[0]];
    XCTestExpectation *closed = [self expectationWithDescription:@"One teardown"];
    [state.subscription startWithMessageHandler:^(NSDictionary *message) {} closeHandler:^{ [closed fulfill]; }];
    XCTAssertTrue([state finish]); XCTAssertFalse([state finish]);
    [state discard];
    [self waitForExpectationsWithTimeout:2 handler:nil];
    NSError *error = nil;
    XCTAssertNil(MPAutoFillReadMessage(sockets[1], &error));
    XCTAssertEqual(error.code, MPAutoFillErrorClosed);
    close(sockets[1]);
    XCTAssertNil(state.subscription);
  }
}

- (void)testSubscriptionRequestRejectsCatalogAndCredentialInputs {
  NSString *request = NSUUID.UUID.UUIDString;
  NSDictionary *subscribe = @{@"version": @1, @"request": request, @"operation": @"subscribe"};
  XCTAssertTrue(MPAutoFillValidateRequest(subscribe));
  for(NSString *key in @[@"record", @"scope", @"services"]) {
    NSMutableDictionary *invalid = subscribe.mutableCopy; invalid[key] = @"all";
    XCTAssertFalse(MPAutoFillValidateRequest(invalid));
  }
}

- (void)testUnsignedTestProcessCannotAuthenticateAsTheExtension {
  int sockets[2]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
  NSError *error = nil;
  XCTAssertFalse(MPAutoFillValidatePeer(sockets[0], [MPAutoFillAppIdentifier() stringByAppendingString:@".AutoFill"], YES, NULL, &error));
  XCTAssertEqual(error.code, MPAutoFillErrorPeerRejected);
  close(sockets[0]); close(sockets[1]);
}

- (void)testDocumentFlagsNotifyOnlyOnChange {
  MPDocument *document = [[MPDocument alloc] initWithType:@"" error:nil];
  __block NSUInteger notifications = 0;
  id observer = [NSNotificationCenter.defaultCenter addObserverForName:MPAutoFillDocumentsChangedNotification object:document queue:nil usingBlock:^(NSNotification *notification) { notifications++; }];
  document.lockedForFileChange = YES; document.lockedForFileChange = YES;
  XCTAssertEqual(notifications, 1);
  XCTAssertTrue(document.autoFillUnavailable);
  document.lockedForFileChange = NO;
  document.autoFillMergePending = YES; document.autoFillMergePending = YES;
  XCTAssertEqual(notifications, 3);
  XCTAssertTrue(document.autoFillUnavailable);
  document.autoFillMergePending = NO;
  XCTAssertFalse(document.autoFillUnavailable);
  [NSNotificationCenter.defaultCenter removeObserver:observer];
}

- (void)testPortsAndWwwMatching {
  XCTAssertEqualObjects(MPAutoFillNormalizedService(@"https://example.com:443/")[@"port"], @"");
  XCTAssertEqualObjects(MPAutoFillNormalizedService(@"http://example.com:80")[@"port"], @"");
  XCTAssertEqualObjects(MPAutoFillNormalizedService(@"localhost:3000")[@"port"], @"3000");
  XCTAssertEqualObjects(MPAutoFillNormalizedService(@"https://example.com:8443/login"), (@{@"host": @"example.com", @"port": @"8443"}));
  XCTAssertTrue(MPAutoFillServiceMatches(@"example.com", @"", @"www.example.com", @""));
  XCTAssertTrue(MPAutoFillServiceMatches(@"www.example.com", @"", @"example.com", @"8443"));
  XCTAssertFalse(MPAutoFillServiceMatches(@"example.com", @"", @"login.example.com", @""));
  XCTAssertFalse(MPAutoFillServiceMatches(@"example.com", @"", @"example.com.evil.test", @""));
  XCTAssertTrue(MPAutoFillServiceMatches(@"localhost", @"3000", @"localhost", @"3000"));
  XCTAssertTrue(MPAutoFillServiceMatches(@"localhost", @"3000", @"localhost", @"8080"));
  XCTAssertTrue(MPAutoFillServiceMatches(@"localhost", @"3000", @"localhost", @""));
  XCTAssertFalse(MPAutoFillServiceMatches(@"", @"", @"", @""));
}

- (void)testCatalogRequestRejectsInvalidServicePorts {
  for(NSString *port in @[@"0", @"65536", @"99999", @"80a"]) {
    XCTAssertFalse(MPAutoFillValidateRequest(@{@"version": @1, @"request": NSUUID.UUID.UUIDString, @"operation": @"catalog",
      @"services": @[@{@"host": @"example.com", @"port": port}]}));
  }
  XCTAssertTrue(MPAutoFillValidateRequest(@{@"version": @1, @"request": NSUUID.UUID.UUIDString, @"operation": @"catalog",
    @"services": @[@{@"host": @"example.com", @"port": @"65535"}]}));
}

- (void)testRequestEnvelopeAndOperationFields {
  BOOL (^valid)(NSDictionary *) = ^BOOL(NSDictionary *fields) {
    NSMutableDictionary *message = [@{@"version": @1, @"request": NSUUID.UUID.UUIDString} mutableCopy];
    [message addEntriesFromDictionary:fields];
    return MPAutoFillValidateRequest(message);
  };
  NSArray *site = @[@{@"host": @"example.com", @"port": @""}];
  XCTAssertTrue(valid(@{@"operation": @"catalog"}));
  XCTAssertFalse(MPAutoFillValidateRequest(@{@"version": @2, @"request": NSUUID.UUID.UUIDString, @"operation": @"catalog"}));
  XCTAssertFalse(MPAutoFillValidateRequest(@{@"version": @1, @"request": @"bad", @"operation": @"catalog"}));
  XCTAssertFalse(MPAutoFillValidateRequest(@{@"version": @1, @"request": @42, @"operation": @"catalog"}));
  // Activation goes through the URL scheme, never through the credential channel.
  for(NSString *operation in @[@"activate", @"status", @"export-all"]) XCTAssertFalse(valid(@{@"operation": operation}), @"%@", operation);
  XCTAssertTrue(valid(@{@"operation": @"credential", @"record": @"test-record"}));
  XCTAssertFalse(valid(@{@"operation": @"credential"}));
  XCTAssertFalse(valid(@{@"operation": @"credential", @"record": @42}));
  XCTAssertTrue(valid(@{@"operation": @"unlock"}));
  XCTAssertFalse(valid(@{@"operation": @"unlock", @"record": @"test-record"}));
  XCTAssertFalse(valid(@{@"operation": @"cancel", @"scope": @"all"}));
  XCTAssertTrue(valid(@{@"operation": @"catalog", @"services": site}));
  XCTAssertTrue(valid(@{@"operation": @"catalog", @"scope": @"all"}));
  XCTAssertTrue(valid(@{@"operation": @"catalog", @"record": @"test-record"}));
  XCTAssertTrue(valid(@{@"operation": @"catalog", @"scope": @"all", @"services": site}));
  XCTAssertFalse(valid(@{@"operation": @"catalog", @"scope": @"all", @"record": @"test-record"}));
  XCTAssertFalse(valid(@{@"operation": @"catalog", @"scope": @"everything"}));
  XCTAssertFalse(valid(@{@"operation": @"catalog", @"services": @"example.com"}));
}

#pragma mark Server grants

- (void)testGrantIsBoundToOwnerAndUsedOnce {
  MPAutoFillServerStub *server = [[MPAutoFillServerStub alloc] init];
  NSString *request = NSUUID.UUID.UUIDString;
  NSData *other = [@"other-owner" dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertEqualObjects([self catalog:server request:request][@"status"], @"ready");
  NSDictionary *fetch = @{@"request": request, @"operation": @"credential", @"record": @"test-record"};
  XCTAssertNil([server replyToMessage:fetch owner:other][@"password"]);
  // Another process can neither replace nor consume the grant.
  NSDictionary *takeover = @{@"request": request, @"operation": @"catalog", @"scope": @"all"};
  XCTAssertEqualObjects([server replyToMessage:takeover owner:other][@"status"], @"unavailable");
  XCTAssertEqualObjects([server replyToMessage:fetch owner:self.owner][@"password"], @"public-password");
  XCTAssertEqualObjects([server replyToMessage:fetch owner:self.owner][@"status"], @"unavailable");
}

- (void)testCancellationConsumesTheGrant {
  MPAutoFillServerStub *server = [[MPAutoFillServerStub alloc] init];
  NSString *request = NSUUID.UUID.UUIDString;
  [self catalog:server request:request];
  NSDictionary *cancel = @{@"request": request, @"operation": @"cancel"};
  XCTAssertEqualObjects([server replyToMessage:cancel owner:self.owner][@"status"], @"cancelled");
  XCTAssertEqualObjects([self fetch:@"test-record" request:request from:server][@"status"], @"unavailable");
}

- (void)testExpiredGrantDoesNotIssueCredential {
  MPAutoFillServerStub *server = [[MPAutoFillServerStub alloc] init];
  NSString *request = NSUUID.UUID.UUIDString;
  [self catalog:server request:request];
  NSMutableDictionary *grant = [server.grants[request] mutableCopy];
  grant[@"deadline"] = @0; server.grants[request] = grant;
  XCTAssertEqualObjects([self fetch:@"test-record" request:request from:server][@"status"], @"unavailable");
}

- (void)testGrantsAreBoundedUntilOneIsUsed {
  MPAutoFillServerStub *server = [[MPAutoFillServerStub alloc] init];
  NSMutableArray *requests = NSMutableArray.array;
  for(NSUInteger index = 0; index < 32; index++) {
    [requests addObject:NSUUID.UUID.UUIDString];
    XCTAssertEqualObjects([self catalog:server request:requests.lastObject][@"status"], @"ready");
  }
  NSDictionary *refused = [self catalog:server request:NSUUID.UUID.UUIDString];
  XCTAssertEqualObjects(refused[@"status"], @"unavailable");
  XCTAssertNil(refused[@"entries"]);
  XCTAssertEqual(server.grants.count, 32U);
  // A request renews its own grant, and a used grant frees its slot.
  XCTAssertEqualObjects([self catalog:server request:requests.firstObject][@"status"], @"ready");
  XCTAssertNotNil([self fetch:@"test-record" request:requests.firstObject from:server][@"password"]);
  XCTAssertEqualObjects([self catalog:server request:NSUUID.UUID.UUIDString][@"status"], @"ready");
}

- (void)testOnlyReadyAndLockedCatalogsIssueGrants {
  MPAutoFillServerStub *server = [[MPAutoFillServerStub alloc] init];
  for(NSString *status in @[@"disabled", @"noDocuments", @"conflict"]) {
    server.status = status;
    XCTAssertEqualObjects([self catalog:server request:NSUUID.UUID.UUIDString][@"status"], status);
  }
  XCTAssertEqual(server.grants.count, 0U);
  server.status = @"locked";
  NSDictionary *locked = [self catalog:server request:NSUUID.UUID.UUIDString];
  XCTAssertEqual([locked[@"entries"] count], 0U); // Only a grant for the unlock handoff.
  XCTAssertEqual(server.grants.count, 1U);
}

- (void)testServerCatalogIsScopedToTheRequestedSite {
  MPAutoFillServerStub *server = [[MPAutoFillServerStub alloc] init];
  NSDictionary *unscoped = [server replyToMessage:@{@"request": NSUUID.UUID.UUIDString, @"operation": @"catalog"} owner:self.owner];
  XCTAssertEqual([unscoped[@"entries"] count], 0U);
  NSDictionary *other = [server replyToMessage:@{@"request": NSUUID.UUID.UUIDString, @"operation": @"catalog",
    @"services": @[@{@"host": @"example.com", @"port": @""}]} owner:self.owner];
  XCTAssertEqual([other[@"entries"] count], 0U);
  NSDictionary *scoped = [server replyToMessage:@{@"request": NSUUID.UUID.UUIDString, @"operation": @"catalog",
    @"services": @[@{@"host": @"localhost", @"port": @"8765"}]} owner:self.owner];
  XCTAssertEqual([scoped[@"entries"] count], 1U);
}

#pragma mark Listing and search

// 250 accounts "Account 000"… on siteNNN.example in listing order, the first
// 100 of them owned by first-user, then three localhost accounts.
- (NSArray<NSDictionary *> *)manyEntries {
  NSMutableArray *entries = NSMutableArray.array;
  for(NSUInteger index = 0; index < 250; index++) {
    [entries addObject:@{@"record": [NSString stringWithFormat:@"record-%03lu", (unsigned long)index],
      @"title": [NSString stringWithFormat:@"Account %03lu", (unsigned long)index], @"user": index < 100 ? @"first-user" : @"second-user",
      @"host": [NSString stringWithFormat:@"site%03lu.example", (unsigned long)index], @"port": @"", @"database": @"Test database", @"available": @YES}];
  }
  for(NSString *title in @[@"Local A", @"Local B", @"Café Ünïcode"]) {
    [entries addObject:@{@"record": title, @"title": title, @"user": @"local-user", @"host": @"localhost", @"port": @"8765",
      @"database": @"Test database", @"available": @YES}];
  }
  return entries;
}

- (MPAutoFillManyServerStub *)manyServer {
  MPAutoFillManyServerStub *server = [[MPAutoFillManyServerStub alloc] init];
  server.entries = self.manyEntries;
  return server;
}

// A list catalog as the extension sends it: "Show all" unless services are given.
- (NSDictionary *)catalog:(MPAutoFillServer *)server request:(NSString *)request query:(NSString *)query services:(NSArray *)services {
  NSMutableDictionary *message = [@{@"version": @1, @"request": request, @"operation": @"catalog"} mutableCopy];
  if(services) message[@"services"] = services;
  else message[@"scope"] = @"all";
  if(query) message[@"query"] = query;
  XCTAssertTrue(MPAutoFillValidateRequest(message), @"%@", message);
  return [server replyToMessage:message owner:self.owner];
}

- (void)testCatalogListsAtMostOneHundredAccountsAndBindsOnlyThose {
  MPAutoFillManyServerStub *server = self.manyServer;
  NSString *request = NSUUID.UUID.UUIDString;
  NSDictionary *all = [self catalog:server request:request query:nil services:nil];
  XCTAssertEqualObjects(all[@"status"], @"ready");
  XCTAssertEqualObjects(all[@"entries"], [server.entries subarrayWithRange:NSMakeRange(0, 100)]);
  XCTAssertEqualObjects(all[@"more"], @YES);
  XCTAssertEqualObjects([NSSet setWithArray:[server.grants[request][@"bindings"] allKeys]], [NSSet setWithArray:[all[@"entries"] valueForKey:@"record"]]);
  // An account the reply held back cannot be filled with that grant.
  NSDictionary *heldBack = [self fetch:@"record-150" request:request from:server];
  XCTAssertEqualObjects(heldBack[@"status"], @"unavailable");
  XCTAssertNil(heldBack[@"password"]);
  // The search lists it, and then it can be filled.
  request = NSUUID.UUID.UUIDString;
  NSDictionary *found = [self catalog:server request:request query:@"account 15" services:nil];
  NSMutableArray *expected = NSMutableArray.array;
  for(NSUInteger index = 150; index < 160; index++) [expected addObject:[NSString stringWithFormat:@"record-%lu", (unsigned long)index]];
  XCTAssertEqualObjects([found[@"entries"] valueForKey:@"record"], expected);
  XCTAssertNil(found[@"more"]);
  XCTAssertEqual([server.grants[request][@"bindings"] count], 10U);
  XCTAssertEqualObjects([self fetch:@"record-150" request:request from:server][@"password"], @"public-password");
}

- (void)testMoreReportsOnlyMatchesBeyondTheLimit {
  MPAutoFillManyServerStub *server = self.manyServer;
  NSDictionary *exact = [self catalog:server request:NSUUID.UUID.UUIDString query:@"first-user" services:nil];
  XCTAssertEqual([exact[@"entries"] count], 100U);
  XCTAssertNil(exact[@"more"]);
  NSDictionary *over = [self catalog:server request:NSUUID.UUID.UUIDString query:@"second-user" services:nil];
  XCTAssertEqual([over[@"entries"] count], 100U);
  XCTAssertEqualObjects([over[@"entries"] firstObject][@"record"], @"record-100");
  XCTAssertEqualObjects([over[@"entries"] lastObject][@"record"], @"record-199");
  XCTAssertEqualObjects(over[@"more"], @YES);
  NSDictionary *none = [self catalog:server request:NSUUID.UUID.UUIDString query:@"no such account" services:nil];
  XCTAssertEqualObjects(none[@"status"], @"ready");
  XCTAssertEqual([none[@"entries"] count], 0U);
  XCTAssertNil(none[@"more"]);
}

- (void)testQueryOnlyNarrowsTheRequestedSite {
  MPAutoFillManyServerStub *server = self.manyServer;
  NSArray *localhost = @[@{@"host": @"localhost", @"port": @""}];
  NSDictionary *site = [self catalog:server request:NSUUID.UUID.UUIDString query:nil services:localhost];
  XCTAssertEqualObjects([site[@"entries"] valueForKey:@"title"], (@[@"Local A", @"Local B", @"Café Ünïcode"]));
  NSDictionary *narrowed = [self catalog:server request:NSUUID.UUID.UUIDString query:@"local b" services:localhost];
  XCTAssertEqualObjects([narrowed[@"entries"] valueForKey:@"title"], @[@"Local B"]);
  // Case and diacritics are ignored, as in the picker.
  NSDictionary *folded = [self catalog:server request:NSUUID.UUID.UUIDString query:@"CAFE UNICODE" services:localhost];
  XCTAssertEqualObjects([folded[@"entries"] valueForKey:@"title"], @[@"Café Ünïcode"]);
  // Another site's account never enters a site's list through the search.
  NSDictionary *other = [self catalog:server request:NSUUID.UUID.UUIDString query:@"Account 001" services:localhost];
  XCTAssertEqual([other[@"entries"] count], 0U);
  NSDictionary *unscoped = [server replyToMessage:@{@"version": @1, @"request": NSUUID.UUID.UUIDString, @"operation": @"catalog", @"query": @"Account"} owner:self.owner];
  XCTAssertEqual([unscoped[@"entries"] count], 0U);
}

- (void)testShowAllListsTheRequestingSiteFirst {
  MPAutoFillManyServerStub *server = [[MPAutoFillManyServerStub alloc] init];
  NSMutableArray *entries = NSMutableArray.array;
  for(NSUInteger index = 0; index < 150; index++) {
    [entries addObject:@{@"record": [NSString stringWithFormat:@"mail-%03lu", (unsigned long)index], @"title": [NSString stringWithFormat:@"Mail %03lu", (unsigned long)index],
      @"user": @"user", @"host": [NSString stringWithFormat:@"mail%03lu.example", (unsigned long)index], @"port": @"", @"database": @"Test database", @"available": @YES}];
  }
  // The site's accounts come last in the catalog.
  [entries addObject:@{@"record": @"Mail here", @"title": @"Mail here", @"user": @"user", @"host": @"example.com", @"port": @"", @"database": @"Test database", @"available": @YES}];
  [entries addObject:@{@"record": @"Other here", @"title": @"Other here", @"user": @"user", @"host": @"www.example.com", @"port": @"8443", @"database": @"Test database", @"available": @YES}];
  server.entries = entries;
  NSArray *site = @[@{@"host": @"example.com", @"port": @""}];
  NSDictionary *(^showAll)(NSString *, NSArray *) = ^NSDictionary *(NSString *query, NSArray *services) {
    NSMutableDictionary *message = [@{@"version": @1, @"request": NSUUID.UUID.UUIDString, @"operation": @"catalog", @"scope": @"all"} mutableCopy];
    if(query) message[@"query"] = query;
    if(services) message[@"services"] = services;
    XCTAssertTrue(MPAutoFillValidateRequest(message), @"%@", message);
    return [server replyToMessage:message owner:self.owner];
  };
  // Both site accounts lead, in catalog order; the services filter nothing.
  NSArray *everything = [showAll(nil, site)[@"entries"] valueForKey:@"record"];
  XCTAssertEqual(everything.count, 100U);
  XCTAssertEqualObjects([everything subarrayWithRange:NSMakeRange(0, 3)], (@[@"Mail here", @"Other here", @"mail-000"]));
  XCTAssertEqualObjects(everything.lastObject, @"mail-097");
  // A search keeps the site's matches ahead of the others'.
  NSDictionary *mail = showAll(@"mail", site);
  NSArray *records = [mail[@"entries"] valueForKey:@"record"];
  XCTAssertEqual(records.count, 100U);
  XCTAssertEqualObjects(records.firstObject, @"Mail here");
  XCTAssertEqualObjects(records[1], @"mail-000");
  XCTAssertEqualObjects(records.lastObject, @"mail-098");
  XCTAssertEqualObjects(mail[@"more"], @YES);
  // Without services the catalog order holds, and the site's account is held back.
  NSArray *plain = [showAll(@"mail", nil)[@"entries"] valueForKey:@"record"];
  XCTAssertEqualObjects(plain.firstObject, @"mail-000");
  XCTAssertFalse([plain containsObject:@"Mail here"]);
}

// Order: the site's accounts, then the others; within both, titles that begin
// with the query first; otherwise catalog order.
- (void)testTitlesThatBeginWithTheQueryAreListedFirst {
  MPAutoFillManyServerStub *server = [[MPAutoFillManyServerStub alloc] init];
  NSDictionary *(^entry)(NSString *, NSString *) = ^NSDictionary *(NSString *title, NSString *host) {
    return @{@"record": title, @"title": title, @"user": @"user", @"host": host, @"port": @"", @"database": @"Test database", @"available": @YES};
  };
  // In catalog order.
  server.entries = @[entry(@"Digital Ocean", @"digitalocean.com"), entry(@"Gitea here", @"example.com"), entry(@"GitHub", @"github.com"),
                     entry(@"My git server", @"www.example.com"), entry(@"Zgit", @"zgit.example")];
  NSArray *site = @[@{@"host": @"example.com", @"port": @""}];
  NSArray *(^list)(NSDictionary *) = ^NSArray *(NSDictionary *fields) {
    NSMutableDictionary *message = [@{@"version": @1, @"request": NSUUID.UUID.UUIDString, @"operation": @"catalog"} mutableCopy];
    [message addEntriesFromDictionary:fields];
    XCTAssertTrue(MPAutoFillValidateRequest(message), @"%@", message);
    return [[server replyToMessage:message owner:self.owner][@"entries"] valueForKey:@"title"];
  };
  XCTAssertEqualObjects(list((@{@"scope": @"all", @"services": site, @"query": @"git"})),
                        (@[@"Gitea here", @"My git server", @"GitHub", @"Digital Ocean", @"Zgit"]));
  XCTAssertEqualObjects(list((@{@"scope": @"all", @"query": @"git"})), (@[@"Gitea here", @"GitHub", @"Digital Ocean", @"My git server", @"Zgit"]));
  XCTAssertEqualObjects(list((@{@"services": site, @"query": @"GIT"})), (@[@"Gitea here", @"My git server"]));
  // Without a query only the site leads.
  XCTAssertEqualObjects(list((@{@"scope": @"all", @"services": site})), (@[@"Gitea here", @"My git server", @"Digital Ocean", @"GitHub", @"Zgit"]));
  // A title that begins with the query is listed even behind the first hundred matches.
  NSMutableArray *many = NSMutableArray.array;
  for(NSUInteger index = 0; index < 150; index++) [many addObject:entry([NSString stringWithFormat:@"Mail %03lu", (unsigned long)index], @"mail.example")];
  [many addObject:entry(@"Ailment", @"ailment.example")];
  server.entries = many;
  NSArray *titles = list(@{@"scope": @"all", @"query": @"ail"});
  XCTAssertEqual(titles.count, 100U);
  XCTAssertEqualObjects(titles.firstObject, @"Ailment");
  XCTAssertEqualObjects(titles.lastObject, @"Mail 098");
}

- (void)testQueryMatchesOnlyTheDisplayedText {
  NSDictionary *entry = @{@"record": @"secret-record-id", @"title": @"Mail", @"user": @"user", @"host": @"mail.example", @"port": @"8443",
                          @"database": @"Personal", @"available": @NO, @"reason": @"Unsupported placeholder"};
  for(NSString *query in @[@"mail", @"USER", @"personal", @"mail.example", @"Mail user", @""]) {
    XCTAssertTrue(MPAutoFillEntryMatchesQuery(entry, query), @"%@", query);
  }
  XCTAssertTrue(MPAutoFillEntryMatchesQuery(entry, nil));
  for(NSString *query in @[@"secret-record", @"8443", @"placeholder", @"user mail"]) {
    XCTAssertFalse(MPAutoFillEntryMatchesQuery(entry, query), @"%@", query);
  }
  // Missing or malformed fields are not text.
  XCTAssertFalse(MPAutoFillEntryMatchesQuery(@{@"title": @5, @"user": NSNull.null}, @"null"));
  XCTAssertFalse(MPAutoFillEntryMatchesQuery(@{@"title": @5}, @"5"));
  // Listed first: the title begins with the query, which may run on into the user.
  for(NSString *query in @[@"ma", @"MAIL", @"mail us", @""]) {
    XCTAssertTrue(MPAutoFillEntryBeginsWithQuery(entry, query), @"%@", query);
  }
  XCTAssertTrue(MPAutoFillEntryBeginsWithQuery(entry, nil));
  XCTAssertTrue(MPAutoFillEntryBeginsWithQuery(@{@"title": @"Café"}, @"cafe"));
  for(NSString *query in @[@"ail", @"user", @"personal", @"mail.example", @"secret"]) {
    XCTAssertFalse(MPAutoFillEntryBeginsWithQuery(entry, query), @"%@", query);
  }
}

- (void)testCatalogQueryIsBoundedAndOnlyNarrowsLists {
  NSDictionary *(^message)(NSString *, NSDictionary *) = ^NSDictionary *(NSString *operation, NSDictionary *fields) {
    NSMutableDictionary *message = [@{@"version": @1, @"request": NSUUID.UUID.UUIDString, @"operation": operation} mutableCopy];
    [message addEntriesFromDictionary:fields];
    return message;
  };
  NSString *longest = [@"" stringByPaddingToLength:256 withString:@"q" startingAtIndex:0];
  NSArray *site = @[@{@"host": @"example.com", @"port": @""}];
  for(NSDictionary *fields in @[@{@"scope": @"all", @"query": @"a"}, @{@"scope": @"all", @"query": longest}, @{@"services": site, @"query": @"a"},
                                @{@"scope": @"all", @"services": site, @"query": @"a"}]) {
    XCTAssertTrue(MPAutoFillValidateRequest(message(@"catalog", fields)), @"%@", fields);
  }
  for(id query in @[[longest stringByAppendingString:@"q"], @"", @5, @[@"a"]]) {
    XCTAssertFalse(MPAutoFillValidateRequest(message(@"catalog", @{@"scope": @"all", @"query": query})), @"%@", query);
  }
  XCTAssertFalse(MPAutoFillValidateRequest(message(@"catalog", @{@"record": @"test-record", @"query": @"a"})));
  XCTAssertFalse(MPAutoFillValidateRequest(message(@"catalog", @{@"record": @"test-record", @"services": site})));
  XCTAssertFalse(MPAutoFillValidateRequest(message(@"credential", @{@"record": @"test-record", @"query": @"a"})));
  for(NSString *operation in @[@"cancel", @"unlock", @"subscribe"]) {
    XCTAssertFalse(MPAutoFillValidateRequest(message(operation, @{@"query": @"a"})), @"%@", operation);
  }
}

- (void)testLockAfterCatalogPreventsCredentialDelivery {
  MPAutoFillServerStub *server = [[MPAutoFillServerStub alloc] init];
  NSString *request = NSUUID.UUID.UUIDString;
  [self catalog:server request:request];
  server.status = @"locked";
  NSDictionary *reply = [self fetch:@"test-record" request:request from:server];
  XCTAssertEqualObjects(reply[@"status"], @"locked");
  XCTAssertNil(reply[@"password"]);
  server.status = nil;
  XCTAssertEqualObjects([self fetch:@"test-record" request:request from:server][@"status"], @"unavailable");
}

#pragma mark Catalog

- (void)testAvailabilityNotificationsInvalidateBeforeMetadataDebounce {
  MPAutoFillTestDocument *first = self.document, *second = self.document;
  [self entryIn:first]; [self entryIn:second];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[first, second]];
  coordinator.lastActiveDocument = first;
  [self entries:coordinator];
  NSUInteger count = coordinator.invalidationCount;
  NSArray *transitions = @[@"lock", @"unlock", @"switch", @"conflict", @"close"];
  for(NSString *transition in transitions) {
    [self catalog:coordinator request:NSUUID.UUID.UUIDString];
    if([transition isEqual:@"lock"]) first.testLocked = YES;
    if([transition isEqual:@"unlock"]) first.testLocked = NO;
    if([transition isEqual:@"switch"]) coordinator.lastActiveDocument = second;
    if([transition isEqual:@"conflict"]) second.testConflict = YES;
    if([transition isEqual:@"close"]) coordinator.documents = @[];
    [coordinator documentsChanged:[NSNotification notificationWithName:MPAutoFillDocumentsChangedNotification object:nil]];
    XCTAssertEqual(coordinator.invalidationCount, ++count, @"%@", transition);
    XCTAssertEqual(coordinator.grants.count, 0U);
    if(![coordinator.providerStatus isEqual:@"ready"]) XCTAssertEqual(coordinator.catalogEntries.count, 0U);
  }
}

- (void)testBackgroundConflictNotificationReconcilesOnMainQueue {
  MPAutoFillTestDocument *document = self.document; [self entryIn:document];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  [self catalog:coordinator request:NSUUID.UUID.UUIDString];
  document.testConflict = YES;
  XCTestExpectation *delivered = [self expectationWithDescription:@"Background file notification"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    [coordinator documentsChanged:[NSNotification notificationWithName:MPAutoFillDocumentsChangedNotification object:document]];
    dispatch_async(dispatch_get_main_queue(), ^{ [delivered fulfill]; });
  });
  [self waitForExpectationsWithTimeout:1 handler:nil];
  XCTAssertEqual(coordinator.grants.count, 0U);
  XCTAssertEqual(coordinator.catalogEntries.count, 0U);
  XCTAssertEqualObjects(coordinator.providerStatus, @"conflict");
}

- (void)testCatalogContainsMetadataAndUsesUnsavedPassword {
  MPAutoFillTestDocument *document = self.document;
  KPKEntry *entry = [self entryIn:document];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  NSDictionary *item = [self entries:coordinator].firstObject;
  XCTAssertEqualObjects(item[@"host"], @"example.com");
  XCTAssertEqualObjects(item[@"port"], @"");
  XCTAssertNil(item[@"password"]); XCTAssertNil(item[@"uuid"]); XCTAssertNil(item[@"document"]);
  entry.password = @"unsaved-new-password";
  XCTAssertEqualObjects([self credential:coordinator record:item[@"record"]][@"password"], @"unsaved-new-password");
}

- (void)testPortEntriesAppearInSuggestionsAndMatchAnyPort {
  MPAutoFillTestDocument *document = self.document;
  [self entryIn:document];
  KPKEntry *portEntry = [self entryIn:document];
  portEntry.username = @"port-user"; portEntry.url = @"https://example.com:8443";
  MPAutoFillTestCoordinator *coordinator = [self publisher:@[document]];
  [coordinator refreshCatalog];
  [self drainMainQueue];
  XCTAssertEqual(coordinator.store.identities.count, 2U);
  NSString *record = nil;
  for(NSDictionary *item in [self entries:coordinator]) if([item[@"user"] isEqual:@"port-user"]) record = item[@"record"];
  XCTAssertNotNil(record);
  NSArray *published = [coordinator.store.identities filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(ASPasswordCredentialIdentity *identity, NSDictionary *bindings) {
    return [identity.recordIdentifier isEqual:record] && [identity.user isEqual:@"port-user"] && [identity.serviceIdentifier.identifier isEqual:@"example.com"];
  }]];
  XCTAssertEqual(published.count, 1U);
  NSDictionary *selected = [coordinator replyToMessage:@{@"request": NSUUID.UUID.UUIDString, @"operation": @"catalog", @"record": record} owner:self.owner];
  XCTAssertEqual([selected[@"entries"] count], 1U);
  XCTAssertEqualObjects([self fetch:record request:selected[@"request"] from:coordinator][@"password"], portEntry.password);
  NSDictionary *otherPort = [coordinator replyToMessage:@{@"request": NSUUID.UUID.UUIDString, @"operation": @"catalog",
    @"services": @[@{@"host": @"example.com", @"port": @"9443"}]} owner:self.owner];
  XCTAssertEqual([otherPort[@"entries"] count], 2U);
  XCTAssertEqualObjects([self fetch:record request:otherPort[@"request"] from:coordinator][@"password"], portEntry.password);
  NSDictionary *right = [coordinator replyToMessage:@{@"request": NSUUID.UUID.UUIDString, @"operation": @"catalog",
    @"services": @[@{@"host": @"example.com", @"port": @"8443"}]} owner:self.owner];
  XCTAssertEqual([right[@"entries"] count], 2U);
  XCTAssertEqualObjects([self fetch:record request:right[@"request"] from:coordinator][@"password"], portEntry.password);
}

- (void)testOnlyTheActiveDatabaseIsExposed {
  MPAutoFillTestDocument *first = self.document, *second = self.document;
  KPKEntry *entry = [self entryIn:first];
  KPKEntry *copy = [entry copy]; copy.username = @"second-user"; [copy addToGroup:second.root];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[first, second]];
  coordinator.lastActiveDocument = first;
  NSArray *items = [self entries:coordinator];
  XCTAssertEqual(items.count, 1U);
  XCTAssertEqualObjects(items.firstObject[@"user"], @"user");
  NSString *firstRecord = items.firstObject[@"record"];
  XCTAssertNotNil([self credential:coordinator record:firstRecord][@"password"]);
  coordinator.lastActiveDocument = second;
  [coordinator refreshCatalog];
  items = [self entries:coordinator];
  XCTAssertEqual(items.count, 1U);
  XCTAssertEqualObjects(items.firstObject[@"user"], @"second-user");
  XCTAssertEqualObjects(coordinator.published.firstObject[@"user"], @"second-user");
  XCTAssertNotEqualObjects(items.firstObject[@"record"], firstRecord);
  XCTAssertEqualObjects([self credential:coordinator record:firstRecord][@"status"], @"stale");
  // Records are bound to one host session.
  MPAutoFillCatalogCoordinator *next = [self coordinator:@[first]];
  XCTAssertNotEqualObjects([self entries:next].firstObject[@"record"], firstRecord);
  XCTAssertNil([self credential:next record:firstRecord][@"password"]);
}

- (void)testLockedDatabaseExposesNoMetadata {
  MPAutoFillTestDocument *document = self.document;
  [self entryIn:document];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  NSString *record = [self entries:coordinator].firstObject[@"record"];
  XCTAssertEqual(coordinator.published.count, 1U);
  document.testLocked = YES;
  [coordinator refreshCatalog];
  XCTAssertEqual([self entries:coordinator].count, 0U);
  XCTAssertEqual(coordinator.published.count, 0U);
  XCTAssertEqualObjects([self credential:coordinator record:record][@"status"], @"locked");
  NSDictionary *catalog = [self catalog:coordinator request:NSUUID.UUID.UUIDString];
  XCTAssertEqualObjects(catalog[@"status"], @"locked");
  XCTAssertEqual([catalog[@"entries"] count], 0U);
  document.testLocked = NO;
  document.testConflict = YES;
  [coordinator refreshCatalog];
  XCTAssertEqual([self entries:coordinator].count, 0U);
  XCTAssertEqualObjects([self catalog:coordinator request:NSUUID.UUID.UUIDString][@"status"], @"conflict");
  document.testConflict = NO;
  [coordinator refreshCatalog];
  XCTAssertEqual([self entries:coordinator].count, 1U);
  coordinator.enabled = NO;
  [coordinator refreshCatalog];
  XCTAssertEqual([self entries:coordinator].count, 0U); XCTAssertEqual(coordinator.published.count, 0U);
}

- (void)testLockNotificationRemovesIdentitiesWithoutDelay {
  MPAutoFillTestDocument *document = self.document;
  [self entryIn:document];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  XCTAssertEqual([self entries:coordinator].count, 1U);
  XCTAssertEqual(coordinator.published.count, 1U);
  document.testLocked = YES;
  [coordinator documentsChanged:[NSNotification notificationWithName:MPDocumentDidLockDatabaseNotification object:document]];
  XCTAssertEqual(coordinator.published.count, 0U);
}

- (void)testCatalogWithoutAuthenticationContainsOnlyTheRequestedSite {
  MPAutoFillTestDocument *document = self.document;
  [self entryIn:document];
  KPKEntry *other = [self entryIn:document]; other.url = @"https://other.example"; other.username = @"other-user";
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  NSDictionary *scoped = [coordinator replyToMessage:@{@"request": NSUUID.UUID.UUIDString, @"operation": @"catalog",
    @"services": @[@{@"host": @"www.example.com", @"port": @""}]} owner:self.owner];
  XCTAssertEqual([scoped[@"entries"] count], 1U);
  XCTAssertEqualObjects([scoped[@"entries"] firstObject][@"user"], @"user");
  NSDictionary *unscoped = [coordinator replyToMessage:@{@"request": NSUUID.UUID.UUIDString, @"operation": @"catalog"} owner:self.owner];
  XCTAssertEqual([unscoped[@"entries"] count], 0U);
  // A record outside the scoped grant cannot be fetched with that grant.
  NSString *otherRecord = nil;
  for(NSDictionary *item in [self entries:coordinator]) if([item[@"user"] isEqual:@"other-user"]) otherRecord = item[@"record"];
  XCTAssertNil([self fetch:otherRecord request:scoped[@"request"] from:coordinator][@"password"]);
  XCTAssertEqual([[self catalog:coordinator request:NSUUID.UUID.UUIDString][@"entries"] count], 2U);
}

- (void)testGroupsWithSearchingDisabledAreExcluded {
  MPAutoFillTestDocument *document = self.document;
  KPKGroup *hidden = [document.tree createGroup:document.root];
  [hidden addToGroup:document.root];
  hidden.isSearchEnabled = KPKInheritNO;
  [self entryIn:document group:hidden];
  [self entryIn:document];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  XCTAssertEqual([self entries:coordinator].count, 1U);
}

- (void)testDisablingSearchAfterTheCatalogPreventsIssuance {
  MPAutoFillTestDocument *document = self.document;
  KPKGroup *group = [document.tree createGroup:document.root];
  [group addToGroup:document.root];
  [self entryIn:document group:group];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  NSString *record = [self entries:coordinator].firstObject[@"record"];
  XCTAssertNotNil([self credential:coordinator record:record][@"password"]);
  group.isSearchEnabled = KPKInheritNO; // Without a model notification.
  XCTAssertEqualObjects([self credential:coordinator record:record][@"status"], @"stale");
}

- (void)testTrashExpiryRemovalAndConflictPreventIssuance {
  MPAutoFillTestDocument *document = self.document;
  KPKEntry *entry = [self entryIn:document];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  NSString *record = [self entries:coordinator].firstObject[@"record"];
  document.testConflict = YES;
  XCTAssertEqualObjects([self credential:coordinator record:record][@"status"], @"conflict");
  document.testConflict = NO;
  entry.timeInfo.expires = YES; entry.timeInfo.expirationDate = [NSDate dateWithTimeIntervalSinceNow:-1];
  XCTAssertNil([self credential:coordinator record:record][@"password"]);
  [coordinator refreshCatalog];
  XCTAssertEqual([self entries:coordinator].count, 0U);
  entry.timeInfo.expires = NO;
  [coordinator refreshCatalog];
  record = [self entries:coordinator].firstObject[@"record"];
  [entry trashOrRemove];
  XCTAssertNil([self credential:coordinator record:record][@"password"]);
  [coordinator refreshCatalog];
  XCTAssertEqual([self entries:coordinator].count, 0U);
}

- (void)testUpcomingExpirationSchedulesOneRefresh {
  MPAutoFillTestDocument *document = self.document;
  KPKEntry *later = [self entryIn:document], *sooner = [self entryIn:document];
  NSDate *soonest = [NSDate dateWithTimeIntervalSinceNow:3600];
  later.timeInfo.expires = YES; later.timeInfo.expirationDate = [NSDate dateWithTimeIntervalSinceNow:7200];
  sooner.timeInfo.expires = YES; sooner.timeInfo.expirationDate = soonest;
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  [coordinator refreshCatalog];
  XCTAssertTrue(coordinator.expirationTimer.valid);
  XCTAssertEqualWithAccuracy(coordinator.expirationTimer.fireDate.timeIntervalSinceReferenceDate, soonest.timeIntervalSinceReferenceDate + 1, 0.01);
  sooner.timeInfo.expires = NO; later.timeInfo.expires = NO;
  [coordinator refreshCatalog];
  XCTAssertNil(coordinator.expirationTimer);
}

- (NSDictionary *)itemTitled:(NSString *)title in:(MPAutoFillCatalogCoordinator *)coordinator {
  [coordinator refreshCatalog];
  for(NSDictionary *item in [self entries:coordinator]) if([item[@"title"] isEqual:title]) return item;
  return nil;
}

- (void)testSafeReferencesAndInteractivePlaceholders {
  MPAutoFillTestDocument *document = self.document;
  KPKEntry *source = [self entryIn:document];
  KPKEntry *reference = [self entryIn:document]; reference.title = @"Reference";
  NSString *uuid = [source.uuid.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
  reference.password = [NSString stringWithFormat:@"{REF:P@I:%@}", uuid];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  NSString *record = [self itemTitled:@"Reference" in:coordinator][@"record"];
  XCTAssertEqualObjects([self credential:coordinator record:record][@"password"], source.password);
  source.password = @"{PICKCHARS}";
  XCTAssertNil([self credential:coordinator record:record][@"password"]);
  [coordinator refreshCatalog];
  for(NSDictionary *item in [self entries:coordinator]) XCTAssertFalse([item[@"available"] boolValue]);
  source.password = @"public-secret";
  reference.username = [NSString stringWithFormat:@"{REF:P@I:%@}", uuid];
  [coordinator refreshCatalog];
  for(NSDictionary *item in [self entries:coordinator]) {
    XCTAssertNotEqualObjects(item[@"user"], source.password); // No password-valued identity.
  }
  XCTAssertFalse([[self itemTitled:@"Reference" in:coordinator][@"available"] boolValue]);
}

- (void)testLiteralBracesAreFilledButKnownPlaceholdersAreNot {
  MPAutoFillTestDocument *document = self.document;
  KPKEntry *entry = [self entryIn:document];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  entry.password = @"pa{ss}word{}";
  NSString *record = [self itemTitled:@"Public test" in:coordinator][@"record"];
  XCTAssertEqualObjects([self credential:coordinator record:record][@"password"], @"pa{ss}word{}");
  for(NSString *placeholder in @[@"x{USERNAME}", @"{url:host}", @"{TOTP}", @"{HMACOTP}", @"{PickField}", @"{PICKCHARS:Password:C=2}"]) {
    entry.password = placeholder;
    XCTAssertNil([self credential:coordinator record:record][@"password"], @"%@", placeholder);
    XCTAssertFalse([[self itemTitled:@"Public test" in:coordinator][@"available"] boolValue], @"%@", placeholder);
  }
}

// Search references depend on KeePassKit's search order; only @I is filled.
- (void)testSearchReferencesAreUnavailable {
  MPAutoFillTestDocument *document = self.document;
  KPKEntry *source = [self entryIn:document]; source.title = @"Shared";
  for(NSString *search in @[@"T:Shared", @"U:user", @"A:example", @"N:x", @"O:x"]) {
    KPKEntry *reference = [self entryIn:document]; reference.title = search;
    reference.password = [NSString stringWithFormat:@"{REF:P@%@}", search];
  }
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  for(NSString *search in @[@"T:Shared", @"U:user", @"A:example", @"N:x", @"O:x"]) {
    NSDictionary *item = [self itemTitled:search in:coordinator];
    XCTAssertFalse([item[@"available"] boolValue], @"%@", search);
    XCTAssertNil([self credential:coordinator record:item[@"record"]][@"password"], @"%@", search);
  }
}

- (void)testReferenceCyclesAndIneligibleTargetsAreUnavailable {
  MPAutoFillTestDocument *document = self.document;
  KPKEntry *a = [self entryIn:document]; a.title = @"A";
  KPKEntry *b = [self entryIn:document]; b.title = @"B";
  a.password = [NSString stringWithFormat:@"{REF:P@I:%@}", b.uuid.UUIDString];
  b.password = [NSString stringWithFormat:@"{REF:P@I:%@}", a.uuid.UUIDString];
  KPKEntry *source = [self entryIn:document]; source.title = @"Source";
  KPKEntry *reference = [self entryIn:document]; reference.title = @"Reference";
  reference.password = [NSString stringWithFormat:@"{REF:P@I:%@}", source.uuid.UUIDString];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  XCTAssertFalse([[self itemTitled:@"A" in:coordinator][@"available"] boolValue]);
  XCTAssertFalse([[self itemTitled:@"B" in:coordinator][@"available"] boolValue]);
  NSString *record = [self itemTitled:@"Reference" in:coordinator][@"record"];
  XCTAssertEqualObjects([self credential:coordinator record:record][@"password"], source.password);
  source.timeInfo.expires = YES; source.timeInfo.expirationDate = [NSDate dateWithTimeIntervalSinceNow:-1];
  XCTAssertNil([self credential:coordinator record:record][@"password"]);
}

- (void)testSubstitutionCannotAssembleAPlaceholder {
  MPAutoFillTestDocument *document = self.document;
  KPKEntry *source = [self entryIn:document]; source.title = @"Source"; source.password = @"{TOT";
  KPKEntry *reference = [self entryIn:document]; reference.title = @"Reference";
  reference.password = [NSString stringWithFormat:@"{REF:P@I:%@}P}", source.uuid.UUIDString];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  XCTAssertTrue([[self itemTitled:@"Source" in:coordinator][@"available"] boolValue]); // An unclosed brace is literal text.
  NSDictionary *item = [self itemTitled:@"Reference" in:coordinator];
  XCTAssertFalse([item[@"available"] boolValue]);
  XCTAssertNil([self credential:coordinator record:item[@"record"]][@"password"]);
}

// One rule decides what the picker offers and what the host fills.
- (void)testCatalogAndFillShareOneRule {
  MPAutoFillTestDocument *document = self.document;
  KPKEntry *url = [self entryIn:document]; url.title = @"URL"; url.url = @"https://example.com/{TOTP}";
  KPKEntry *source = [self entryIn:document]; source.title = @"Source"; source.password = @"";
  KPKEntry *empty = [self entryIn:document]; empty.title = @"Empty";
  empty.password = [NSString stringWithFormat:@"{REF:P@I:%@}", source.uuid.UUIDString];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  for(NSString *title in @[@"URL", @"Empty"]) {
    NSDictionary *item = [self itemTitled:title in:coordinator];
    XCTAssertNotNil(item, @"%@", title);
    XCTAssertFalse([item[@"available"] boolValue], @"%@", title);
    XCTAssertEqualObjects([self credential:coordinator record:item[@"record"]][@"status"], @"stale", @"%@", title);
  }
}

#pragma mark Active requests

- (void)testHarmlessEditKeepsAnActiveRequest {
  MPAutoFillTestDocument *document = self.document; KPKEntry *entry = [self entryIn:document];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  NSString *request = NSUUID.UUID.UUIDString;
  NSDictionary *catalog = [self catalog:coordinator request:request];
  entry.notes = @"edited during authentication";
  [coordinator refreshCatalog];
  XCTAssertEqualObjects([self fetch:[catalog[@"entries"] firstObject][@"record"] request:request from:coordinator][@"password"], @"public-secret");
}

- (void)testLockInvalidatesAnActiveRequest {
  MPAutoFillTestDocument *document = self.document; [self entryIn:document];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  NSString *request = NSUUID.UUID.UUIDString;
  NSDictionary *catalog = [self catalog:coordinator request:request];
  document.testLocked = YES;
  [coordinator refreshCatalog];
  document.testLocked = NO;
  [coordinator refreshCatalog];
  XCTAssertNil([self fetch:[catalog[@"entries"] firstObject][@"record"] request:request from:coordinator][@"password"]);
}

- (void)testSiteChangeCannotRedirectAnActiveRequest {
  MPAutoFillTestDocument *document = self.document; KPKEntry *entry = [self entryIn:document];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  NSString *request = NSUUID.UUID.UUIDString;
  NSDictionary *catalog = [self catalog:coordinator request:request];
  entry.url = @"https://other.example";
  [coordinator refreshCatalog];
  XCTAssertEqualObjects([self fetch:[catalog[@"entries"] firstObject][@"record"] request:request from:coordinator][@"status"], @"stale");
}

- (void)testPortChangeCannotRedirectAnActiveRequest {
  MPAutoFillTestDocument *document = self.document; KPKEntry *entry = [self entryIn:document];
  entry.url = @"https://example.com:8443";
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  NSString *request = NSUUID.UUID.UUIDString;
  NSDictionary *catalog = [self catalog:coordinator request:request];
  XCTAssertEqualObjects([catalog[@"entries"] firstObject][@"port"], @"8443");
  entry.url = @"https://example.com:9443"; // No notification, no refresh.
  XCTAssertEqualObjects([self fetch:[catalog[@"entries"] firstObject][@"record"] request:request from:coordinator][@"status"], @"stale");
}

- (void)testUnlockHandoffKeepsItsDatabase {
  MPAutoFillTestDocument *first = self.document, *second = self.document;
  first.testLocked = YES;
  MPAutoFillUnlockCoordinator *coordinator = [self configure:[[MPAutoFillUnlockCoordinator alloc] initWithDefaults:self.defaults] documents:@[first, second]];
  coordinator.lastActiveDocument = first;
  XCTAssertTrue([coordinator requestUnlock]);
  coordinator.lastActiveDocument = second; // E.g. another window became main.
  XCTAssertEqual(coordinator.documentToReveal, first);
  coordinator.documents = @[second]; // The handoff database was closed.
  XCTAssertEqual(coordinator.documentToReveal, second);
}

- (void)testUnlockHandoffExpires {
  MPAutoFillTestDocument *first = self.document, *second = self.document;
  first.testLocked = YES;
  MPAutoFillUnlockCoordinator *coordinator = [self configure:[[MPAutoFillUnlockCoordinator alloc] initWithDefaults:self.defaults] documents:@[first, second]];
  coordinator.lastActiveDocument = first;
  XCTAssertTrue([coordinator requestUnlock]);
  coordinator.lastActiveDocument = second;
  XCTAssertEqual(coordinator.documentToReveal, first);
  coordinator.unlockDeadline = NSProcessInfo.processInfo.systemUptime - 1; // The 15 s window passed.
  XCTAssertEqual(coordinator.documentToReveal, second);
}

- (void)testUnlockRequiresAnEnabledActiveDatabase {
  MPAutoFillTestDocument *document = self.document;
  document.testLocked = YES;
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[]];
  XCTAssertFalse([coordinator requestUnlock]);
  coordinator.documents = @[document];
  XCTAssertTrue([coordinator requestUnlock]);
  coordinator.enabled = NO;
  XCTAssertFalse([coordinator requestUnlock]);
}

#pragma mark Delivery

// The server's worker path: the reply is built on the main queue.
- (void)answer:(NSDictionary *)message server:(MPAutoFillServer *)server socket:(int)fd {
  XCTestExpectation *done = [self expectationWithDescription:@"Answered"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [server answerMessage:message owner:self.owner socket:fd error:NULL];
    [done fulfill];
  });
  [self waitForExpectationsWithTimeout:10 handler:nil];
  [self drainMainQueue];
}

- (void)testOversizedCatalogIsAnsweredWithoutAGrant {
  MPAutoFillLargeServerStub *server = [[MPAutoFillLargeServerStub alloc] init];
  int sockets[2];
  XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
  MPAutoFillConfigureSocket(sockets[0]); MPAutoFillConfigureSocket(sockets[1]);
  NSString *request = NSUUID.UUID.UUIDString;
  [self answer:@{@"version": @1, @"request": request, @"operation": @"catalog", @"scope": @"all"} server:server socket:sockets[0]];
  NSDictionary *reply = MPAutoFillReadMessage(sockets[1], NULL);
  XCTAssertEqualObjects(reply[@"status"], @"tooLarge");
  XCTAssertNil(reply[@"entries"]);
  XCTAssertNil(server.grants[request]);
  close(sockets[0]); close(sockets[1]);
}

- (void)testUndeliveredCatalogRevokesOnlyItsGrant {
  MPAutoFillServerStub *server = [[MPAutoFillServerStub alloc] init];
  int sockets[2];
  XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
  MPAutoFillConfigureSocket(sockets[0]);
  close(sockets[1]); // The extension went away.
  NSString *request = NSUUID.UUID.UUIDString;
  [self answer:@{@"version": @1, @"request": request, @"operation": @"catalog", @"scope": @"all"} server:server socket:sockets[0]];
  XCTAssertNil(server.grants[request]);
  close(sockets[0]);
  // A later catalog of the same request replaced the grant: it stays.
  [self catalog:server request:request];
  [server revokeGrant:@{} request:request];
  [self drainMainQueue];
  XCTAssertNotNil(server.grants[request]);
}

#pragma mark Identity store

- (void)testDisabledLaunchNeverTouchesTheStore {
  [self.defaults setBool:NO forKey:MPAutoFillEnabledPreference];
  MPAutoFillTestCoordinator *coordinator = [self publisher:@[]];
  coordinator.testListening = NO;
  [coordinator refreshCatalog]; [self drainMainQueue];
  XCTAssertEqual(coordinator.store.stateRequestCount, 0U);
  XCTAssertFalse(coordinator.testListening);
}

- (void)testIndexRetriesFailureWithoutChangingMetadata {
  MPAutoFillTestDocument *document = self.document; [self entryIn:document];
  MPAutoFillTestCoordinator *coordinator = [self publisher:@[document]];
  [coordinator refreshCatalog]; [self drainMainQueue];
  coordinator.store.pendingReplacement(NO, [NSError errorWithDomain:ASCredentialIdentityStoreErrorDomain code:ASCredentialIdentityStoreErrorCodeStoreBusy userInfo:nil]);
  [self drainMainQueue];
  XCTAssertEqual(coordinator.store.replacementCount, 1U); // No immediate retry loop.
  XCTAssertTrue(coordinator.indexDirty);
  [coordinator refreshCatalog]; [self drainMainQueue];
  XCTAssertEqual(coordinator.store.replacementCount, 2U);
  coordinator.store.pendingReplacement(YES, nil); [self drainMainQueue];
  [coordinator refreshCatalog]; [self drainMainQueue];
  XCTAssertEqual(coordinator.store.replacementCount, 2U);
}

- (void)testEnablingProviderPublishesAnUnchangedCatalogOnActivation {
  MPAutoFillTestDocument *document = self.document; [self entryIn:document];
  MPAutoFillTestCoordinator *coordinator = [self publisher:@[document]];
  coordinator.store.enabled = NO;
  [coordinator refreshCatalog]; [self drainMainQueue];
  XCTAssertEqual(coordinator.store.replacementCount, 0U);
  XCTAssertTrue(coordinator.indexDirty);
  coordinator.store.enabled = YES;
  [coordinator applicationDidBecomeActive:nil]; [self drainMainQueue];
  XCTAssertEqual(coordinator.store.replacementCount, 1U);
  XCTAssertEqual(coordinator.store.identities.count, 1U);
}

- (void)testLockDuringStoreStateQueryPublishesNoMetadata {
  MPAutoFillTestDocument *document = self.document; [self entryIn:document];
  MPAutoFillTestCoordinator *coordinator = [self publisher:@[document]];
  coordinator.store.deferState = YES;
  [coordinator refreshCatalog];
  document.testLocked = YES;
  [coordinator refreshCatalog];
  coordinator.store.pendingState((id)coordinator.store); [self drainMainQueue];
  XCTAssertEqual(coordinator.store.replacementCount, 1U);
  XCTAssertEqual(coordinator.store.identities.count, 0U);
}

- (void)testDisabledSecondInstanceCannotClearTheListeningInstancesStore {
  // Identities a crash left behind, while another instance owns the listener.
  [self.defaults setBool:NO forKey:MPAutoFillEnabledPreference];
  MPAutoFillTestCoordinator *coordinator = [self publisher:@[]];
  coordinator.indexMayHoldIdentities = YES;
  coordinator.indexDirty = YES;
  coordinator.testListening = NO; coordinator.canStart = NO;
  [coordinator refreshCatalog]; [self drainMainQueue];
  XCTAssertEqual(coordinator.store.stateRequestCount, 0U);
  XCTAssertEqual(coordinator.store.replacementCount, 0U);
  coordinator.canStart = YES;
  [coordinator refreshCatalog]; [self drainMainQueue];
  XCTAssertEqual(coordinator.store.replacementCount, 1U);
  XCTAssertEqual(coordinator.store.identities.count, 0U);
  coordinator.store.pendingReplacement(YES, nil); [self drainMainQueue];
  XCTAssertFalse(coordinator.testListening);
  XCTAssertFalse(coordinator.indexMayHoldIdentities);
}

- (void)testDisablingDuringPublicationClearsBeforeReleasingOwnership {
  MPAutoFillTestDocument *document = self.document; [self entryIn:document];
  MPAutoFillTestCoordinator *coordinator = [self publisher:@[document]];
  [coordinator refreshCatalog]; [self drainMainQueue];
  XCTAssertTrue(coordinator.indexMayHoldIdentities);
  [self.defaults setBool:NO forKey:MPAutoFillEnabledPreference];
  [coordinator enabledPreferenceChanged]; [self drainMainQueue];
  XCTAssertTrue(coordinator.testListening);
  ASPasswordCredentialIdentity *identity = coordinator.store.identities.firstObject;
  XCTAssertNil([self credential:coordinator record:identity.recordIdentifier][@"password"]);
  coordinator.store.pendingReplacement(YES, nil);
  [self drainMainQueue]; [self drainMainQueue];
  XCTAssertEqual(coordinator.store.replacementCount, 2U);
  XCTAssertEqual(coordinator.store.identities.count, 0U);
  XCTAssertTrue(coordinator.testListening);
  coordinator.store.pendingReplacement(YES, nil); [self drainMainQueue];
  XCTAssertFalse(coordinator.testListening);
  XCTAssertFalse(coordinator.indexMayHoldIdentities);
}

- (void)testQuittingDoesNotRebuildOrRepublishTheCatalog {
  MPAutoFillTestDocument *document = self.document;
  [self entryIn:document];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  NSString *record = [self entries:coordinator].firstObject[@"record"];
  coordinator.quitting = YES;
  [coordinator.metadata removeAllObjects];
  coordinator.published = nil;
  [coordinator documentsChanged:nil];
  XCTAssertEqual([self entries:coordinator].count, 0U);
  XCTAssertNil(coordinator.published);
  XCTAssertNil([self credential:coordinator record:record][@"password"]);
}

#pragma mark Termination

- (void)testTerminationStopsSecretsAndWaitsForIndexCleanup {
  MPAutoFillTestDocument *document = self.document;
  [self entryIn:document];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  coordinator.indexMayHoldIdentities = YES;
  NSString *record = [self entries:coordinator].firstObject[@"record"];
  __block NSUInteger finished = 0;
  [coordinator prepareForTerminationWithCompletion:^{ finished++; }];
  XCTAssertTrue(coordinator.testListening); // Retain ownership until cleanup finishes.
  XCTAssertEqual(coordinator.store.removalCount, 1U);
  XCTAssertEqual(finished, 0U);
  XCTAssertNil([self credential:coordinator record:record][@"password"]);
  XCTAssertEqual([self entries:coordinator].count, 0U);
  coordinator.store.pendingRemoval(YES, nil); [self drainMainQueue];
  XCTAssertFalse(coordinator.testListening);
  XCTAssertFalse(coordinator.indexMayHoldIdentities);
  XCTAssertEqual(finished, 1U);
  [coordinator stop];
  XCTAssertEqual(coordinator.store.removalCount, 1U); // WillTerminate starts no new store operation.
}

- (void)testTerminationWaitsForPendingPublicationBeforeClearing {
  MPAutoFillTestCoordinator *coordinator = [self publisher:@[]];
  coordinator.indexBusy = YES;
  coordinator.indexMayHoldIdentities = YES;
  __block BOOL finished = NO;
  [coordinator prepareForTerminationWithCompletion:^{ finished = YES; }];
  XCTAssertEqual(coordinator.store.removalCount, 0U);
  [coordinator didPublishIdentities:YES success:YES error:nil];
  XCTAssertEqual(coordinator.store.removalCount, 1U);
  XCTAssertFalse(finished);
  coordinator.store.pendingRemoval(YES, nil); [self drainMainQueue];
  XCTAssertTrue(finished);
  [coordinator didPublishIdentities:YES success:YES error:nil];
  XCTAssertEqual(coordinator.store.removalCount, 1U);
  XCTAssertEqual(coordinator.store.stateRequestCount, 0U); // No republication while quitting.
}

- (void)testTerminationSkipsStoreWhenNothingIsPublished {
  // A store request delays exit by ~3 s (Apple helper). A locked database
  // already replaced the published identities with an empty list.
  MPAutoFillTestCoordinator *coordinator = [self publisher:@[]];
  coordinator.indexBusy = YES;
  coordinator.indexMayHoldIdentities = YES;
  __block BOOL finished = NO;
  [coordinator prepareForTerminationWithCompletion:^{ finished = YES; }];
  XCTAssertFalse(finished);
  [coordinator didPublishIdentities:NO success:YES error:nil];
  XCTAssertTrue(finished);
  XCTAssertEqual(coordinator.store.removalCount, 0U);

  // A failed empty publication leaves the store state unknown: clear it.
  coordinator = [self publisher:@[]];
  coordinator.indexBusy = YES;
  coordinator.indexMayHoldIdentities = YES;
  finished = NO;
  [coordinator prepareForTerminationWithCompletion:^{ finished = YES; }];
  [coordinator didPublishIdentities:NO success:NO error:nil];
  XCTAssertEqual(coordinator.store.removalCount, 1U);
  coordinator.store.pendingRemoval(YES, nil); [self drainMainQueue];
  XCTAssertTrue(finished);
}

- (void)testSecondInstanceNeitherPublishesNorClearsIdentities {
  // Not listening while enabled: another MacPass instance owns the store.
  MPAutoFillTestCoordinator *coordinator = [self publisher:@[]];
  coordinator.testListening = NO; coordinator.canStart = NO;
  coordinator.indexMayHoldIdentities = YES;
  [coordinator publishIndex]; [self drainMainQueue];
  XCTAssertEqual(coordinator.store.stateRequestCount, 0U);
  XCTAssertFalse(coordinator.indexBusy);
  __block BOOL finished = NO;
  [coordinator prepareForTerminationWithCompletion:^{ finished = YES; }];
  XCTAssertTrue(finished);
  XCTAssertEqual(coordinator.store.removalCount, 0U);
}

- (void)testEnabledPreferenceIsObserved {
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[]];
  [self.defaults setBool:NO forKey:MPAutoFillEnabledPreference];
  [self drainMainQueue];
  XCTAssertFalse(coordinator.enabled);
  XCTAssertEqualObjects(coordinator.providerStatus, @"disabled");
}

#pragma mark End to end

- (MPAutoFillLoopbackController *)loopback:(MPAutoFillServer *)server {
  [server prepareForRequest];
  MPLoopbackServer = server;
  MPLoopbackOwner = self.owner;
  MPAutoFillLoopbackController *controller = [[MPAutoFillLoopbackController alloc] init];
  controller.context = [[MPAutoFillLoopbackContext alloc] init];
  controller.messages = NSMutableArray.array;
  controller.replies = NSMutableArray.array;
  [controller loadView];
  controller.appeared = YES;
  return controller;
}

- (NSArray *)exampleSite {
  return @[[[ASCredentialServiceIdentifier alloc] initWithIdentifier:@"https://example.com/login" type:ASCredentialServiceIdentifierTypeURL]];
}

- (void)waitUntil:(BOOL (^)(void))condition {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
  while(!condition() && deadline.timeIntervalSinceNow > 0) {
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  XCTAssertTrue(condition());
}

- (void)assertMessages:(MPAutoFillLoopbackController *)controller operations:(NSArray *)operations {
  XCTAssertEqualObjects([controller.messages valueForKey:@"operation"], operations);
  for(NSDictionary *message in controller.messages) XCTAssertTrue(MPAutoFillValidateRequest(message), @"%@", message);
  // Only the credential reply carries the password.
  for(NSDictionary *reply in controller.replies) {
    if(!reply[@"password"]) XCTAssertFalse([reply.description containsString:@"public-secret"]);
  }
}

- (void)testEndToEndPickerFillsTheSiteAccountAfterAuthentication {
  MPAutoFillTestDocument *document = self.document;
  [self entryIn:document];
  KPKEntry *other = [self entryIn:document];
  other.url = @"https://other.example.org"; other.username = @"other";
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  MPAutoFillLoopbackController *controller = [self loopback:coordinator];
  [controller prepareCredentialListForServiceIdentifiers:self.exampleSite];
  [self waitUntil:^BOOL{ return controller.pickerView.fillButton.enabled; }];
  // Only the requested site's account, and no password, left the host.
  NSDictionary *catalog = controller.replies.firstObject;
  XCTAssertEqualObjects(catalog[@"status"], @"ready");
  XCTAssertEqualObjects([catalog[@"entries"] valueForKey:@"user"], @[@"user"]);
  XCTAssertEqualObjects(controller.messages.firstObject[@"services"], (@[@{@"host": @"example.com", @"port": @""}]));
  [controller fill:nil];
  [self waitUntil:^BOOL{ return controller.context.credential != nil; }];
  XCTAssertEqualObjects(controller.context.credential.user, @"user");
  XCTAssertEqualObjects(controller.context.credential.password, @"public-secret");
  XCTAssertNil(controller.context.error);
  XCTAssertEqual(coordinator.grants.count, 0U);
  [self assertMessages:controller operations:@[@"catalog", @"credential"]];
}

- (void)testEndToEndPublishedSuggestionFillsAfterAuthentication {
  MPAutoFillTestDocument *document = self.document;
  [self entryIn:document];
  MPAutoFillTestCoordinator *coordinator = [self publisher:@[document]];
  [coordinator refreshCatalog]; [self drainMainQueue];
  ASPasswordCredentialIdentity *identity = coordinator.store.identities.firstObject;
  XCTAssertEqualObjects(identity.serviceIdentifier.identifier, @"example.com");
  XCTAssertEqualObjects(identity.user, @"user");
  // Safari hands the selected suggestion to the extension.
  MPAutoFillLoopbackController *controller = [self loopback:coordinator];
  [controller prepareInterfaceToProvideCredentialForIdentity:identity];
  [self waitUntil:^BOOL{ return controller.context.credential != nil; }];
  XCTAssertEqualObjects(controller.context.credential.password, @"public-secret");
  XCTAssertEqualObjects(controller.messages.firstObject[@"record"], identity.recordIdentifier);
  XCTAssertEqual(coordinator.grants.count, 0U);
  [self assertMessages:controller operations:@[@"catalog", @"credential"]];
}

- (void)testEndToEndLockedDatabaseHandsOffItsUnlock {
  MPAutoFillTestDocument *document = self.document;
  [self entryIn:document];
  document.testLocked = YES;
  MPAutoFillUnlockCoordinator *coordinator = [self configure:[[MPAutoFillUnlockCoordinator alloc] initWithDefaults:self.defaults] documents:@[document]];
  MPAutoFillLoopbackController *controller = [self loopback:coordinator];
  [controller prepareCredentialListForServiceIdentifiers:self.exampleSite];
  [self waitUntil:^BOOL{ return controller.pickerView.handoffButton.enabled; }];
  XCTAssertEqual([controller.replies.firstObject[@"entries"] count], 0U);
  [controller handoff:nil];
  [self waitUntil:^BOOL{ return controller.openedURL != nil; }];
  XCTAssertEqualObjects(controller.replies.lastObject[@"status"], @"accepted");
  XCTAssertEqualObjects(controller.openedURL.absoluteString, [MPAutoFillAppIdentifier() stringByAppendingString:@".autofill://open"]);
  XCTAssertEqual(controller.context.error.code, ASExtensionErrorCodeUserCanceled); // Safari's sheet ends first.
  XCTAssertEqual(coordinator.documentToReveal, document);
  XCTAssertEqual(coordinator.grants.count, 0U);
  [self assertMessages:controller operations:@[@"catalog", @"unlock"]];
}

- (void)testEndToEndUnlockInMacPassMakesTheVisiblePickerFillable {
  MPAutoFillTestDocument *document = self.document;
  [self entryIn:document];
  document.testLocked = YES;
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  MPAutoFillLoopbackController *controller = [self loopback:coordinator];
  [controller prepareCredentialListForServiceIdentifiers:self.exampleSite];
  [self waitUntil:^BOOL{ return controller.pickerView.handoffButton.enabled; }];
  document.testLocked = NO;
  [coordinator documentsChanged:[NSNotification notificationWithName:MPDocumentDidUnlockDatabaseNotification object:document]];
  [self waitUntil:^BOOL{ return controller.pickerView.fillButton.enabled; }];
  [controller fill:nil];
  [self waitUntil:^BOOL{ return controller.context.credential != nil; }];
  XCTAssertEqualObjects(controller.context.credential.password, @"public-secret");
  XCTAssertEqual(coordinator.grants.count, 0U); // The locked catalog's grant was cancelled.
  [self assertMessages:controller operations:@[@"catalog", @"catalog", @"credential"]];
}

- (void)testEndToEndLockBeforeCatalogDeliveryCannotRestoreMetadata {
  MPAutoFillTestDocument *document = self.document;
  [self entryIn:document];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  MPAutoFillLoopbackController *controller = [self loopback:coordinator];
  [controller prepareCredentialListForServiceIdentifiers:self.exampleSite];
  [self waitUntil:^BOOL{ return controller.pickerView.fillButton.enabled; }];
  controller.deferNextCatalog = YES;
  [controller refreshVisibleCatalog];
  [self waitUntil:^BOOL{ return controller.heldCatalogCompletion != nil; }];
  document.testLocked = YES;
  [coordinator documentsChanged:[NSNotification notificationWithName:MPDocumentDidLockDatabaseNotification object:document]];
  [self waitUntil:^BOOL{ return controller.pickerView.handoffButton.enabled; }];
  controller.heldCatalogCompletion(controller.heldCatalog);
  XCTAssertNil(controller.requestState.entries);
  XCTAssertEqual(controller.pickerView.entries.count, 0U);
  XCTAssertFalse(controller.pickerView.fillButton.enabled);
  XCTAssertEqualObjects(controller.requestState.catalogStatus, @"locked");
  controller.heldCatalogCompletion = nil; controller.heldCatalog = nil;
  [controller cancel:nil];
  [self waitUntil:^BOOL{ return coordinator.subscribers.count == 0; }];
}

- (void)testEndToEndHarmlessEditUpdatesPickerWithoutRevokingItsGrant {
  MPAutoFillTestDocument *document = self.document;
  KPKEntry *entry = [self entryIn:document];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  MPAutoFillLoopbackController *controller = [self loopback:coordinator];
  [controller prepareCredentialListForServiceIdentifiers:self.exampleSite];
  [self waitUntil:^BOOL{ return controller.pickerView.fillButton.enabled; }];
  NSString *request = controller.requestState.requestIdentifier;
  NSDictionary *grant = coordinator.grants[request];
  entry.title = @"Updated account";
  [coordinator documentsChanged:[NSNotification notificationWithName:MPAutoFillDocumentsChangedNotification object:document]];
  XCTAssertEqual(coordinator.grants[request], grant); // Before edit debounce/event delivery.
  [self waitUntil:^BOOL{ return [controller.pickerView.entries.firstObject[@"title"] isEqual:@"Updated account"]; }];
  XCTAssertFalse(controller.requestState.busy);
  [controller cancel:nil];
  [self waitUntil:^BOOL{ return coordinator.subscribers.count == 0; }];
}

- (void)testEndToEndDisconnectClearsPickerAndIdleMakesNoCatalogRequests {
  MPAutoFillTestDocument *document = self.document; [self entryIn:document];
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  MPAutoFillLoopbackController *controller = [self loopback:coordinator];
  [controller prepareCredentialListForServiceIdentifiers:self.exampleSite];
  [self waitUntil:^BOOL{ return controller.pickerView.fillButton.enabled; }];
  NSUInteger count = controller.messages.count;
  XCTestExpectation *idle = [self expectationWithDescription:@"No periodic catalog requests"];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [idle fulfill]; });
  [self waitForExpectationsWithTimeout:6 handler:nil];
  XCTAssertEqual(controller.messages.count, count);
  [coordinator stopServer];
  [self waitUntil:^BOOL{ return controller.requestState.subscription == nil; }];
  XCTAssertNil(controller.requestState.entries);
  XCTAssertEqual(controller.pickerView.table.numberOfRows, 0);
  XCTAssertFalse(controller.pickerView.fillButton.enabled);
  XCTAssertNil(controller.requestState.deadlineTimer);
  [controller cancel:nil];
}

- (void)testEndToEndShowAllListsOtherSitesAfterAuthentication {
  MPAutoFillTestDocument *document = self.document;
  [self entryIn:document];
  KPKEntry *other = [self entryIn:document];
  other.url = @"https://other.example.org"; other.username = @"other";
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  MPAutoFillLoopbackController *controller = [self loopback:coordinator];
  [controller prepareCredentialListForServiceIdentifiers:self.exampleSite];
  [self waitUntil:^BOOL{ return controller.pickerView.fillButton.enabled; }];
  XCTAssertEqual(controller.pickerView.entries.count, 1U);
  controller.pickerView.allEntriesButton.state = NSControlStateValueOn;
  [controller toggleAllEntries:controller.pickerView.allEntriesButton];
  [self waitUntil:^BOOL{ return controller.pickerView.entries.count == 2; }];
  XCTAssertEqualObjects(controller.messages.lastObject[@"scope"], @"all");
  XCTAssertEqual(coordinator.grants.count, 1U); // Only the current catalog's.
  [controller cancel:nil];
  XCTAssertEqual(coordinator.grants.count, 0U);
  [self assertMessages:controller operations:@[@"catalog", @"catalog"]];
}

// "Show all" puts the site's account first, though it sorts last, and lists 99
// others. The search in MacPass reaches another site's account behind them,
// which fills after the confirmation.
- (void)testEndToEndSearchReachesAccountsBeyondTheListedHundred {
  MPAutoFillTestDocument *document = self.document;
  for(NSUInteger index = 0; index < 120; index++) {
    KPKEntry *entry = [self entryIn:document];
    entry.title = [NSString stringWithFormat:@"Account %03lu", (unsigned long)index];
    entry.url = [NSString stringWithFormat:@"https://site%03lu.example.org", (unsigned long)index];
  }
  [self entryIn:document].title = @"Yankee site";
  KPKEntry *needle = [self entryIn:document];
  needle.title = @"Zeta needle"; needle.username = @"needle-user"; needle.url = @"https://needle.example.net";
  MPAutoFillCatalogCoordinator *coordinator = [self coordinator:@[document]];
  MPAutoFillLoopbackController *controller = [self loopback:coordinator];
  MPAutoFillConfirmingPicker *picker = [[MPAutoFillConfirmingPicker alloc] initWithDelegate:(id)controller];
  controller.pickerView = picker; controller.view = picker;
  [controller prepareCredentialListForServiceIdentifiers:self.exampleSite];
  [self waitUntil:^BOOL{ return controller.pickerView.fillButton.enabled; }];
  XCTAssertEqualObjects([controller.pickerView.entries valueForKey:@"title"], @[@"Yankee site"]);
  controller.pickerView.allEntriesButton.state = NSControlStateValueOn;
  [controller toggleAllEntries:controller.pickerView.allEntriesButton];
  [self waitUntil:^BOOL{ return controller.pickerView.entries.count == 100; }];
  NSArray *titles = [controller.pickerView.entries valueForKey:@"title"];
  XCTAssertEqualObjects(titles.firstObject, @"Yankee site");
  XCTAssertEqualObjects(titles[1], @"Account 000");
  XCTAssertEqualObjects(titles.lastObject, @"Account 098");
  XCTAssertEqualObjects(controller.pickerView.selectedEntry[@"title"], @"Yankee site"); // Return fills the site's account.
  XCTAssertEqualObjects(controller.messages.lastObject[@"services"], (@[@{@"host": @"example.com", @"port": @""}]));
  XCTAssertEqualObjects(controller.replies.lastObject[@"more"], @YES);
  XCTAssertEqual([coordinator.grants[controller.requestState.requestIdentifier][@"bindings"] count], 100U);
  XCTAssertEqualObjects(controller.pickerView.status, MPAutoFillLocalized(@"AUTOFILL_EXT_MORE", @"Not all accounts are listed. Refine the search to find the others."));
  controller.pickerView.search.stringValue = @"NEEDLE";
  [controller pickerViewQueryDidChange:controller.pickerView];
  [self waitUntil:^BOOL{ return controller.pickerView.entries.count == 1; }];
  XCTAssertEqualObjects(controller.messages.lastObject[@"query"], @"NEEDLE");
  XCTAssertEqualObjects(controller.messages.lastObject[@"scope"], @"all");
  XCTAssertNil(controller.replies.lastObject[@"more"]);
  XCTAssertEqualObjects(controller.pickerView.selectedEntry[@"title"], @"Zeta needle");
  XCTAssertEqualObjects(controller.pickerView.status, MPAutoFillLocalized(@"AUTOFILL_EXT_CHOOSE", @"Choose an account to fill from the active database."));
  [controller fill:nil];
  [self waitUntil:^BOOL{ return controller.context.credential != nil; }];
  XCTAssertEqualObjects(picker.confirmedEntry[@"title"], @"Zeta needle");
  XCTAssertEqualObjects(controller.context.credential.user, @"needle-user");
  XCTAssertEqualObjects(controller.context.credential.password, @"public-secret");
  XCTAssertEqual(coordinator.grants.count, 0U);
  [self assertMessages:controller operations:@[@"catalog", @"catalog", @"catalog", @"credential"]];
}
@end
