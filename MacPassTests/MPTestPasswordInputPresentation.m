#import <XCTest/XCTest.h>
#import <Carbon/Carbon.h>
#import <KeePassKit/KeePassKit.h>

#import "MPPasswordInputController.h"
#import "MPSettingsHelper.h"
#import "DDHotKey+MacPassAdditions.h"
#import "MPTouchIdCompositeKeyStore.h"
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

@interface MPPasswordInputController (PresentationTests)
- (IBAction)unlockMethodChanged:(NSSegmentedControl *)sender;
- (BOOL)_event:(NSEvent *)event matchesHotKey:(DDHotKey *)hotKey;
- (IBAction)_submit:(id)sender;
- (IBAction)unlockWithTouchID:(id)sender;
- (BOOL)_touchIdIsUnlockAvailable;
@end

@interface MPTestTouchIDActionController : MPPasswordInputController
@property NSUInteger touchIDRequests;
@end

@implementation MPTestTouchIDActionController
- (BOOL)_touchIdIsUnlockAvailable {
  return YES;
}
- (IBAction)unlockWithTouchID:(id)sender {
  self.touchIDRequests++;
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

- (void)testUnavailableKeyReturnsTouchIDCardToManualInput {
  MPPasswordInputController *controller = [[MPPasswordInputController alloc] init];
  __block BOOL submitted = NO;
  [controller requestPasswordWithMessage:nil cancelLabel:nil completionHandler:^BOOL(KPKCompositeKey *key, NSURL *url, BOOL cancel, NSError **error) {
    submitted = YES;
    return YES;
  }];
  NSView *touchCard = [controller valueForKey:@"touchIdCard"];
  NSView *manualCard = [controller valueForKey:@"manualCard"];
  touchCard.hidden = NO;
  manualCard.hidden = YES;
  [controller _submit:nil];
  XCTAssertTrue(touchCard.hidden);
  XCTAssertFalse(manualCard.hidden);
  XCTAssertFalse(submitted);
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

- (MPPasswordInputPresentationState)stateForMode:(MPTouchIDKeyStorage)mode
                                             key:(BOOL)key
                                         enabled:(BOOL)enabled
                                           valid:(BOOL)valid
                                       supported:(BOOL)supported {
  return [MPPasswordInputController presentationStateForTouchIDMode:mode
                                                       keyAvailable:key
                                                    shortcutEnabled:enabled
                                                      shortcutValid:valid
                                                           supported:supported];
}

- (void)testDisabledModeAlwaysUsesManualPresentation {
  XCTAssertEqual([self stateForMode:MPTouchIDKeyStorageDisabled key:YES enabled:YES valid:YES supported:YES],
                 MPPasswordInputPresentationManualOnly);
}

- (void)testEnabledModesWithoutKeyRequireProvisioning {
  XCTAssertEqual([self stateForMode:MPTouchIDKeyStorageTransient key:NO enabled:NO valid:NO supported:YES],
                 MPPasswordInputPresentationProvisioningNeeded);
  XCTAssertEqual([self stateForMode:MPTouchIDKeyStoragePersistent key:NO enabled:NO valid:NO supported:YES],
                 MPPasswordInputPresentationProvisioningNeeded);
}

- (void)testEnabledModesWithKeyOfferTouchID {
  XCTAssertEqual([self stateForMode:MPTouchIDKeyStorageTransient key:YES enabled:NO valid:NO supported:YES],
                 MPPasswordInputPresentationTouchIDAvailable);
  XCTAssertEqual([self stateForMode:MPTouchIDKeyStoragePersistent key:YES enabled:NO valid:NO supported:YES],
                 MPPasswordInputPresentationTouchIDAvailable);
}

- (void)testShortcutRequiresEnabledAndValidHotKey {
  MPPasswordInputPresentationState validState = [self stateForMode:MPTouchIDKeyStoragePersistent key:YES enabled:YES valid:YES supported:YES];
  XCTAssertTrue((validState & MPPasswordInputPresentationShortcutAvailable) != 0);

  MPPasswordInputPresentationState disabledState = [self stateForMode:MPTouchIDKeyStoragePersistent key:YES enabled:NO valid:YES supported:YES];
  XCTAssertFalse((disabledState & MPPasswordInputPresentationShortcutAvailable) != 0);
  MPPasswordInputPresentationState invalidState = [self stateForMode:MPTouchIDKeyStoragePersistent key:YES enabled:YES valid:NO supported:YES];
  XCTAssertFalse((invalidState & MPPasswordInputPresentationShortcutAvailable) != 0);
}

- (void)testUnsupportedSystemsAlwaysUseManualPresentation {
  XCTAssertEqual([self stateForMode:MPTouchIDKeyStoragePersistent key:YES enabled:YES valid:YES supported:NO],
                 MPPasswordInputPresentationManualOnly);
}

- (void)testUnknownModeUsesManualPresentation {
  XCTAssertEqual([MPPasswordInputController presentationStateForTouchIDMode:99 keyAvailable:YES shortcutEnabled:YES shortcutValid:YES supported:YES], MPPasswordInputPresentationManualOnly);
}

- (void)testTouchBarUnlockUsesTheSelectedTouchIDCard {
  MPTestTouchIDActionController *controller = [[MPTestTouchIDActionController alloc] initWithNibName:nil bundle:nil];
  __block BOOL requestedManualPassword = NO;
  [controller requestPasswordWithMessage:nil cancelLabel:nil completionHandler:^BOOL(KPKCompositeKey *key, NSURL *url, BOOL cancel, NSError **error) {
    requestedManualPassword = YES;
    return YES;
  }];
  NSView *card = [controller valueForKey:@"touchIdCard"];
  card.hidden = NO;
  [controller _submit:nil];
  XCTAssertEqual(controller.touchIDRequests, 1u);
  XCTAssertFalse(requestedManualPassword);
}

- (void)testCancelKeepsItsLabelAndRemovesShortcutMonitor {
  MPPasswordInputController *controller = [[MPPasswordInputController alloc] initWithNibName:nil bundle:nil];
  __block BOOL cancelled = NO;
  [controller requestPasswordWithMessage:nil cancelLabel:@"Abort Merge" completionHandler:^BOOL(KPKCompositeKey *key, NSURL *url, BOOL cancel, NSError **error) {
    cancelled = cancel;
    return YES;
  }];
  NSButton *button = [controller valueForKey:@"cancelButton"];
  XCTAssertEqualObjects(button.title, @"Abort Merge");
  [controller _submit:button];
  XCTAssertTrue(cancelled);
  XCTAssertNil([controller valueForKey:@"touchIdShortcutMonitor"]);
}

- (void)testShortcutHintUsesDDHotKeyGlyphFormatting {
  // A function key has the same label in every keyboard layout.
  DDHotKey *hotKey = [DDHotKey hotKeyWithKeyCode:kVK_F6 modifierFlags:NSEventModifierFlagControl|NSEventModifierFlagOption task:nil];
  NSString *hint = [MPPasswordInputController touchIDShortcutHintForHotKey:hotKey];
  XCTAssertTrue([hint containsString:@"⌃⌥F6"], @"Unexpected shortcut hint: %@", hint);
}

- (void)testShortcutIgnoresCapsLockAndNumericPadFlags {
  MPPasswordInputController *controller = [[MPPasswordInputController alloc] initWithNibName:nil bundle:nil];
  DDHotKey *hotKey = [DDHotKey hotKeyWithKeyData:[DDHotKey hotKeyDataWithKeyCode:kVK_ANSI_M modifierFlags:kCGEventFlagMaskControl|kCGEventFlagMaskAlternate]];
  NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                  location:NSZeroPoint
                             modifierFlags:NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagCapsLock|NSEventModifierFlagNumericPad
                                 timestamp:0 windowNumber:0 context:nil
                                characters:@"M" charactersIgnoringModifiers:@"m" isARepeat:NO keyCode:kVK_ANSI_M];
  XCTAssertTrue([controller _event:event matchesHotKey:hotKey]);
  DDHotKey *otherKey = [DDHotKey hotKeyWithKeyData:[DDHotKey hotKeyDataWithKeyCode:kVK_ANSI_N modifierFlags:kCGEventFlagMaskControl|kCGEventFlagMaskAlternate]];
  XCTAssertFalse([controller _event:event matchesHotKey:otherKey]);
  DDHotKey *otherModifiers = [DDHotKey hotKeyWithKeyCode:kVK_ANSI_M modifierFlags:NSEventModifierFlagCommand|NSEventModifierFlagOption task:nil];
  XCTAssertFalse([controller _event:event matchesHotKey:otherModifiers]);
}

- (void)testCardSelectionUpdatesVisibilityAndFocus {
  MPPasswordInputController *controller = [[MPPasswordInputController alloc] initWithNibName:nil bundle:nil];
  NSView *view = controller.view;
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 508, 489)
                                                 styleMask:NSWindowStyleMaskTitled
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
  window.contentView = view;
  NSSegmentedControl *control = [controller valueForKey:@"unlockMethodControl"];
  NSView *touchCard = [controller valueForKey:@"touchIdCard"];
  NSView *manualCard = [controller valueForKey:@"manualCard"];
  NSButton *touchButton = [controller valueForKey:@"touchIdButton"];
  NSTextField *passwordField = [controller valueForKey:@"passwordTextField"];

  control.selectedSegment = 1;
  [controller unlockMethodChanged:control];
  XCTAssertFalse(manualCard.hidden);
  XCTAssertTrue(touchCard.hidden);
  XCTAssertEqual(window.firstResponder, passwordField.currentEditor);

  control.selectedSegment = 0;
  [controller unlockMethodChanged:control];
  XCTAssertTrue(manualCard.hidden);
  XCTAssertFalse(touchCard.hidden);
  XCTAssertEqual(window.firstResponder, touchButton);
}

