#import <XCTest/XCTest.h>
#import <KeePassKit/KeePassKit.h>
#import "MPTouchIdCompositeKeyStore.h"
#import "MPSettingsHelper.h"
#import "MPConstants.h"
#import "MPSecurityPreferencesController.h"

@interface MPTouchIdCompositeKeyStore (ExpirationTests)
- (void)setTouchIdEnabledState:(MPTouchIDKeyStorage)mode;
- (void)setKeyTimeOut:(NSUInteger)timeOut;
- (void)setClearKeysOnSleep:(BOOL)clear;
- (BOOL)_isTimedOutDate:(NSDate *)date;
@end

@interface MPTestTouchIDCacheStore : MPTouchIdCompositeKeyStore
@property (strong) NSMutableDictionary *persistentValues;
@end

@implementation MPTestTouchIDCacheStore
- (instancetype)init {
  // Keep tests independent of user preferences and Keychain authentication.
  self.persistentValues = [NSMutableDictionary dictionary];
  [self setValue:[NSMutableDictionary dictionary] forKey:@"keys"];
  [self setValue:[NSMutableDictionary dictionary] forKey:@"keyDates"];
  return self;
}
- (NSData *)encryptedDataForCompositeKey:(KPKCompositeKey *)key error:(NSError **)error {
  return [@"encrypted test key" dataUsingEncoding:NSUTF8StringEncoding];
}
- (void)_updatePersistentStoreForKey:(NSString *)setting documentKey:(NSString *)key value:(id)value {
  if(!self.persistentValues[setting]) {
    self.persistentValues[setting] = [NSMutableDictionary dictionary];
  }
  self.persistentValues[setting][key] = value;
}
- (NSData *)_persitentCompositeKeyDataForDocumentKey:(NSString *)key {
  return self.persistentValues[kMPSettingsKeyTouchIdEncryptedKeyStore][key];
}
- (NSDate *)_persistentDateForDocumentKey:(NSString *)key {
  return self.persistentValues[kMPSettingsKeyTouchIdKeyDateStore][key];
}
- (void)_clearPersistenCompositeKeyData {
  [self.persistentValues removeAllObjects];
}
@end

@interface MPTestTouchIDEncryptionStore : MPTouchIdCompositeKeyStore
@property (assign) SecKeyRef publicKey;
@property (strong) NSError *retrievalError;
@end

@implementation MPTestTouchIDEncryptionStore
- (instancetype)init {
  // Encryption tests use in-memory keys and bypass the application's defaults binding.
  return self;
}
- (SecKeyRef)_copyPublicKeyForEncryption:(NSError **)error {
  if(self.retrievalError) {
    *error = self.retrievalError;
    return NULL;
  }
  return (SecKeyRef)CFRetain(self.publicKey);
}
@end

@interface MPTestPasswordInputPresentation : XCTestCase
@end

@implementation MPTestPasswordInputPresentation

- (void)testTransientKeyExpirationClearsOnlyExpiredDatabase {
  MPTestTouchIDCacheStore *store = [[MPTestTouchIDCacheStore alloc] init];
  [store setTouchIdEnabledState:MPTouchIDKeyStorageTransient];
  [store setKeyTimeOut:3600];
  KPKCompositeKey *key = [[KPKCompositeKey alloc] init];
  [store saveCompositeKey:key forDocumentKey:@"expired"];
  [store saveCompositeKey:key forDocumentKey:@"valid"];
  NSMutableDictionary *dates = [store valueForKey:@"keyDates"];
  dates[@"expired"] = [NSDate dateWithTimeIntervalSinceNow:-3601];
  XCTAssertNil([store loadEncryptedCompositeKeyForDocumentKey:@"expired"]);
  XCTAssertNil(dates[@"expired"]);
  XCTAssertNotNil([store loadEncryptedCompositeKeyForDocumentKey:@"valid"]);
}

- (void)testPersistentExpirationPreservesValidKeyAndDoesNotRefreshItsDate {
  MPTestTouchIDCacheStore *store = [[MPTestTouchIDCacheStore alloc] init];
  [store setTouchIdEnabledState:MPTouchIDKeyStoragePersistent];
  [store setKeyTimeOut:3600];
  [store saveCompositeKey:[[KPKCompositeKey alloc] init] forDocumentKey:@"expired"];
  [store saveCompositeKey:[[KPKCompositeKey alloc] init] forDocumentKey:@"valid"];
  NSMutableDictionary *dates = store.persistentValues[kMPSettingsKeyTouchIdKeyDateStore];
  NSDate *originalDate = dates[@"valid"];
  dates[@"expired"] = [NSDate dateWithTimeIntervalSinceNow:-3601];
  XCTAssertNil([store loadEncryptedCompositeKeyForDocumentKey:@"expired"]);
  XCTAssertNil(dates[@"expired"]);
  XCTAssertNotNil([store loadEncryptedCompositeKeyForDocumentKey:@"valid"]);
  XCTAssertEqualObjects(dates[@"valid"], originalDate);
}

