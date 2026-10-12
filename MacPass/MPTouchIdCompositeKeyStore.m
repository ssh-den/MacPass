//
//  MPTouchIdCompositeKeyStore.m
//  MacPass
//
//  Created by Julius Zint on 14.03.21.
//  Copyright © 2021 HicknHack Software GmbH. All rights reserved.
//
#import "MPSettingsHelper.h"
#import "MPTouchIdCompositeKeyStore.h"
#import "MPConstants.h"

#import "NSError+Messages.h"
#import <KeePassKit/KeePassKit.h>

@interface MPTouchIdCompositeKeyStore ()
@property (readonly, strong) NSMutableDictionary* keys;
@property (readonly, strong) NSMutableDictionary* keyDates;
@property (nonatomic) MPTouchIDKeyStorage touchIdEnabledState;
@property (nonatomic) NSUInteger keyTimeOut;
@property (nonatomic) BOOL clearKeysOnSleep;
@end

@implementation MPTouchIdCompositeKeyStore

+ (instancetype)defaultStore {
  static MPTouchIdCompositeKeyStore *instance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[MPTouchIdCompositeKeyStore alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if(self) {
    _keys = [[NSMutableDictionary alloc] init];
    _keyDates = [[NSMutableDictionary alloc] init];
    [self bind:NSStringFromSelector(@selector(touchIdEnabledState))
      toObject:NSUserDefaultsController.sharedUserDefaultsController
   withKeyPath:[MPSettingsHelper defaultControllerPathForKey:kMPSettingsKeyTouchIdEnabled]
       options:nil];
    [self bind:NSStringFromSelector(@selector(keyTimeOut))
      toObject:NSUserDefaultsController.sharedUserDefaultsController
   withKeyPath:[MPSettingsHelper defaultControllerPathForKey:kMPSettingsKeyTouchIdKeyTimeOut]
       options:nil];
    [self bind:NSStringFromSelector(@selector(clearKeysOnSleep))
      toObject:NSUserDefaultsController.sharedUserDefaultsController
   withKeyPath:[MPSettingsHelper defaultControllerPathForKey:kMPSettingsKeyClearTouchIdKeysOnSleep]
       options:nil];
  }
  return self;
}

- (void)dealloc {
  [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}

- (void)setTouchIdEnabledState:(MPTouchIDKeyStorage)touchIdEnabledState {
  switch(touchIdEnabledState) {
    case MPTouchIDKeyStorageTransient:
      // clear persistent store
      [self _clearPersistenCompositeKeyData];
      break;
    case MPTouchIDKeyStoragePersistent:
      // clear transient store
      [self _clearTransientCompositeKeyData];
      break;
    default:
      // clear persitent and transient store
      [self _clearPersistenCompositeKeyData];
      [self _clearTransientCompositeKeyData];
  }
  _touchIdEnabledState = touchIdEnabledState;
}

- (void)setClearKeysOnSleep:(BOOL)clearKeysOnSleep {
  if(_clearKeysOnSleep == clearKeysOnSleep) {
    return;
  }
  _clearKeysOnSleep = clearKeysOnSleep;
  if(clearKeysOnSleep) {
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
                                                       selector:@selector(_clearStoredCompositeKeysForNotification:)
                                                           name:NSWorkspaceWillSleepNotification
                                                         object:nil];
  }
  else {
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self name:NSWorkspaceWillSleepNotification object:nil];
  }
}

- (void)clearStoredCompositeKeys {
  [self _clearPersistenCompositeKeyData];
  [self _clearTransientCompositeKeyData];
}

- (void)_clearStoredCompositeKeysForNotification:(NSNotification *)notification {
  [self clearStoredCompositeKeys];
}

