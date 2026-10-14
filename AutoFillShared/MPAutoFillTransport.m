#import "MPAutoFillTransport.h"
#import <Security/Security.h>
#import <bsm/audit.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#import <arpa/inet.h>
#import <string.h>
#import <CommonCrypto/CommonDigest.h>

NSString *const MPAutoFillErrorDomain = @"com.macpass.autofill.transport";
NSString *const MPAutoFillOperationCatalog = @"catalog";
NSString *const MPAutoFillOperationCredential = @"credential";
NSString *const MPAutoFillOperationCancel = @"cancel";
NSString *const MPAutoFillOperationUnlock = @"unlock";
NSString *const MPAutoFillOperationSubscribe = @"subscribe";
NSString *const MPAutoFillStatusReady = @"ready";
NSString *const MPAutoFillStatusLocked = @"locked";
NSString *const MPAutoFillStatusConflict = @"conflict";
NSString *const MPAutoFillStatusDisabled = @"disabled";
NSString *const MPAutoFillStatusNoDocuments = @"noDocuments";
NSString *const MPAutoFillStatusTooLarge = @"tooLarge";
NSString *const MPAutoFillStatusStale = @"stale";
NSString *const MPAutoFillStatusUnavailable = @"unavailable";
NSString *const MPAutoFillStatusAccepted = @"accepted";
NSString *const MPAutoFillStatusCancelled = @"cancelled";
NSString *const MPAutoFillStatusSubscribed = @"subscribed";
NSString *const MPAutoFillEventInvalidate = @"invalidate";
NSString *const MPAutoFillEventCatalogChanged = @"catalogChanged";
const NSUInteger MPAutoFillMaximumQueryLength = 256;
static const NSUInteger MPMaximumFrameLength = 1024 * 1024;
static const NSTimeInterval MPTransferTimeout = 5;

static BOOL MPFail(NSError **error, MPAutoFillErrorCode code) {
  if(error) *error = [NSError errorWithDomain:MPAutoFillErrorDomain code:code userInfo:nil];
  return NO;
}

void MPAutoFillLogError(NSString *context, NSError *error) {
  if(!error) return;
  NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
  NSLog(@"AutoFill %@ failed: %ld; phase: %@; underlying: %ld", context, (long)error.code,
        error.userInfo[@"phase"] ?: @"transport", (long)underlying.code);
}

NSString *MPAutoFillAppIdentifier(void) {
  // The extension names its containing app in its Info.plist; the app is the main bundle.
  id identifier = [NSBundle.mainBundle objectForInfoDictionaryKey:@"MPAutoFillAppIdentifier"];
  if([identifier isKindOfClass:NSString.class]) return identifier;
  return NSBundle.mainBundle.bundleIdentifier ?: @"";
}

BOOL MPAutoFillStatusIssuesGrant(id status) {
  return [status isEqual:MPAutoFillStatusReady] || [status isEqual:MPAutoFillStatusLocked];
}

static NSString *MPTeamIdentifier(void) {
  id team = [NSBundle.mainBundle objectForInfoDictionaryKey:@"MPAutoFillTeamIdentifier"];
  return [team isKindOfClass:NSString.class] ? team : @"";
}

NSURL *MPAutoFillSocketURL(NSError **error) {
  NSString *team = MPTeamIdentifier();
  NSData *identifier = [MPAutoFillAppIdentifier() dataUsingEncoding:NSUTF8StringEncoding];
  if(team.length != 10 || identifier.length == 0) { MPFail(error, MPAutoFillErrorConfiguration); return nil; }
  NSString *group = [team stringByAppendingString:@".MacPass.AutoFill"];
  NSURL *container = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
  // Builds with other bundle identifiers share the team's container but not the
  // socket, so none replaces another's listener. A digest fits sun_path.
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(identifier.bytes, (CC_LONG)identifier.length, digest);
  NSMutableString *name = [NSMutableString stringWithString:@"af-"];
  for(NSUInteger index = 0; index < 6; index++) [name appendFormat:@"%02x", digest[index]];
  NSURL *url = [container URLByAppendingPathComponent:[name stringByAppendingString:@".sock"]];
  if(!url || strlen(url.fileSystemRepresentation) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
    MPFail(error, MPAutoFillErrorSocketPath); return nil;
  }
  return url;
}

