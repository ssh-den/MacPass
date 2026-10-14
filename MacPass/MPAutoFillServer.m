#import "MPAutoFillServer.h"
#import "../AutoFillShared/MPAutoFillTransport.h"
#import "../AutoFillShared/MPAutoFillDomain.h"
#import <AppKit/AppKit.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <unistd.h>

static const NSUInteger MPMaximumGrants = 32;
static const NSTimeInterval MPGrantLifetime = 120;
static const NSUInteger MPMaximumSubscribers = 8;
// A catalog lists at most this many accounts; the extension's search runs here,
// so every account stays reachable without sending the whole database.
static const NSUInteger MPMaximumListedEntries = 100;

@interface MPAutoFillServer ()
@property dispatch_source_t source;
// Request ID → {owner, bindings, deadline}. The owner is the caller's audit
// token, so only the requesting extension process can use or cancel a grant.
@property NSMutableDictionary<NSString *, NSDictionary *> *grants;
@property NSMutableDictionary<NSString *, MPAutoFillStream *> *subscribers;
@property BOOL stopped;
@property dispatch_semaphore_t connectionSlots;
@property ino_t socketInode;
@property dev_t socketDevice;
// MPAutoFillErrorCode of the last failed startServer, to log changes only.
@property NSInteger lastStartFailure;
@end

@implementation MPAutoFillServer

- (instancetype)init {
  if((self = [super init])) {
    _grants = NSMutableDictionary.dictionary;
    _subscribers = NSMutableDictionary.dictionary;
    _connectionSlots = dispatch_semaphore_create(4);
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(sleepForNotification:) name:NSWorkspaceWillSleepNotification object:nil];
  }
  return self;
}

- (BOOL)isListening { return self.source != nil; }

- (BOOL)startServer {
  if(self.stopped) return NO;
  if(self.source) return YES;
  NSError *error = nil;
  int listener = MPAutoFillCreateListener(&error);
  if(listener < 0) {
    // Attempted again on later changes while another instance listens; log changes only.
    if(error.code != self.lastStartFailure) MPAutoFillLogError(@"listener", error);
    self.lastStartFailure = error.code;
    return NO;
  }
  self.lastStartFailure = 0;
  NSURL *url = MPAutoFillSocketURL(NULL);
  struct stat info;
  if(url && lstat(url.fileSystemRepresentation, &info) == 0) { self.socketInode = info.st_ino; self.socketDevice = info.st_dev; }
  self.source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, listener, 0, dispatch_get_main_queue());
  __weak MPAutoFillServer *weakSelf = self;
  dispatch_source_set_event_handler(self.source, ^{ [weakSelf acceptConnectionOn:listener]; });
  dispatch_source_set_cancel_handler(self.source, ^{ close(listener); });
  dispatch_resume(self.source);
  return YES;
}

- (void)stopServer {
  [self invalidateGrants];
  for(MPAutoFillStream *stream in self.subscribers.allValues) [stream close];
  [self.subscribers removeAllObjects];
  if(!self.source) return;
  dispatch_source_cancel(self.source);
  self.source = nil;
  // Remove only the socket this instance bound, never a successor's.
  NSURL *url = MPAutoFillSocketURL(NULL);
  struct stat info;
  if(url && lstat(url.fileSystemRepresentation, &info) == 0 && S_ISSOCK(info.st_mode) &&
     info.st_ino == self.socketInode && info.st_dev == self.socketDevice) unlink(url.fileSystemRepresentation);
}

- (void)stop {
  if(self.stopped) return;
  self.stopped = YES;
  [self stopServer];
}

- (void)acceptConnectionOn:(int)listener {
  int fd = accept(listener, NULL, NULL);
  if(fd < 0) return;
  dispatch_semaphore_t slots = self.connectionSlots;
  if(dispatch_semaphore_wait(slots, DISPATCH_TIME_NOW) != 0) { close(fd); return; }
  MPAutoFillConfigureSocket(fd);
  __weak MPAutoFillServer *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      NSError *error = nil;
      NSData *owner = nil;
      __block BOOL subscribed = NO;
      if(MPAutoFillValidatePeer(fd, [MPAutoFillAppIdentifier() stringByAppendingString:@".AutoFill"], YES, &owner, &error)) {
        NSDictionary *message = MPAutoFillReadMessage(fd, &error);
        if(MPAutoFillValidateRequest(message)) {
          if([message[@"operation"] isEqual:MPAutoFillOperationSubscribe]) {
            dispatch_sync(dispatch_get_main_queue(), ^{ subscribed = [weakSelf subscribeRequest:message[@"request"] socket:fd]; });
          }
          else [weakSelf answerMessage:message owner:owner socket:fd error:&error];
        }
      }
      // Another MacPass instance probes the listener before binding its own;
      // an extension that rejected this host closes without a message.
      BOOL expected = error.code == MPAutoFillErrorClosed ||
        (error.code == MPAutoFillErrorPeerRejected && MPAutoFillValidatePeer(fd, MPAutoFillAppIdentifier(), NO, NULL, NULL));
      if(!expected) MPAutoFillLogError(@"IPC", error);
      if(!subscribed) close(fd);
      dispatch_semaphore_signal(slots);
    }
  });
}