- (void)saveCompositeKey:(KPKCompositeKey *)compositeKey forDocumentKey:(NSString *)documentKey {
  if(documentKey.length == 0 || compositeKey == nil) {
    return;
  }
  if(self.touchIdEnabledState == MPTouchIDKeyStorageDisabled) {
    [self _clearPersistenCompositeKeyData];
    [self _clearTransientCompositeKeyDataForDocumentKey:documentKey];
    return;
  }
  NSError *error = nil;
  NSData *encryptedCompositeKey = [self encryptedDataForCompositeKey:compositeKey error:&error];
  if(!encryptedCompositeKey) {
    NSLog(@"Unable to encrypt composite key: %@", error);
    return;
  }

  switch(self.touchIdEnabledState) {
    case MPTouchIDKeyStorageTransient:
      [self _clearPersistenCompositeKeyData];
      if(nil != encryptedCompositeKey) {
        self.keys[documentKey] = encryptedCompositeKey;
        self.keyDates[documentKey] = NSDate.date;
      }
      break;
    case MPTouchIDKeyStoragePersistent:
      [self _clearTransientCompositeKeyDataForDocumentKey:documentKey];
      if(nil != encryptedCompositeKey) {
        [self _persistCompositeKeyData:encryptedCompositeKey date:NSDate.date forDocumentKey:documentKey];
      }
      break;
    case MPTouchIDKeyStorageDisabled:
      [self _clearPersistenCompositeKeyData];
      [self _clearTransientCompositeKeyDataForDocumentKey:documentKey];
      break;
    default:
      NSAssert(NO,@"Unsupported internal touchID preferences value.");
      break;
  }
}
- (NSData *)loadEncryptedCompositeKeyForDocumentKey:(NSString *)documentKey {
  if(documentKey.length == 0) {
    return nil;
  }
  NSInteger touchIdMode = self.touchIdEnabledState;
  if(touchIdMode == MPTouchIDKeyStoragePersistent) {
    NSData *data = [self _persitentCompositeKeyDataForDocumentKey:documentKey];
    if(data && [self _isTimedOutDate:[self _persistentDateForDocumentKey:documentKey]]) {
      [self _clearPersistentCompositeKeyDataForDocumentKey:documentKey];
      return nil;
    }
    return data;
  }
  if(touchIdMode == MPTouchIDKeyStorageTransient) {
    if(self.keys[documentKey] && [self _isTimedOutDate:self.keyDates[documentKey]]) {
      [self _clearTransientCompositeKeyDataForDocumentKey:documentKey];
      return nil;
    }
    return self.keys[documentKey];
  }
  return nil;
}

- (BOOL)_isTimedOutDate:(NSDate *)date {
  if(self.keyTimeOut == 0) {
    return NO;
  }
  // Legacy keys without a date must be provisioned again when expiration is enabled.
  if(![date isKindOfClass:NSDate.class]) {
    return YES;
  }
  return -date.timeIntervalSinceNow >= (NSTimeInterval)self.keyTimeOut;
}

- (KPKCompositeKey *)compositeKeyForEncryptedKeyData:(NSData *)data error:(NSError *__autoreleasing  _Nullable *)error {
  if(nil == data) {
    return nil;
  }
  
  NSData* tag = [MPTouchIdUnlockPrivateKeyTag dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *queryPrivateKey = @{
    (id)kSecClass: (id)kSecClassKey,
    (id)kSecAttrApplicationTag: tag,
    (id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA,
    (id)kSecReturnRef: @YES,
  };
  SecKeyRef privateKey = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)queryPrivateKey, (CFTypeRef *)&privateKey);
  if(status != errSecSuccess) {
    if(error != NULL) {
      NSString* description = CFBridgingRelease(SecCopyErrorMessageString(status, NULL));
      *error = [NSError errorWithCode:status description:description];
    }
    if(privateKey) {
      CFRelease(privateKey);
    }
    return nil;
  }
  
  SecKeyAlgorithm algorithm = kSecKeyAlgorithmRSAEncryptionOAEPSHA256AESGCM;
  BOOL canDecrypt = SecKeyIsAlgorithmSupported(privateKey, kSecKeyOperationTypeDecrypt, algorithm);
  if(!canDecrypt) {
    if(error != NULL) {
      *error = [NSError errorWithCode:MPErrorTouchIdUnsupportedKeyForEncrpytion description:NSLocalizedString(@"ERROR_TOUCH_ID_UNSUPPORTED_KEY", @"The key stored for TouchID is not suitable for encrpytion")];
    }
    if(privateKey) {
      CFRelease(privateKey);
    }
    return nil;
  }
  
  CFErrorRef errorRef = NULL;
  NSData* clearText = (NSData*)CFBridgingRelease(SecKeyCreateDecryptedData(privateKey, algorithm, (__bridge CFDataRef)data, &errorRef));
  CFRelease(privateKey);
  NSError *decryptionError = CFBridgingRelease(errorRef);
  if(clearText) {
    return [NSKeyedUnarchiver unarchivedObjectOfClass:KPKCompositeKey.class fromData:clearText error:error];
  }
  if(error != NULL) {
    *error = decryptionError;
  }
  return nil;
}


