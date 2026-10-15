//
//  MPAddCustomFieldContextMenuDelegate.m
//  MacPass
//
//  Created by Michael Starke on 05.12.17.
//  Copyright © 2017 HicknHack Software GmbH. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#import "MPAddCustomFieldContextMenuDelegate.h"
#import "KeePassKit/KeePassKit.h"

#import "MPActionHelper.h"
#import "MPEntryInspectorViewController.h"

/*
 HmacOtp-Secret (the UTF-8 representation of the value is the secret),
 HmacOtp-Secret-Hex (secret as hex string),
 HmacOtp-Secret-Base32 (secret as Base32 string)
 HmacOtp-Secret-Base64 (secret as Base64 string)
 
 HmacOtp-Counter field.
 */

@interface MPAddCustomFieldContextMenuDelegate ()
@property (readonly, nonatomic) KPKEntry *entry;
@end

@implementation MPAddCustomFieldContextMenuDelegate

- (KPKEntry *)entry {
  KPKEntry *entry = self.viewController.representedObject;
  if([entry isKindOfClass:KPKEntry.class]) {
    return entry;
  }
  return nil;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
  [menu removeAllItems];
  [self _setupHOTPMenuItemsToMenu:menu];
  [self _setupTOTPMenuItemsToMenu:menu];
}

/* HMAC OTP */
- (void)_setupHOTPMenuItemsToMenu:(NSMenu *)menu {
  
}
- (IBAction)_setupHMACConfig:(id)sender {
  
}
- (IBAction)_delteHMACConfig:(id)sender {
  
}

/* Time OPT*/
- (void)_setupTOTPMenuItemsToMenu:(NSMenu *)menu {
  BOOL hasTimeOTP = self.entry.hasTimeOTP;
  NSString *title = hasTimeOTP
  ? NSLocalizedStringWithDefaultValue(@"EDIT_TOTP", nil, NSBundle.mainBundle, @"Edit Verification Code…", @"Menu item to edit the verification code (TOTP) of an entry")
  : NSLocalizedStringWithDefaultValue(@"SETUP_TOTP", nil, NSBundle.mainBundle, @"Set Up Verification Code…", @"Menu item to set up the verification code (TOTP) of an entry");
  NSMenuItem *setupItem = [[NSMenuItem alloc] initWithTitle:title action:@selector(showOTPSetup:) keyEquivalent:@""];
  setupItem.target = self.viewController;
  /* the popover points at the button that opened this menu */
  if([self.viewController isKindOfClass:MPEntryInspectorViewController.class]) {
    setupItem.representedObject = ((MPEntryInspectorViewController *)self.viewController).addCustomFieldButton;
  }
  [menu addItem:setupItem];
  if(hasTimeOTP) {
    /* the window controller asks for confirmation */
    NSMenuItem *removeItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedStringWithDefaultValue(@"REMOVE_TOTP", nil, NSBundle.mainBundle, @"Remove Verification Code", @"Menu item to remove the verification code (TOTP) of an entry") action:[MPActionHelper actionOfType:MPActionRemoveTimeOTP] keyEquivalent:@""];
    [menu addItem:removeItem];
  }
}

- (IBAction)_setupTOTPSettings:(id)sender {}
- (IBAction)_deleteTOTPSettings:(id)sender {}

@end
