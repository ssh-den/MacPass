//
//  MPTestTimeOTP.m
//  MacPassTests
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#import <XCTest/XCTest.h>
#import <KeePassKit/KeePassKit.h>

#import "KPKEntry+MPTimeOTP.h"
#import "MPDocument.h"

// The RFC 6238 test secret "12345678901234567890".
static NSString *const MPTestSetupKey = @"GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";

@interface MPTimeOTPTestDocument : MPDocument
@end
@implementation MPTimeOTPTestDocument
// Never autosaved. Without a key, MacPass asks for a password in a modal alert
// as soon as an edit marks the document as changed.
- (BOOL)checkAutosavingSafetyAndReturnError:(NSError **)outError { return YES; }
- (void)autosaveWithImplicitCancellability:(BOOL)cancellable completionHandler:(void (^)(NSError *))completionHandler { completionHandler(nil); }
@end

@interface MPTestTimeOTP : XCTestCase
@end

@implementation MPTestTimeOTP

- (MPDocument *)document {
  return [[MPTimeOTPTestDocument alloc] initWithType:@"" error:nil];
}

- (KPKEntry *)entryInDocument:(MPDocument *)document {
  KPKEntry *entry = [document.tree createEntry:document.root];
  entry.title = @"Public test";
  [entry addToGroup:document.root];
  return entry;
}

- (void)addAttributeWithKey:(NSString *)key value:(NSString *)value toEntry:(KPKEntry *)entry {
  [entry addCustomAttribute:[[KPKAttribute alloc] initWithKey:key value:value]];
}