- (NSData *)encryptedDataForCompositeKey:(KPKCompositeKey *)compositeKey error:(NSError *__autoreleasing  _Nullable *)error {
  NSData* keyData = [NSKeyedArchiver archivedDataWithRootObject:compositeKey requiringSecureCoding:YES error:error];
  if(keyData == nil) {
    return nil;
  }
  SecKeyRef publicKey = [self _copyPublicKeyForEncryption:error];
  if(publicKey == NULL) {
    return nil;
  }
  SecKeyAlgorithm algorithm = kSecKeyAlgorithmRSAEncryptionOAEPSHA256AESGCM;
  NSData *encryptedKey = nil;
  if(SecKeyIsAlgorithmSupported(publicKey, kSecKeyOperationTypeEncrypt, algorithm)) {
    CFErrorRef encryptionError = NULL;
    encryptedKey = CFBridgingRelease(SecKeyCreateEncryptedData(publicKey, algorithm, (__bridge CFDataRef)keyData, &encryptionError));
    NSError *failure = CFBridgingRelease(encryptionError);
    if(error != NULL) {
      *error = failure;
    }
  }
  else if(error != NULL) {
    *error = [NSError errorWithCode:MPErrorTouchIdUnsupportedKeyForEncrpytion description:NSLocalizedString(@"ERROR_TOUCH_ID_UNSUPPORTED_KEY", @"The key stored for TouchID is not suitable for encryption")];
  }
  CFRelease(publicKey);
  return encryptedKey;
}

- (SecKeyRef)_copyPublicKeyForEncryption:(NSError **)error {
  NSData* tag = [MPTouchIdUnlockPublicKeyTag dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *getquery = @{
    (id)kSecClass: (id)kSecClassKey,
    (id)kSecAttrApplicationTag: tag,
    (id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA,
    (id)kSecReturnRef: @YES,
  };
  SecKeyRef publicKey = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)getquery, (CFTypeRef *)&publicKey);
  if(status == errSecSuccess && publicKey != NULL) {
    return publicKey;
  }
  if(publicKey) {
    CFRelease(publicKey);
  }

  // SecKeyCreateRandomKey stores the private key; derive its public key when needed.
  NSDictionary *privateQuery = @{
    (id)kSecClass: (id)kSecClassKey,
    (id)kSecAttrApplicationTag: [MPTouchIdUnlockPrivateKeyTag dataUsingEncoding:NSUTF8StringEncoding],
    (id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA,
    (id)kSecReturnRef: @YES,
  };
  SecKeyRef privateKey = NULL;
  status = SecItemCopyMatching((__bridge CFDictionaryRef)privateQuery, (CFTypeRef *)&privateKey);
  if(status == errSecSuccess && privateKey != NULL) {
    publicKey = SecKeyCopyPublicKey(privateKey);
    CFRelease(privateKey);
    if(publicKey != NULL) {
      return publicKey;
    }
    status = errSecInternalComponent;
  }
  else if(privateKey) {
    CFRelease(privateKey);
  }
  if(status == errSecSuccess) {
    status = errSecInternalComponent;
  }
  if(status == errSecItemNotFound) {
    return [self _createPublicKeyForEncryption:error];
  }
  if(error != NULL) {
    *error = [NSError errorWithCode:status description:CFBridgingRelease(SecCopyErrorMessageString(status, NULL))];
  }
  return NULL;
}

- (SecKeyRef)_createPublicKeyForEncryption:(NSError **)outError {
  CFErrorRef error = NULL;
  NSString* privateKeyLabel = @"MacPass TouchID Feature Private Key";
  NSData* privateKeyTag = [MPTouchIdUnlockPrivateKeyTag dataUsingEncoding:NSUTF8StringEncoding];
  SecAccessControlRef access = NULL;
  if (@available(macOS 10.13.4, *)) {
    SecAccessControlCreateFlags flags = kSecAccessControlBiometryCurrentSet;
    if (@available(macOS 10.15, *)) {
      flags |= kSecAccessControlWatch | kSecAccessControlOr;
    }
    access = SecAccessControlCreateWithFlags(kCFAllocatorDefault,
                                             kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                             flags,
                                             &error);
    if(access == NULL) {
      NSError *failure = CFBridgingRelease(error);
      if(outError != NULL) {
        *outError = failure;
      }
      return NULL;
    }
    NSDictionary* attributes = @{
      (id)kSecAttrKeyType:        (id)kSecAttrKeyTypeRSA,
      (id)kSecAttrKeySizeInBits:  @2048,
      (id)kSecAttrSynchronizable: @NO,
      (id)kSecPrivateKeyAttrs:
           @{ (id)kSecAttrIsPermanent:    @YES,
              (id)kSecAttrApplicationTag: privateKeyTag,
              (id)kSecAttrLabel: privateKeyLabel,
              (id)kSecAttrAccessControl:  (__bridge id)access
            },
    };
    SecKeyRef result = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attributes, &error);
    CFRelease(access);
    NSError *failure = CFBridgingRelease(error);
    if(result == NULL) {
      if(outError != NULL) {
        *outError = failure;
      }
      return NULL;
    }
    SecKeyRef publicKey = SecKeyCopyPublicKey(result);
    CFRelease(result);
    if(publicKey == NULL && outError != NULL) {
      *outError = [NSError errorWithCode:errSecInternalComponent description:@"Unable to derive the Touch ID public key"];
    }
    return publicKey;
  }
  else {
    return NULL;
  }
}