// The validated connection transfers to a separately bounded stream, freeing
// its transient worker/slot. Registration precedes the acknowledgement.
- (BOOL)subscribeRequest:(NSString *)request socket:(int)fd {
  if(self.stopped || !self.isListening || self.subscribers[request] || self.subscribers.count >= MPMaximumSubscribers) return NO;
  MPAutoFillStream *stream = [[MPAutoFillStream alloc] initWithSocket:fd];
  self.subscribers[request] = stream;
  __weak MPAutoFillServer *weakSelf = self;
  __weak MPAutoFillStream *weakStream = stream;
  [stream startWithMessageHandler:^(NSDictionary *message) {
    // There are no client messages after registration; EOF is unsubscribe.
    [weakStream close];
  } closeHandler:^{
    if(weakSelf.subscribers[request] == weakStream) [weakSelf.subscribers removeObjectForKey:request];
  }];
  [stream sendMessage:@{@"version": @1, @"request": request, @"status": MPAutoFillStatusSubscribed}];
  return YES;
}

- (void)sendEvent:(NSString *)event {
  for(NSString *request in self.subscribers.allKeys) {
    [self.subscribers[request] sendMessage:@{@"version": @1, @"request": request, @"event": event}];
  }
}

// Runs on a worker queue for a validated peer; the reply is built on the main queue.
- (void)answerMessage:(NSDictionary *)message owner:(NSData *)owner socket:(int)fd error:(NSError **)error {
  NSString *request = message[@"request"];
  __block NSDictionary *reply = nil;
  __block NSDictionary *grant = nil;
  __block NSData *frame = nil;
  __block NSUInteger sent = 0;
  dispatch_sync(dispatch_get_main_queue(), ^{
    reply = [self replyToMessage:message owner:owner];
    if([message[@"operation"] isEqual:MPAutoFillOperationCatalog] && MPAutoFillStatusIssuesGrant(reply[@"status"])) grant = self.grants[request];
    // A password is handed to the kernel in the same main-queue operation
    // that checked the live entry, so no lock or close can come between.
    // Never wait for the reader here: a password reply fits the empty
    // socket buffer, and any rest continues below as already issued.
    if(reply[@"password"]) {
      frame = MPAutoFillEncodeMessage(reply, NULL);
      ssize_t count = frame ? send(fd, frame.bytes, frame.length, MSG_DONTWAIT) : -1;
      sent = count > 0 ? (NSUInteger)count : 0;
    }
  });
  // Other replies (catalogs up to the frame limit) are encoded and written
  // here, so a slow reader cannot stall the main queue.
  if(!frame) frame = MPAutoFillEncodeMessage(reply, error);
  // A catalog over the frame limit is answered without entries or a grant.
  if(!frame && grant) {
    [self revokeGrant:grant request:request];
    grant = nil;
    frame = MPAutoFillEncodeMessage(@{@"version": @1, @"request": request, @"status": MPAutoFillStatusTooLarge}, NULL);
  }
  // The extension never learnt of a grant it did not receive.
  if(frame && !MPAutoFillWriteFrame(fd, frame, sent, error) && grant) [self revokeGrant:grant request:request];
}

// Only that grant: a later catalog of the same request may have replaced it.
- (void)revokeGrant:(NSDictionary *)grant request:(NSString *)request {
  dispatch_async(dispatch_get_main_queue(), ^{
    if(self.grants[request] == grant) [self.grants removeObjectForKey:request];
  });
}

