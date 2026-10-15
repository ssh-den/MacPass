//
//  MPTOTPSetupViewController.h
//  MacPass
//
//  Created by Michael Starke on 10.12.20.
//  Copyright © 2020 HicknHack Software GmbH. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "MPViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// Sets up the verification code (TOTP) of the represented entry. Saving
/// notifies the observer, so the entry's history and undo are recorded.
@interface MPTOTPSetupViewController : MPViewController <NSTextFieldDelegate>

@end

NS_ASSUME_NONNULL_END