- (NSData *)_persitentCompositeKeyDataForDocumentKey:(NSString *)key {
  if(key.length == 0) {
    return nil;
  }
  return [NSUserDefaults.standardUserDefaults objectForKey:kMPSettingsKeyTouchIdEncryptedKeyStore][key];
}

- (NSDate *)_persistentDateForDocumentKey:(NSString *)key {
  return [NSUserDefaults.standardUserDefaults objectForKey:kMPSettingsKeyTouchIdKeyDateStore][key];
}

- (void)_persistCompositeKeyData:(NSData *)data date:(NSDate *)date forDocumentKey:(NSString *)key {
  if(data.length == 0 || key.length == 0) {
    return;
  }
  [self _updatePersistentStoreForKey:kMPSettingsKeyTouchIdEncryptedKeyStore documentKey:key value:data];
  [self _updatePersistentStoreForKey:kMPSettingsKeyTouchIdKeyDateStore documentKey:key value:date];
}

- (void)_updatePersistentStoreForKey:(NSString *)settingsKey documentKey:(NSString *)key value:(id)value {
  NSMutableDictionary *dict = [[NSUserDefaults.standardUserDefaults objectForKey:settingsKey] mutableCopy];
  if(nil == dict) {
    dict = [[NSMutableDictionary alloc] init];
  }
  dict[key] = value;
  [NSUserDefaults.standardUserDefaults setObject:[dict copy] forKey:settingsKey];
}

- (void)_clearPersistenCompositeKeyData {
  [NSUserDefaults.standardUserDefaults removeObjectForKey:kMPSettingsKeyTouchIdEncryptedKeyStore];
  [NSUserDefaults.standardUserDefaults removeObjectForKey:kMPSettingsKeyTouchIdKeyDateStore];
}

- (void)_clearPersistentCompositeKeyDataForDocumentKey:(NSString *)key {
  [self _updatePersistentStoreForKey:kMPSettingsKeyTouchIdEncryptedKeyStore documentKey:key value:nil];
  [self _updatePersistentStoreForKey:kMPSettingsKeyTouchIdKeyDateStore documentKey:key value:nil];
}

- (void)_clearTransientCompositeKeyData {
  [self.keys removeAllObjects];
  [self.keyDates removeAllObjects];
}

- (void)_clearTransientCompositeKeyDataForDocumentKey:(NSString *)key {
  [self.keys removeObjectForKey:key];
  [self.keyDates removeObjectForKey:key];
}

@end
