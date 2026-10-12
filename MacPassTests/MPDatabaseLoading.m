//
//  MPDatabaseLoadingTest.m
//  MacPass
//
//  Created by Michael Starke on 10.07.13.
//  Copyright (c) 2013 HicknHack Software GmbH. All rights reserved.
//

#import <XCTest/XCTest.h>
#import <KeePassKit/KeePassKit.h>

#import "MPDocument.h"

@interface MPDatabaseLoading : XCTestCase

@end

@implementation MPDatabaseLoading


- (void)testLoadVersion1 {
  NSBundle *myBundle = [NSBundle bundleForClass:[self class]];
  NSURL *url = [myBundle URLForResource:@"Test_Password_1234" withExtension:@"kdb"];
  NSError *error = nil;
  MPDocument *document = [[MPDocument alloc] initWithContentsOfURL:url ofType:@"kdb" error:&error];
  XCTAssertNil(error, @"No Error should occur on loading");
  XCTAssertNotNil(document, @"Document cannot be nil");
  XCTAssertTrue(document.encrypted, @"Loaded but unencrypted should be not decrypted");
  KPKCompositeKey *key = [[KPKCompositeKey alloc] initWithKeys:@[[KPKKey keyWithPassword:@"1234"]]];
  XCTAssertTrue([document unlockWithPassword:key keyFileURL:nil error:&error], @"Should decrypt with password");
  XCTAssertNil(error, @"No Error should occur on unlocking with correct password");
  XCTAssertFalse(document.encrypted);
  KPKFileVersion kdb = { KPKDatabaseFormatKdb, kKPKKdbFileVersion };
  XCTAssertEqual(NSOrderedSame, KPKFileVersionCompare(kdb, document.tree.minimumVersion), @"Minimal Version should not increase with KDB File loaded");
}

- (void)testVersion1WrongPassword {
  NSBundle *myBundle = [NSBundle bundleForClass:[self class]];
  NSURL *url = [myBundle URLForResource:@"Test_Password_1234" withExtension:@"kdb"];
  NSError *error = nil;
  MPDocument *document = [[MPDocument alloc] initWithContentsOfURL:url ofType:@"kdb" error:&error];
  XCTAssertNil(error, @"No Error should occur on loading");
  XCTAssertNotNil(document, @"Document should not be nil");
  XCTAssertTrue(document.encrypted, @"Loaded but unencrypted should be not decrypted");
  KPKCompositeKey *key = [[KPKCompositeKey alloc] initWithKeys:@[[KPKKey keyWithPassword:@"123"]]];
  XCTAssertFalse([document unlockWithPassword:key keyFileURL:nil error:&error], @"Decryption should fail");
  XCTAssertNotNil(error, @"Error should occur on unlocking with incorrect password");
  XCTAssertTrue(document.encrypted);
  XCTAssertNil(document.compositeKey);
}

- (void)testLoadDatabaseVerions2 {
  NSBundle *myBundle = [NSBundle bundleForClass:[self class]];
  NSURL *url = [myBundle URLForResource:@"Test_Password_1234" withExtension:@"kdbx"];
  NSError *error = nil;
  MPDocument *document = [[MPDocument alloc] initWithContentsOfURL:url ofType:@"kdbx" error:&error];
  XCTAssertNil(error, @"No Error should occur on loading");
  XCTAssertNotNil(document, @"Document cannot be nil");
  XCTAssertTrue(document.encrypted);
  KPKCompositeKey *key = [[KPKCompositeKey alloc] initWithKeys:@[[KPKKey keyWithPassword:@"1234"]]];
  XCTAssertTrue([document unlockWithPassword:key keyFileURL:nil error:&error]);
  XCTAssertNil(error);
  XCTAssertNotNil(document.tree);
  XCTAssertFalse(document.encrypted);
}

@end