// more: the scope and query match further accounts than are listed.
- (NSArray<NSDictionary *> *)entriesForCatalogMessage:(NSDictionary *)message more:(BOOL *)more {
  NSString *record = message[@"record"], *query = message[@"query"];
  BOOL all = [message[@"scope"] isEqual:@"all"];
  NSArray *services = message[@"services"];
  // Listing order: the requesting sites' accounts, then the rest of "all";
  // within both, titles that begin with the query first. Otherwise catalog order.
  NSArray<NSMutableArray *> *parts = @[NSMutableArray.array, NSMutableArray.array, NSMutableArray.array, NSMutableArray.array];
  for(NSDictionary *entry in [self catalogEntries]) {
    if(record) { if([entry[@"record"] isEqual:record]) [parts[0] addObject:entry]; continue; }
    // Without a selected record or an authenticated "all" scope, only accounts
    // for the requesting site leave the host. A query only narrows the scope.
    if(!MPAutoFillEntryMatchesQuery(entry, query)) continue;
    BOOL site = MPAutoFillEntryMatchesServices(entry, services);
    if(!site && !all) continue;
    [parts[(site ? 0 : 2) + (MPAutoFillEntryBeginsWithQuery(entry, query) ? 0 : 1)] addObject:entry];
  }
  NSMutableArray *entries = NSMutableArray.array;
  for(NSArray *part in parts) [entries addObjectsFromArray:part];
  *more = entries.count > MPMaximumListedEntries;
  return *more ? [entries subarrayWithRange:NSMakeRange(0, MPMaximumListedEntries)] : entries;
}

- (NSDictionary *)replyToMessage:(NSDictionary *)message owner:(NSData *)owner {
  NSString *request = message[@"request"];
  NSMutableDictionary *reply = [@{@"version": @1, @"request": request, @"status": MPAutoFillStatusUnavailable} mutableCopy];
  if(self.stopped) return reply;
  [self prepareForRequest];
  NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  for(NSString *key in self.grants.allKeys) {
    if([self.grants[key][@"deadline"] doubleValue] < now) [self.grants removeObjectForKey:key];
  }
  NSString *operation = message[@"operation"];
  NSDictionary *grant = self.grants[request];
  // Request IDs are random and never leave the extension; another process
  // cannot use or replace a grant bound to a different audit token.
  if(grant && ![grant[@"owner"] isEqual:owner]) return reply;
  if([operation isEqual:MPAutoFillOperationCatalog]) {
    if(!grant && self.grants.count >= MPMaximumGrants) return reply;
    NSString *status = [self providerStatus];
    reply[@"status"] = status;
    if(!MPAutoFillStatusIssuesGrant(status)) { [self.grants removeObjectForKey:request]; return reply; }
    // Locked databases expose no metadata at all.
    BOOL more = NO;
    NSArray *entries = [status isEqual:MPAutoFillStatusReady] ? [self entriesForCatalogMessage:message more:&more] : @[];
    NSMutableDictionary *bindings = NSMutableDictionary.dictionary;
    for(NSDictionary *entry in entries) bindings[entry[@"record"]] = @{@"host": entry[@"host"], @"port": entry[@"port"] ?: @"", @"user": entry[@"user"]};
    self.grants[request] = @{@"owner": owner, @"bindings": bindings, @"deadline": @(now + MPGrantLifetime)};
    reply[@"entries"] = entries;
    if(more) reply[@"more"] = @YES;
    reply[@"deadline"] = self.grants[request][@"deadline"];
    return reply;
  }
  if(!grant) return reply;
  [self.grants removeObjectForKey:request]; // Every grant is consumed exactly once.
  if([operation isEqual:MPAutoFillOperationCredential]) {
    NSDictionary *binding = grant[@"bindings"][message[@"record"]];
    if(binding) [reply addEntriesFromDictionary:[self credentialForRecord:message[@"record"] expecting:binding]];
  }
  else if([operation isEqual:MPAutoFillOperationUnlock]) reply[@"status"] = [self requestUnlock] ? MPAutoFillStatusAccepted : MPAutoFillStatusUnavailable;
  else if([operation isEqual:MPAutoFillOperationCancel]) reply[@"status"] = MPAutoFillStatusCancelled;
  return reply;
}

- (void)prepareForRequest {}
- (NSString *)providerStatus { return MPAutoFillStatusDisabled; }
- (NSArray<NSDictionary *> *)catalogEntries { return @[]; }
- (NSDictionary *)credentialForRecord:(NSString *)record expecting:(NSDictionary *)binding { return @{@"status": MPAutoFillStatusUnavailable}; }
- (BOOL)requestUnlock { return NO; }

- (void)invalidateGrants { [self.grants removeAllObjects]; [self sendEvent:MPAutoFillEventInvalidate]; }
- (void)catalogDidChange { [self sendEvent:MPAutoFillEventCatalogChanged]; }
- (void)sleepForNotification:(NSNotification *)notification {
  if(NSThread.isMainThread) [self invalidateGrants];
  else dispatch_async(dispatch_get_main_queue(), ^{ [self invalidateGrants]; });
}

- (void)dealloc {
  if(_source) dispatch_source_cancel(_source);
  for(MPAutoFillStream *stream in _subscribers.allValues) [stream close];
  [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}
@end
