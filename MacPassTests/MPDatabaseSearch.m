//
//  MPDatabaseSearch.m
//  MacPass
//
//  Created by Michael Starke on 09/12/14.
//  Copyright (c) 2014 HicknHack Software GmbH. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>
#import <KeePassKit/KeePassKit.h>

@interface MPDatabaseSearch : XCTestCase

@property (strong) KPKTree *tree;
@property (strong) KPKGroup *includedGroup;
@property (strong) KPKGroup *inheritingGroup;
@property (strong) KPKGroup *excludedGroup;
@property (strong) KPKEntry *entry1;
@property (strong) KPKEntry *entry2;
@property (strong) KPKEntry *entry3;

@end

@implementation MPDatabaseSearch

- (void)setUp {
  [super setUp];
  self.tree = [[KPKTree alloc] init];
  self.tree.root = [[KPKGroup alloc] init];
  
  self.tree.root.isAutoTypeEnabled = KPKInheritYES;
  self.inheritingGroup = [self.tree createGroup:self.tree.root];
  self.includedGroup = [self.tree createGroup:self.tree.root];
  self.excludedGroup = [self.tree createGroup:self.tree.root];
  // Creation configures nodes; addToGroup: attaches them to the tree.
  [self.inheritingGroup addToGroup:self.tree.root];
  [self.includedGroup addToGroup:self.tree.root];
  [self.excludedGroup addToGroup:self.tree.root];
  self.inheritingGroup.isAutoTypeEnabled = KPKInherit;
  self.includedGroup.isAutoTypeEnabled = KPKInheritYES;
  self.excludedGroup.isAutoTypeEnabled = KPKInheritNO;
  
  self.entry1 = [self.tree createEntry:self.includedGroup];
  self.entry2 = [self.tree createEntry:self.inheritingGroup];
  self.entry3 = [self.tree createEntry:self.excludedGroup];
  [self.entry1 addToGroup:self.includedGroup];
  [self.entry2 addToGroup:self.inheritingGroup];
  [self.entry3 addToGroup:self.excludedGroup];

  
  self.entry1.title = @"entry1";
  self.entry1.url = @"www.url1.com";
  
  self.entry2.title = @"entry2";
  self.entry2.url = @"www.url1.com";
  
  self.entry3.title = @"entry3";
  self.entry3.url = @"www.url1.com";
}

- (void)tearDown {
  self.entry1 = nil;
  self.entry2 = nil;
  self.entry3 = nil;
  self.includedGroup = nil;
  self.inheritingGroup = nil;
  self.excludedGroup = nil;
  self.tree = nil;
  [super tearDown];
}

- (void)testAutotypeSearchRespectsGroupAndEntrySettings {
  XCTAssertEqual(self.tree.allEntries.count, 3u);
  NSArray *entries = self.tree.root.autotypeableChildEntries;
  XCTAssertEqual(entries.count, 2u);
  XCTAssertTrue([entries containsObject:self.entry1]);
  XCTAssertTrue([entries containsObject:self.entry2]);
  XCTAssertFalse([entries containsObject:self.entry3]);

  self.tree.root.isAutoTypeEnabled = KPKInheritNO;
  XCTAssertEqualObjects(self.tree.root.autotypeableChildEntries, (@[self.entry1]));

  self.entry1.autotype.enabled = NO;
  XCTAssertEqual(self.tree.root.autotypeableChildEntries.count, 0u);
}

@end
