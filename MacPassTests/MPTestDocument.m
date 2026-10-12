//
//  MPDatabaseCreation.m
//  MacPass
//
//  Created by Michael Starke on 10.07.13.
//  Copyright (c) 2013 HicknHack Software GmbH. All rights reserved.
//

#import <XCTest/XCTest.h>
#import <KeePassKit/KeePassKit.h>

#import "MPDocument.h"
#import "MPDocumentSplitViewController.h"

@interface MPToolbarValidationDocument : NSDocument
@property BOOL allowsToolbarAction;
@end

@implementation MPToolbarValidationDocument
- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
  return self.allowsToolbarAction;
}
@end

@interface MPToolbarValidationSplitController : MPDocumentSplitViewController
@end

@implementation MPToolbarValidationSplitController
- (void)viewDidLoad {
  // The validation test does not need database content views.
}
@end

@interface MPTestDocument : XCTestCase

@end

@implementation MPTestDocument

- (void)testCreateEmptyDocument {
  MPDocument *document = [[MPDocument alloc] init];
  XCTAssertNotNil(document, @"Document should be created");
  XCTAssertNil(document.tree, @"Allocated document should not have a tree");
  XCTAssertFalse(document.encrypted, @"Document cannot be encrypted without a tree");
  XCTAssertNil(document.compositeKey, @"Document shoudl have not key at all");
}

- (void)testInspectorToolbarValidationPreservesDocumentRestrictions {
  MPToolbarValidationDocument *document = [MPToolbarValidationDocument new];
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
  NSWindowController *windowController = [[NSWindowController alloc] initWithWindow:window];
  windowController.document = document;
  MPDocumentSplitViewController *controller = [MPToolbarValidationSplitController new];
  controller.view = window.contentView;
  NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:@"validation"];
  item.action = @selector(toggleInspector:);
  XCTAssertTrue([controller validateToolbarItem:item]);
  item.action = @selector(copyPassword:);
  XCTAssertFalse([controller validateToolbarItem:item]);
  document.allowsToolbarAction = YES;
  XCTAssertTrue([controller validateToolbarItem:item]);
  windowController.document = nil;
}

- (void)testCreateUntitledDocument {
  MPDocument *document = [[MPDocument alloc] initWithType:@"" error:nil];
  XCTAssertNotNil(document, @"Document should be created");
  KPKFileVersion kdb = { KPKDatabaseFormatKdb, kKPKKdbFileVersion };
  XCTAssertEqual(NSOrderedSame, KPKFileVersionCompare(kdb, document.tree.minimumVersion), @"Tree should be Legacy Version in default case");
  XCTAssertFalse(document.encrypted, @"Document cannot be encrypted at creation");
  XCTAssertFalse(document.compositeKey.hasKeys, @"Document has no Password/Keyfile and thus is not secured");

}

@end
