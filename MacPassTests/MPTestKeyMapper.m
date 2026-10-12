//
//  MPTestKeyMapper.m
//  MacPass
//
//  Created by Michael Starke on 18/01/2017.
//  Copyright © 2017 HicknHack Software GmbH. All rights reserved.
//

#import <XCTest/XCTest.h>
#import <Carbon/Carbon.h>

#import "MPKeyMapper.h"


@interface MPTestKeyMapper : XCTestCase

@end

@implementation MPTestKeyMapper

- (void)testKeyMapper {
  // Round-trip characters produced by this layout, including modified keys.
  CGEventFlags modifiers[] = {0, kCGEventFlagMaskShift, kCGEventFlagMaskAlternate,
                             kCGEventFlagMaskShift | kCGEventFlagMaskAlternate};
  NSUInteger checked = 0;
  for(CGKeyCode keyCode = 0; keyCode < 128; keyCode++) {
    for(NSUInteger index = 0; index < sizeof(modifiers) / sizeof(modifiers[0]); index++) {
      NSString *character = [MPKeyMapper stringForModifiedKey:MPMakeModifiedKey(modifiers[index], keyCode)];
      if(character.length != 1) {
        continue;
      }
      MPModifiedKey key = [MPKeyMapper modifiedKeyForCharacter:character];
      XCTAssertNotEqual(key.keyCode, kMPUnknownKeyCode, @"No reverse mapping for %@", character);
      XCTAssertEqualObjects([MPKeyMapper stringForModifiedKey:key], character);
      checked++;
    }
  }
  XCTAssertGreaterThan(checked, 0u);
}

- (void)testUnmappableCharacterReturnsUnknownKey {
  MPModifiedKey key = [MPKeyMapper modifiedKeyForCharacter:@"😀"];
  XCTAssertEqual(key.keyCode, kMPUnknownKeyCode);
  XCTAssertNil([MPKeyMapper stringForModifiedKey:key]);
}

@end