- (void)testUnlockPanelUsesSharedAlignmentAndAccessibleTouchIDAction {
  MPPasswordInputController *controller = [[MPPasswordInputController alloc] initWithNibName:nil bundle:nil];
  NSView *view = controller.view;
  [view layoutSubtreeIfNeeded];

  NSView *manualCard = [controller valueForKey:@"manualCard"];
  NSView *touchCard = [controller valueForKey:@"touchIdCard"];
  NSView *panel = manualCard.superview;
  NSTextField *passwordField = [controller valueForKey:@"passwordTextField"];
  NSView *keyPathControl = [controller valueForKey:@"keyPathControl"];
  NSButton *showPasswordButton = [controller valueForKey:@"togglePasswordButton"];
  NSButton *resetKeyFileButton = [controller valueForKey:@"resetKeyFileButton"];
  NSButton *unlockButton = [controller valueForKey:@"unlockButton"];
  NSButton *touchIdButton = [controller valueForKey:@"touchIdButton"];
  NSView *touchIdFooter = [controller valueForKey:@"touchIdFooter"];

  XCTAssertEqualWithAccuracy(NSMidX(panel.frame), NSMidX(view.bounds), 0.5);
  XCTAssertTrue(NSEqualRects(manualCard.frame, touchCard.frame));
  NSRect passwordAlignmentRect = [passwordField alignmentRectForFrame:passwordField.frame];
  NSRect keyPathAlignmentRect = [keyPathControl alignmentRectForFrame:keyPathControl.frame];
  NSRect unlockAlignmentRect = [unlockButton alignmentRectForFrame:unlockButton.frame];
  XCTAssertEqualWithAccuracy(NSMinX(passwordAlignmentRect), NSMinX(keyPathAlignmentRect), 0.5);
  XCTAssertEqualWithAccuracy(NSMaxX(showPasswordButton.frame), NSMaxX(resetKeyFileButton.frame), 0.5);
  XCTAssertEqualWithAccuracy(NSMaxX(unlockAlignmentRect), NSMaxX(keyPathAlignmentRect), 0.5);
  XCTAssertEqualWithAccuracy(NSMidX(touchIdFooter.frame), NSMidX(panel.bounds), 0.5);
  XCTAssertEqualObjects(touchIdButton.accessibilityLabel, touchIdButton.title);
  XCTAssertTrue([touchIdButton.title containsString:@"Touch ID"]);
}

@end