// A valid signature does not protect a process that others can debug or inject
// code into: require the hardened runtime, no get-task-allow and no debugger.
static OSStatus MPCheckHardening(SecCodeRef code) {
  CFDictionaryRef information = NULL;
  OSStatus status = SecCodeCopySigningInformation((SecStaticCodeRef)code, kSecCSDynamicInformation | kSecCSRequirementInformation, &information);
  if(status != errSecSuccess) return status;
  NSDictionary *info = CFBridgingRelease(information);
  uint32_t flags = [info[(__bridge NSString *)kSecCodeInfoFlags] unsignedIntValue];
  uint32_t dynamicStatus = [info[(__bridge NSString *)kSecCodeInfoStatus] unsignedIntValue];
  NSDictionary *entitlements = info[(__bridge NSString *)kSecCodeInfoEntitlementsDict];
  BOOL debuggable = [entitlements isKindOfClass:NSDictionary.class] && [entitlements[@"com.apple.security.get-task-allow"] boolValue];
  if(!(flags & kSecCodeSignatureRuntime) || (dynamicStatus & kSecCodeStatusDebugged) || debuggable) return errSecCSReqFailed;
  return errSecSuccess;
}

BOOL MPAutoFillValidatePeer(int fd, NSString *identifier, BOOL hardened, NSData **token, NSError **error) {
  // Use the kernel's connection-bound identity; never validate a reusable PID.
  audit_token_t audit;
  socklen_t size = sizeof(audit);
  uid_t uid; gid_t gid;
  if(getpeereid(fd, &uid, &gid) != 0 || uid != geteuid() ||
     getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &audit, &size) != 0 || size != sizeof(audit)) {
    return MPFail(error, MPAutoFillErrorPeerRejected);
  }
  NSString *team = MPTeamIdentifier();
  // The requirement is built from a string: allow no quotes or other syntax.
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
  if(team.length != 10 || identifier.length == 0 ||
     [team rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound ||
     [identifier rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return MPFail(error, MPAutoFillErrorPeerRejected);
  NSData *data = [NSData dataWithBytes:&audit length:sizeof(audit)];
  SecCodeRef code = NULL;
  SecRequirementRef requirement = NULL;
  // With an audit token, the dynamic-code attribute makes Security take the
  // peer's signature from the kernel (the one it loaded and enforces) instead
  // of the executable on disk, which the sandboxed extension may not be able to
  // read. The flag's value is ours, not peer-supplied; the requirement below
  // still decides. Verify rejection on a signed build (see MacPassAutoFill/README.md).
  NSDictionary *attributes = @{
    (__bridge NSString *)kSecGuestAttributeAudit: data,
    (__bridge NSString *)kSecGuestAttributeDynamicCode: @YES
  };
  NSString *phase = @"locate-peer";
  OSStatus status = SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code);
  NSString *expression = [NSString stringWithFormat:@"anchor apple generic and identifier \"%@\" and certificate leaf[subject.OU] = \"%@\"", identifier, team];
  if(status == errSecSuccess) {
    phase = @"create-requirement";
    status = SecRequirementCreateWithString((__bridge CFStringRef)expression, kSecCSDefaultFlags, &requirement);
  }
  if(status == errSecSuccess) {
    phase = @"validate-peer";
    status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
  }
  if(status == errSecSuccess && hardened) {
    phase = @"hardened-runtime";
    status = MPCheckHardening(code);
  }
  if(requirement) CFRelease(requirement);
  if(code) CFRelease(code);
  if(status != errSecSuccess) {
    if(error) *error = [NSError errorWithDomain:MPAutoFillErrorDomain code:MPAutoFillErrorPeerRejected userInfo:@{
      @"phase": phase, NSUnderlyingErrorKey: [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil]
    }];
    return NO;
  }
  if(token) *token = data;
  return YES;
}

void MPAutoFillConfigureSocket(int fd) {
  struct timeval timeout = {(time_t)MPTransferTimeout, 0};
  int enabled = 1;
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
  fcntl(fd, F_SETFD, FD_CLOEXEC);
  // Accepted sockets inherit the listener's O_NONBLOCK; transfers block with a timeout.
  int flags = fcntl(fd, F_GETFL);
  if(flags >= 0) fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
}

static BOOL MPTransfer(int fd, void *buffer, size_t length, BOOL writing, NSError **error) {
  uint8_t *cursor = buffer;
  NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + MPTransferTimeout;
  while(length) {
    NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
    // A zero timeval disables the socket timeout; never round down to it.
    if(remaining < 0.001) return MPFail(error, MPAutoFillErrorTransport);
    struct timeval timeout = {(time_t)remaining, (suseconds_t)((remaining - (time_t)remaining) * 1000000)};
    setsockopt(fd, SOL_SOCKET, writing ? SO_SNDTIMEO : SO_RCVTIMEO, &timeout, sizeof(timeout));
    ssize_t count = writing ? send(fd, cursor, length, 0) : recv(fd, cursor, length, 0);
    if(count < 0 && errno == EINTR) continue;
    if(count == 0 && !writing && cursor == buffer) return MPFail(error, MPAutoFillErrorClosed);
    if(count <= 0) return MPFail(error, MPAutoFillErrorTransport);
    cursor += count;
    length -= (size_t)count;
  }
  return YES;
}

static NSDictionary *MPDecodeMessage(NSData *data, NSError **error) {
  id message = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
  if(![message isKindOfClass:NSDictionary.class]) { MPFail(error, MPAutoFillErrorMessage); return nil; }
  return message;
}

NSDictionary *MPAutoFillReadMessage(int fd, NSError **error) {
  uint32_t header;
  if(!MPTransfer(fd, &header, sizeof(header), NO, error)) return nil;
  NSUInteger length = ntohl(header);
  if(length == 0 || length > MPMaximumFrameLength) { MPFail(error, MPAutoFillErrorMessage); return nil; }
  NSMutableData *data = [NSMutableData dataWithLength:length];
  // Only an empty connection counts as closed; a cut-off frame is a transport error.
  if(!MPTransfer(fd, data.mutableBytes, length, NO, error)) { MPFail(error, MPAutoFillErrorTransport); return nil; }
  return MPDecodeMessage(data, error);
}

NSData *MPAutoFillEncodeMessage(NSDictionary *message, NSError **error) {
  NSData *encoded = [NSPropertyListSerialization dataWithPropertyList:message format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
  if(!encoded || encoded.length == 0 || encoded.length > MPMaximumFrameLength) { MPFail(error, MPAutoFillErrorMessage); return nil; }
  uint32_t header = htonl((uint32_t)encoded.length);
  NSMutableData *frame = [NSMutableData dataWithBytes:&header length:sizeof(header)];
  [frame appendData:encoded];
  return frame;
}

BOOL MPAutoFillWriteFrame(int fd, NSData *frame, NSUInteger offset, NSError **error) {
  if(offset > frame.length) return MPFail(error, MPAutoFillErrorTransport);
  return MPTransfer(fd, (uint8_t *)frame.bytes + offset, frame.length - offset, YES, error);
}

BOOL MPAutoFillWriteMessage(int fd, NSDictionary *message, NSError **error) {
  NSData *frame = MPAutoFillEncodeMessage(message, error);
  return frame && MPAutoFillWriteFrame(fd, frame, 0, error);
}

BOOL MPAutoFillValidateRequest(NSDictionary *message) {
  if(![message isKindOfClass:NSDictionary.class] || ![message[@"version"] isKindOfClass:NSNumber.class] ||
     ![message[@"version"] isEqual:@1] || ![message[@"request"] isKindOfClass:NSString.class] ||
     ![[NSUUID alloc] initWithUUIDString:message[@"request"]] || ![message[@"operation"] isKindOfClass:NSString.class]) return NO;
  NSString *operation = message[@"operation"];
  if(![@[MPAutoFillOperationCatalog, MPAutoFillOperationCredential, MPAutoFillOperationCancel, MPAutoFillOperationUnlock,
         MPAutoFillOperationSubscribe] containsObject:operation]) return NO;
  id record = message[@"record"], scope = message[@"scope"], services = message[@"services"], query = message[@"query"];
  BOOL validRecord = [record isKindOfClass:NSString.class] && [record length] > 0 && [record length] <= 512;
  if([operation isEqual:MPAutoFillOperationCredential]) return validRecord && !scope && !services && !query;
  if(![operation isEqual:MPAutoFillOperationCatalog]) return !record && !scope && !services && !query;
  // A catalog names one scope: a selected record, the requesting services or all
  // entries. Next to "all", services only put those sites' accounts first.
  if(record && (scope || services)) return NO;
  if(record && !validRecord) return NO;
  // A search only narrows a list; a selected record is never searched.
  if(query && (record || ![query isKindOfClass:NSString.class] || [query length] == 0 || [query length] > MPAutoFillMaximumQueryLength)) return NO;
  if(scope && ![scope isEqual:@"all"]) return NO;
  if(services) {
    if(![services isKindOfClass:NSArray.class] || [services count] > 16) return NO;
    NSCharacterSet *digits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
    for(NSDictionary *service in services) {
      if(![service isKindOfClass:NSDictionary.class] || ![service[@"host"] isKindOfClass:NSString.class] ||
         [service[@"host"] length] == 0 || [service[@"host"] length] > 253 || ![service[@"port"] isKindOfClass:NSString.class] ||
         [service[@"port"] length] > 5 || [service[@"port"] rangeOfCharacterFromSet:digits.invertedSet].location != NSNotFound) return NO;
      if([service[@"port"] length] && ([service[@"port"] integerValue] <= 0 || [service[@"port"] integerValue] > 65535)) return NO;
    }
  }
  return YES;
}

static BOOL MPAddress(struct sockaddr_un *address, NSError **error) {
  NSURL *url = MPAutoFillSocketURL(error);
  if(!url) return NO;
  memset(address, 0, sizeof(*address));
  address->sun_family = AF_UNIX;
  strlcpy(address->sun_path, url.fileSystemRepresentation, sizeof(address->sun_path));
  address->sun_len = (unsigned char)SUN_LEN(address);
  return YES;
}

static int MPConnect(NSError **error) {
  struct sockaddr_un address;
  if(!MPAddress(&address, error)) return -1;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if(fd < 0) { MPFail(error, MPAutoFillErrorTransport); return -1; }
  MPAutoFillConfigureSocket(fd);
  if(connect(fd, (struct sockaddr *)&address, address.sun_len) != 0) {
    // No listener: MacPass is not running or AutoFill is disabled there.
    MPFail(error, (errno == ECONNREFUSED || errno == ENOENT) ? MPAutoFillErrorNoListener : MPAutoFillErrorTransport);
  }
  else if(MPAutoFillValidatePeer(fd, MPAutoFillAppIdentifier(), NO, NULL, error)) return fd;
  close(fd);
  return -1;
}

NSDictionary *MPAutoFillExchange(NSDictionary *message, NSError **error) {
  if(!MPAutoFillValidateRequest(message)) return nil;
  int fd = MPConnect(error);
  if(fd < 0) return nil;
  NSDictionary *reply = nil;
  if(MPAutoFillWriteMessage(fd, message, error)) {
    reply = MPAutoFillReadMessage(fd, error);
    // A failed read keeps its own code, e.g. a host that closed without replying.
    if(reply && (![reply[@"version"] isEqual:@1] || ![reply[@"request"] isEqual:message[@"request"]])) {
      MPFail(error, MPAutoFillErrorMessage); reply = nil;
    }
  }
  else if(error && !*error) MPFail(error, MPAutoFillErrorTransport);
  close(fd);
  return reply;
}

MPAutoFillStream *MPAutoFillSubscribe(NSString *request, NSError **error) {
  NSDictionary *message = @{@"version": @1, @"request": request, @"operation": MPAutoFillOperationSubscribe};
  if(!MPAutoFillValidateRequest(message)) return nil;
  int fd = MPConnect(error);
  if(fd < 0) return nil;
  NSDictionary *reply = MPAutoFillWriteMessage(fd, message, error) ? MPAutoFillReadMessage(fd, error) : nil;
  if([reply[@"version"] isEqual:@1] && [reply[@"request"] isEqual:request] && [reply[@"status"] isEqual:MPAutoFillStatusSubscribed]) {
    return [[MPAutoFillStream alloc] initWithSocket:fd];
  }
  if(reply) MPFail(error, MPAutoFillErrorMessage);
  close(fd);
  return nil;
}

int MPAutoFillCreateListener(NSError **error) {
  struct sockaddr_un address;
  if(!MPAddress(&address, error)) return -1;
  // Do not replace another running MacPass instance's listener or follow a
  // symlink. A stale socket, or one bound by any other process, is replaced.
  struct stat existing;
  if(lstat(address.sun_path, &existing) == 0) {
    if(!S_ISSOCK(existing.st_mode) || existing.st_uid != geteuid()) { MPFail(error, MPAutoFillErrorListenerOccupied); return -1; }
    int check = socket(AF_UNIX, SOCK_STREAM, 0);
    if(check < 0) { MPFail(error, MPAutoFillErrorTransport); return -1; }
    MPAutoFillConfigureSocket(check);
    BOOL live = connect(check, (struct sockaddr *)&address, address.sun_len) == 0;
    int savedError = errno;
    // The listening instance recognizes this probe and does not log it.
    BOOL legitimate = live && MPAutoFillValidatePeer(check, MPAutoFillAppIdentifier(), NO, NULL, NULL);
    close(check);
    if(legitimate || (!live && savedError != ECONNREFUSED)) { MPFail(error, MPAutoFillErrorListenerOccupied); return -1; }
    if(unlink(address.sun_path) != 0) { MPFail(error, MPAutoFillErrorListenerOccupied); return -1; }
  }
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if(fd < 0) { MPFail(error, MPAutoFillErrorTransport); return -1; }
  MPAutoFillConfigureSocket(fd);
  // A full backlog refuses connections, which the extension would take for a
  // missing host; excess connections are closed by the server's slot limit instead.
  if(bind(fd, (struct sockaddr *)&address, address.sun_len) != 0 || chmod(address.sun_path, 0600) != 0 || listen(fd, SOMAXCONN) != 0) {
    close(fd); MPFail(error, MPAutoFillErrorTransport); return -1;
  }
  int flags = fcntl(fd, F_GETFL);
  if(flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  return fd;
}

@interface MPAutoFillStream () {
  int _socket;
  dispatch_queue_t _queue;
  dispatch_source_t _reader, _writer, _deadline;
  // Descriptor sources not yet past their cancel handler.
  dispatch_group_t _sources;
  NSMutableData *_input, *_output;
  NSUInteger _outputOffset;
  NSUInteger _pendingMessages;
  NSTimeInterval _readDeadline, _writeDeadline;
  BOOL _closed, _started;
  void (^_messageHandler)(NSDictionary *);
  void (^_closeHandler)(void);
}
@end

@implementation MPAutoFillStream

- (instancetype)initWithSocket:(int)socket {
  if((self = [super init])) {
    _socket = socket;
    _queue = dispatch_queue_create("com.macpass.autofill.stream", DISPATCH_QUEUE_SERIAL);
    _sources = dispatch_group_create();
    _input = NSMutableData.data;
    _output = NSMutableData.data;
    MPAutoFillConfigureSocket(socket);
    int flags = fcntl(socket, F_GETFL);
    if(flags < 0 || fcntl(socket, F_SETFL, flags | O_NONBLOCK) < 0) { close(socket); _socket = -1; }
  }
  return self;
}

- (void)startWithMessageHandler:(void (^)(NSDictionary *))messageHandler closeHandler:(void (^)(void))closeHandler {
  dispatch_async(_queue, ^{
    if(self->_closed || self->_started) return;
    self->_started = YES;
    self->_messageHandler = [messageHandler copy];
    self->_closeHandler = [closeHandler copy];
    if(self->_socket < 0) { [self closeOnQueue]; return; }
    __weak MPAutoFillStream *weakSelf = self;
    int fd = self->_socket;
    self->_reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, self->_queue);
    dispatch_source_set_event_handler(self->_reader, ^{ [weakSelf readAvailable]; });
    [self trackSource:self->_reader];
    dispatch_resume(self->_reader);
    self->_deadline = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
    dispatch_source_set_event_handler(self->_deadline, ^{ [weakSelf checkDeadline]; });
    dispatch_source_set_timer(self->_deadline, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(self->_deadline);
  });
}

- (void)checkDeadline {
  if(_closed) return;
  NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if((_readDeadline && _readDeadline <= now) || (_writeDeadline && _writeDeadline <= now)) [self closeOnQueue];
  else [self updateDeadline]; // A queued timer event may belong to an already completed transfer.
}

- (void)updateDeadline {
  NSTimeInterval due = _readDeadline && _writeDeadline ? MIN(_readDeadline, _writeDeadline) : MAX(_readDeadline, _writeDeadline);
  dispatch_source_set_timer(_deadline, due ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, due - NSProcessInfo.processInfo.systemUptime) * NSEC_PER_SEC)) : DISPATCH_TIME_FOREVER,
                           DISPATCH_TIME_FOREVER, 0);
}

