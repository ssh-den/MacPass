#import <XCTest/XCTest.h>
#import <KeePassKit/KeePassKit.h>
#import "MPTouchIdCompositeKeyStore.h"

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