- (void)testLegacyUndatedKeyIsRetainedUntilExpirationIsEnabled {
  MPTestTouchIDCacheStore *store = [[MPTestTouchIDCacheStore alloc] init];
  [store setTouchIdEnabledState:MPTouchIDKeyStoragePersistent];
  [store saveCompositeKey:[[KPKCompositeKey alloc] init] forDocumentKey:@"legacy"];
  [store.persistentValues[kMPSettingsKeyTouchIdKeyDateStore] removeObjectForKey:@"legacy"];
  XCTAssertNotNil([store loadEncryptedCompositeKeyForDocumentKey:@"legacy"]);
  [store setKeyTimeOut:3600];
  XCTAssertNil([store loadEncryptedCompositeKeyForDocumentKey:@"legacy"]);
}

- (void)testSleepClearingCanBeEnabledAndDisabled {
  MPTestTouchIDCacheStore *store = [[MPTestTouchIDCacheStore alloc] init];
  [store setTouchIdEnabledState:MPTouchIDKeyStoragePersistent];
  [store setClearKeysOnSleep:YES];
  [store saveCompositeKey:[[KPKCompositeKey alloc] init] forDocumentKey:@"database"];
  [NSWorkspace.sharedWorkspace.notificationCenter postNotificationName:NSWorkspaceWillSleepNotification object:nil];
  XCTAssertNil([store loadEncryptedCompositeKeyForDocumentKey:@"database"]);
  [store setClearKeysOnSleep:NO];
  [store saveCompositeKey:[[KPKCompositeKey alloc] init] forDocumentKey:@"database"];
  [NSWorkspace.sharedWorkspace.notificationCenter postNotificationName:NSWorkspaceWillSleepNotification object:nil];
  XCTAssertNotNil([store loadEncryptedCompositeKeyForDocumentKey:@"database"]);
}

- (void)testManualClearRemovesBothStoresAndDates {
  MPTestTouchIDCacheStore *store = [[MPTestTouchIDCacheStore alloc] init];
  [store setTouchIdEnabledState:MPTouchIDKeyStorageTransient];
  [store saveCompositeKey:[[KPKCompositeKey alloc] init] forDocumentKey:@"database"];
  [store clearStoredCompositeKeys];
  XCTAssertEqual([[store valueForKey:@"keys"] count], 0u);
  XCTAssertEqual([[store valueForKey:@"keyDates"] count], 0u);
  [store setTouchIdEnabledState:MPTouchIDKeyStoragePersistent];
  [store saveCompositeKey:[[KPKCompositeKey alloc] init] forDocumentKey:@"database"];
  [store clearStoredCompositeKeys];
  XCTAssertEqual(store.persistentValues.count, 0u);
}

- (void)testSecurityPreferencesConnectExpiryControls {
  MPSecurityPreferencesController *controller = [[MPSecurityPreferencesController alloc] init];
  XCTAssertNotNil(controller.view);
  XCTAssertNotNil(controller.clearTouchIdKeysOnSleepCheckButton);
  NSArray *tags = [controller.touchIdKeyTimeOutPopup.itemArray valueForKey:@"tag"];
  XCTAssertEqualObjects(tags, (@[@0, @3600, @14400, @86400, @604800]));
}

- (void)testCompositeKeyEncryptionRoundTrip {
  CFErrorRef errorRef = NULL;
  SecKeyRef privateKey = SecKeyCreateRandomKey((__bridge CFDictionaryRef)@{
    (id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA,
    (id)kSecAttrKeySizeInBits: @2048,
  }, &errorRef);
  XCTAssertNotEqual(privateKey, NULL);
  if(privateKey == NULL) {
    if(errorRef) { CFRelease(errorRef); }
    return;
  }
  SecKeyRef publicKey = SecKeyCopyPublicKey(privateKey);
  MPTestTouchIDEncryptionStore *store = [[MPTestTouchIDEncryptionStore alloc] init];
  store.publicKey = publicKey;
  KPKCompositeKey *key = [[KPKCompositeKey alloc] initWithKeys:@[[KPKKey keyWithPassword:@"Touch ID test password"]]];
  NSError *error = nil;
  NSData *encrypted = [store encryptedDataForCompositeKey:key error:&error];
  XCTAssertNotNil(encrypted);
  XCTAssertNil(error);
  if(encrypted) {
    NSData *clear = CFBridgingRelease(SecKeyCreateDecryptedData(privateKey, kSecKeyAlgorithmRSAEncryptionOAEPSHA256AESGCM, (__bridge CFDataRef)encrypted, &errorRef));
    XCTAssertNotNil(clear);
    if(clear) {
      KPKCompositeKey *decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:KPKCompositeKey.class fromData:clear error:&error];
      XCTAssertTrue([key isEqualToKey:decoded]);
      XCTAssertNil(error);
    }
  }
  if(errorRef) { CFRelease(errorRef); }
  CFRelease(publicKey);
  CFRelease(privateKey);
}

- (void)testKeyRetrievalErrorIsReturnedWithoutRetry {
  MPTestTouchIDEncryptionStore *store = [[MPTestTouchIDEncryptionStore alloc] init];
  store.retrievalError = [NSError errorWithDomain:NSOSStatusErrorDomain code:errSecUserCanceled userInfo:nil];
  NSError *error = nil;
  XCTAssertNil([store encryptedDataForCompositeKey:[[KPKCompositeKey alloc] init] error:&error]);
  XCTAssertEqualObjects(error, store.retrievalError);
}

@end