- (void)readAvailable {
  if(_closed) return;
  uint8_t bytes[4096];
  // Bound work per dispatch so a busy peer cannot monopolize this queue.
  for(NSUInteger reads = 0; reads < 16; reads++) {
    ssize_t count = recv(_socket, bytes, sizeof(bytes), 0);
    if(count < 0 && errno == EINTR) continue;
    if(count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
    if(count <= 0) { [self closeOnQueue]; return; }
    if(!_input.length) _readDeadline = NSProcessInfo.processInfo.systemUptime + MPTransferTimeout;
    [_input appendBytes:bytes length:(NSUInteger)count];
    while(_input.length >= sizeof(uint32_t)) {
      uint32_t header; memcpy(&header, _input.bytes, sizeof(header));
      NSUInteger length = ntohl(header);
      if(!length || length > MPMaximumFrameLength) { [self closeOnQueue]; return; }
      if(_input.length < sizeof(header) + length) break;
      NSDictionary *message = MPDecodeMessage([_input subdataWithRange:NSMakeRange(sizeof(header), length)], NULL);
      if(!message || _pendingMessages >= 32) { [self closeOnQueue]; return; }
      [_input replaceBytesInRange:NSMakeRange(0, sizeof(header) + length) withBytes:NULL length:0];
      void (^handler)(NSDictionary *) = _messageHandler;
      _pendingMessages++;
      __weak MPAutoFillStream *weakSelf = self;
      dispatch_queue_t queue = _queue;
      dispatch_async(dispatch_get_main_queue(), ^{
        if(handler) handler(message);
        dispatch_async(queue, ^{
          MPAutoFillStream *stream = weakSelf;
          if(stream) stream->_pendingMessages--;
        });
      });
      _readDeadline = _input.length ? NSProcessInfo.processInfo.systemUptime + MPTransferTimeout : 0;
    }
  }
  [self updateDeadline];
}

- (void)sendMessage:(NSDictionary *)message {
  dispatch_async(_queue, ^{
    if(self->_closed || !self->_started) return;
    NSData *frame = MPAutoFillEncodeMessage(message, NULL);
    NSUInteger pending = self->_output.length - self->_outputOffset;
    if(!frame || pending + frame.length > MPMaximumFrameLength + sizeof(uint32_t)) { [self closeOnQueue]; return; }
    if(self->_outputOffset) {
      [self->_output replaceBytesInRange:NSMakeRange(0, self->_outputOffset) withBytes:NULL length:0];
      self->_outputOffset = 0;
    }
    if(!pending) self->_writeDeadline = NSProcessInfo.processInfo.systemUptime + MPTransferTimeout;
    [self->_output appendData:frame];
    [self writeAvailable];
    if(self->_output.length && !self->_writer && !self->_closed) {
      self->_writer = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, self->_socket, 0, self->_queue);
      __weak MPAutoFillStream *weakSelf = self;
      dispatch_source_set_event_handler(self->_writer, ^{ [weakSelf writeAvailable]; });
      [self trackSource:self->_writer];
      dispatch_resume(self->_writer);
    }
  });
}