- (void)testSetupKeysAsWebsitesShowThem {
  NSData *expected = [@"12345678901234567890" dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertEqualObjects([KPKEntry timeOTPKeyFromSetupKey:MPTestSetupKey], expected);
  XCTAssertEqualObjects([KPKEntry timeOTPKeyFromSetupKey:@"gezd gnbv gy3t qojq gezd gnbv gy3t qojq"], expected);
  XCTAssertEqualObjects([KPKEntry timeOTPKeyFromSetupKey:@" GEZD-GNBV-GY3T-QOJQ\nGEZD-GNBV-GY3T-QOJQ "], expected);
  XCTAssertEqualObjects([KPKEntry timeOTPKeyFromSetupKey:@"GEZDGNBV========"], [@"12345" dataUsingEncoding:NSUTF8StringEncoding]);
}

- (void)testInvalidSetupKeysAreRejectedInsteadOfTruncated {
  XCTAssertNil([KPKEntry timeOTPKeyFromSetupKey:@""]);
  XCTAssertNil([KPKEntry timeOTPKeyFromSetupKey:@"   "]);
  // 0, 1, 8 and 9 are not Base32; KeePassKit would silently stop decoding there.
  XCTAssertNil([KPKEntry timeOTPKeyFromSetupKey:@"GEZDGNB0GY3TQOJQ"]);
  XCTAssertNil([KPKEntry timeOTPKeyFromSetupKey:@"GEZDGNBVGY3TQOJQ1"]);
  // Lengths that no Base32 encoding produces.
  XCTAssertNil([KPKEntry timeOTPKeyFromSetupKey:@"GEZ"]);
  XCTAssertNil([KPKEntry timeOTPKeyFromSetupKey:@"GEZDGN"]);
}

- (void)testTimeOTPAttributesCoverEveryFormatButNotHmacOTP {
  MPDocument *document = self.document;
  KPKEntry *entry = [self entryInDocument:document];
  [self addAttributeWithKey:kKPKAttributeKeyTimeOTPSecretBase32 value:MPTestSetupKey toEntry:entry];
  [self addAttributeWithKey:kKPKAttributeKeyTimeOTPPeriod value:@"30" toEntry:entry];
  [self addAttributeWithKey:kKPKAttributeKeyTimeOTPSeed value:MPTestSetupKey toEntry:entry];
  [self addAttributeWithKey:kKPKAttributeKeyTimeOTPSettings value:@"30;6" toEntry:entry];
  [self addAttributeWithKey:kKPKAttributeKeyOTPOAuthURL value:[@"otpauth://totp/Test?secret=" stringByAppendingString:MPTestSetupKey] toEntry:entry];
  [self addAttributeWithKey:kKPKAttributeKeyHmacOTPSecretBase32 value:MPTestSetupKey toEntry:entry];
  [self addAttributeWithKey:kKPKAttributeKeyHmacOTPCounter value:@"3" toEntry:entry];
  [self addAttributeWithKey:@"Recovery codes" value:@"keep" toEntry:entry];

  NSSet *keys = [NSSet setWithArray:[entry.timeOTPAttributes valueForKey:@"key"]];
  NSSet *expected = [NSSet setWithArray:@[kKPKAttributeKeyTimeOTPSecretBase32, kKPKAttributeKeyTimeOTPPeriod, kKPKAttributeKeyTimeOTPSeed,
                                          kKPKAttributeKeyTimeOTPSettings, kKPKAttributeKeyOTPOAuthURL]];
  XCTAssertEqualObjects(keys, expected);

  KPKEntry *hotp = [self entryInDocument:document];
  [self addAttributeWithKey:kKPKAttributeKeyOTPOAuthURL value:[@"otpauth://hotp/Test?counter=1&secret=" stringByAppendingString:MPTestSetupKey] toEntry:hotp];
  XCTAssertEqual(hotp.timeOTPAttributes.count, 0);
}

- (void)testChangingTheSetupKeyReplacesEveryStoredSecret {
  MPDocument *document = self.document;
  KPKEntry *entry = [self entryInDocument:document];
  NSString *oldKey = @"JBSWY3DPEHPK3PXP";
  [self addAttributeWithKey:kKPKAttributeKeyOTPOAuthURL value:[@"otpauth://totp/Test?secret=" stringByAppendingString:oldKey] toEntry:entry];
  [self addAttributeWithKey:kKPKAttributeKeyTimeOTPSecretBase32 value:oldKey toEntry:entry];
  [self addAttributeWithKey:kKPKAttributeKeyTimeOTPSeed value:oldKey toEntry:entry];
  [self addAttributeWithKey:kKPKAttributeKeyTimeOTPSettings value:@"30;6" toEntry:entry];

  KPKTimeOTPGenerator *generator = [[KPKTimeOTPGenerator alloc] init];
  generator.key = [KPKEntry timeOTPKeyFromSetupKey:MPTestSetupKey];
  [entry saveTimeOTPGenerator:generator];

  XCTAssertEqualObjects([entry attributeWithKey:kKPKAttributeKeyTimeOTPSecretBase32].value, MPTestSetupKey);
  XCTAssertEqualObjects([entry attributeWithKey:kKPKAttributeKeyTimeOTPSeed].value, MPTestSetupKey);
  XCTAssertEqualObjects([entry attributeWithKey:kKPKAttributeKeyTimeOTPSettings].value, @"30;6");
  // Every format alone yields the new key.
  for(NSString *key in @[kKPKAttributeKeyOTPOAuthURL, kKPKAttributeKeyTimeOTPSecretBase32, kKPKAttributeKeyTimeOTPSeed]) {
    NSMutableArray *attributes = [NSMutableArray arrayWithObject:[entry attributeWithKey:key]];
    if([key isEqual:kKPKAttributeKeyTimeOTPSeed]) [attributes addObject:[entry attributeWithKey:kKPKAttributeKeyTimeOTPSettings]];
    XCTAssertEqualObjects([[KPKTimeOTPGenerator alloc] initWithAttributes:attributes].key, generator.key, @"%@", key);
  }
}

- (void)testRemovingTheVerificationCodeKeepsOtherFieldsAndCanBeUndone {
  MPDocument *document = self.document;
  KPKEntry *entry = [self entryInDocument:document];
  [self addAttributeWithKey:kKPKAttributeKeyOTPOAuthURL value:[@"otpauth://totp/Test?secret=" stringByAppendingString:MPTestSetupKey] toEntry:entry];
  [self addAttributeWithKey:kKPKAttributeKeyTimeOTPSecretBase32 value:MPTestSetupKey toEntry:entry];
  [self addAttributeWithKey:kKPKAttributeKeyHmacOTPSecretBase32 value:MPTestSetupKey toEntry:entry];
  [self addAttributeWithKey:@"Recovery codes" value:@"keep" toEntry:entry];
  XCTAssertTrue(entry.hasTimeOTP);

  NSUndoManager *undoManager = document.undoManager;
  undoManager.groupsByEvent = NO;
  [undoManager removeAllActions];
  [undoManager beginUndoGrouping];
  [document removeTimeOTPFromEntry:entry];
  [undoManager endUndoGrouping];

  XCTAssertFalse(entry.hasTimeOTP);
  XCTAssertNil([entry attributeWithKey:kKPKAttributeKeyOTPOAuthURL]);
  XCTAssertNil([entry attributeWithKey:kKPKAttributeKeyTimeOTPSecretBase32]);
  XCTAssertNotNil([entry attributeWithKey:kKPKAttributeKeyHmacOTPSecretBase32]);
  XCTAssertEqualObjects([entry attributeWithKey:@"Recovery codes"].value, @"keep");

  [undoManager undo];
  XCTAssertTrue(entry.hasTimeOTP);
  XCTAssertEqualObjects([entry attributeWithKey:kKPKAttributeKeyTimeOTPSecretBase32].value, MPTestSetupKey);
}

@end