- (void)writeAvailable {
  if(_closed) return;
  while(_outputOffset < _output.length) {
    ssize_t count = send(_socket, (const uint8_t *)_output.bytes + _outputOffset, _output.length - _outputOffset, 0);
    if(count < 0 && errno == EINTR) continue;
    if(count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
    if(count <= 0) { [self closeOnQueue]; return; }
    _outputOffset += (NSUInteger)count;
  }
  if(_outputOffset == _output.length) {
    _output.length = 0; _outputOffset = 0; _writeDeadline = 0;
    if(_writer) { dispatch_source_cancel(_writer); _writer = nil; }
  }
  [self updateDeadline];
}

- (void)close { dispatch_async(_queue, ^{ [self closeOnQueue]; }); }

- (void)closeOnQueue {
  if(_closed) return;
  _closed = YES;
  [self releaseIO];
  _input.length = 0; _output.length = 0;
  void (^handler)(void) = _closeHandler;
  _closeHandler = nil; _messageHandler = nil;
  dispatch_async(dispatch_get_main_queue(), ^{ if(handler) handler(); });
}

// libdispatch requires a descriptor to stay open until every source that
// monitored it has run its cancel handler.
- (void)trackSource:(dispatch_source_t)source {
  dispatch_group_t sources = _sources;
  dispatch_group_enter(sources);
  dispatch_source_set_cancel_handler(source, ^{ dispatch_group_leave(sources); });
}

- (void)releaseIO {
  if(_writer) dispatch_source_cancel(_writer);
  if(_deadline) dispatch_source_cancel(_deadline);
  if(_reader) dispatch_source_cancel(_reader);
  _writer = nil; _deadline = nil; _reader = nil;
  int fd = _socket;
  _socket = -1;
  // Also covers a stream that never started or was abandoned after the handshake.
  if(fd >= 0) dispatch_group_notify(_sources, _queue, ^{ close(fd); });
}

- (void)dealloc { [self releaseIO]; }
@end
