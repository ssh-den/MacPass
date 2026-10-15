//
//  MPTOTPSetupViewController.m
//  MacPass
//
//  Created by Michael Starke on 10.12.20.
//  Copyright © 2020 HicknHack Software GmbH. All rights reserved.
//

#import "MPTOTPSetupViewController.h"
#import "NSImage+MPQRCode.h"
#import "KPKEntry+MPTimeOTP.h"
#import <KeePassKit/KeePassKit.h>

/* the message row sits below the secret */
static const NSInteger MPOTPMessageRowIndex = 2;

@interface MPTOTPSetupViewController ()
@property (strong) IBOutlet NSTextField *urlTextField;
@property (strong) IBOutlet NSTextField *secretTextField;
@property (strong) IBOutlet NSPopUpButton *algorithmPopUpButton;
@property (strong) IBOutlet NSTextField *timeStepTextField;
@property (strong) IBOutlet NSStepper *timeStepStepper;
@property (strong) IBOutlet NSPopUpButton *digitCountPopUpButton;
@property (strong) IBOutlet NSImageView *qrCodeImageView;
@property (strong) IBOutlet NSGridView *gridView;
@property (strong) IBOutlet NSPopUpButton *typePopUpButton;
@property (strong) IBOutlet NSButton *saveButton;
@property (strong) NSTextField *messageTextField;

@property (nonatomic, readonly) KPKEntry *representedEntry;
@property (copy) KPKTimeOTPGenerator *generator;
/* the last input could not be used; it stays visible for correction */
@property BOOL hasInvalidInput;

@end

typedef NS_ENUM(NSUInteger, MPOTPUpdateSource) {
  MPOTPUpdateSourceQRImage,
  MPOTPUpdateSourceURL,
  MPOTPUpdateSourceSecret,
  MPOTPUpdateSourceAlgorithm,
  MPOTPUpdateSourceTimeSlice,
  MPOTPUpdateSourceType,
  MPOTPUpdateSourceDigits,
  MPOTPUpdateSourceEntry
};

typedef NS_ENUM(NSUInteger, MPOTPType) {
  MPOTPTypeRFC,
  MPOTPTypeSteam,
  MPOTPTypeCustom
};

@implementation MPTOTPSetupViewController

- (KPKEntry *)representedEntry {
  if([self.representedObject isKindOfClass:KPKEntry.class]) {
    return (KPKEntry *)self.representedObject;
  }
  return nil;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  [self _setupView];
  [self _updateView:MPOTPUpdateSourceEntry];
}

- (IBAction)changeType:(id)sender {
  if(sender != self.typePopUpButton) {
    return; // wrong sender
  }
  [self _updateView:MPOTPUpdateSourceType];
}

- (IBAction)changeHashAlgorithm:(id)sender {
  [self _updateView:MPOTPUpdateSourceAlgorithm];
}

- (IBAction)changeDigits:(id)sender {
  [self _updateView:MPOTPUpdateSourceDigits];
}

- (IBAction)changeTimeSlice:(id)sender {
  [self _updateView:MPOTPUpdateSourceTimeSlice];
}

- (IBAction)parseQRCode:(id)sender {
  if(sender != self.qrCodeImageView) {
    return; // wrong sender
  }
  [self _updateView:MPOTPUpdateSourceQRImage];
}

- (IBAction)cancel:(id)sender {
  [self.presentingViewController dismissViewController:self];
}

- (IBAction)save:(id)sender {
  /* commit a pending edit first, it may still turn out to be invalid */
  [self.view.window makeFirstResponder:nil];
  if(!self.canSave || !self.representedEntry) {
    NSBeep();
    return;
  }
  KPKEntry *entry = self.representedEntry;
  [self.observer willChangeModelProperty];
  [entry saveTimeOTPGenerator:self.generator];
  [entry.undoManager setActionName:NSLocalizedStringWithDefaultValue(@"SETUP_TOTP_ACTION", nil, NSBundle.mainBundle, @"Change Verification Code", @"Undo action name for setting up or changing the verification code (TOTP) of an entry")];
  [self.observer didChangeModelProperty];
  [self.presentingViewController dismissViewController:self];
}

- (BOOL)canSave {
  return !self.hasInvalidInput && self.generator.key.length > 0;
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
  NSControl *control = notification.object;
  if(control == self.secretTextField) {
    [self _updateView:MPOTPUpdateSourceSecret];
  }
  else if(control == self.urlTextField) {
    [self _updateView:MPOTPUpdateSourceURL];
  }
  else if(control == self.timeStepTextField) {
    [self _updateView:MPOTPUpdateSourceTimeSlice];
  }
}

- (void)_setupView {
  /* algorithm */
  NSMenuItem *sha1Item = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"HASH_SHA1", "SHA 1 hash algoritm menu item") action:NULL keyEquivalent:@""];
  sha1Item.tag = KPKOTPHashAlgorithmSha1;
  NSMenuItem *sha256Item = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"HASH_SHA256", "SHA 256 hash algoritm menu item") action:NULL keyEquivalent:@""];
  sha256Item.tag = KPKOTPHashAlgorithmSha256;
  NSMenuItem *sha512Item = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"HASH_SHA512", "SHA 512 hash algoritm menu item") action:NULL keyEquivalent:@""];
  sha512Item.tag = KPKOTPHashAlgorithmSha512;
  
  NSAssert(self.algorithmPopUpButton.menu.numberOfItems == 0, @"Hash algorithm menu needs to be empty");
  [self.algorithmPopUpButton.menu addItem:sha1Item];
  [self.algorithmPopUpButton.menu addItem:sha256Item];
  [self.algorithmPopUpButton.menu addItem:sha512Item];
  
  self.algorithmPopUpButton.action = @selector(changeHashAlgorithm:);
  self.algorithmPopUpButton.target = self;
  
  /* digits */
  NSAssert(self.digitCountPopUpButton.menu.numberOfItems == 0, @"Digit menu needs to be empty");
  for(NSUInteger digit = 6; digit <= 8; digit++) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%ld", digit] action:NULL keyEquivalent:@""];
    item.tag = digit;
    [self.digitCountPopUpButton.menu addItem:item];
  }
  
  self.digitCountPopUpButton.action = @selector(changeDigits:);
  self.digitCountPopUpButton.target = self;
  
  
  NSAssert(self.typePopUpButton.menu.numberOfItems == 0, @"Type menu needs to be empty!");
  NSMenuItem *rfcItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"OTP_RFC", @"OTP type RFC ") action:NULL keyEquivalent:@""];
  rfcItem.tag = MPOTPTypeRFC;
  NSMenuItem *steamItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"OTP_STEAM", @"OTP type Steam ") action:NULL keyEquivalent:@""];
  steamItem.tag = MPOTPTypeSteam;
  NSMenuItem *customItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"OTP_CUSTOM", @"OTP custom type ") action:NULL keyEquivalent:@""];
  customItem.tag = MPOTPTypeCustom;
  
  [self.typePopUpButton.menu addItem:rfcItem];
  [self.typePopUpButton.menu addItem:steamItem];
  [self.typePopUpButton.menu addItem:customItem];
  
  self.typePopUpButton.action = @selector(changeType:);
  self.typePopUpButton.target = self;
  
  self.timeStepTextField.stringValue = @"";
  /* a time step of 0 has no valid codes */
  self.timeStepStepper.minValue = 1;
  self.timeStepStepper.integerValue = KPKTimeOTPDefaultTimeSlice;

  self.timeStepStepper.action = @selector(changeTimeSlice:);
  /*[self.timeStepTextField bind:NSValueBinding
                      toObject:self
                   withKeyPath:NSStringFromSelector(@selector(timeSlice))
                       options:nil];
  [self.timeStepStepper bind:NSValueBinding
                    toObject:self
                 withKeyPath:NSStringFromSelector(@selector(timeSlice))
                     options:@{ NSConditionallySetsEnabledBindingOption:@(NO), NSConditionallySetsEditableBindingOption:@(NO)}];*/
  
  self.secretTextField.delegate = self;
  self.urlTextField.delegate = self;

  /* hints and input errors */
  self.messageTextField = [NSTextField wrappingLabelWithString:@""];
  self.messageTextField.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  self.messageTextField.preferredMaxLayoutWidth = 180;
  [self.gridView insertRowAtIndex:MPOTPMessageRowIndex withViews:@[NSGridCell.emptyContentView, self.messageTextField, NSGridCell.emptyContentView]];
  [self.gridView mergeCellsInHorizontalRange:NSMakeRange(1, 2) verticalRange:NSMakeRange(MPOTPMessageRowIndex, 1)];
}

- (void)_showMessage:(NSString *)message isError:(BOOL)isError {
  self.messageTextField.stringValue = message ?: @"";
  self.messageTextField.textColor = isError ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
  [self.gridView rowAtIndex:MPOTPMessageRowIndex].hidden = (message.length == 0);
}

/* keeps the rejected input in its field so it can be corrected */
- (void)_rejectInputWithMessage:(NSString *)message {
  self.hasInvalidInput = YES;
  [self _showMessage:message isError:YES];
  self.saveButton.enabled = NO;
}

- (void)_updateView:(MPOTPUpdateSource)source {
  /*
   MPOTPUpdateSourceQRImage,
   MPOTPUpdateSourceURL,
   MPOTPUpdateSourceSecret,
   MPOTPUpdateSourceAlgorithm,
   MPOTPUpdateSourceTimeSlice,
   MPOTPUpdateSourceType,
   MPOTPUpdateSourceEntry
   */
  if(source != MPOTPUpdateSourceEntry) {
    NSAssert(self.generator, @"OTP Generator needs to be set when change source is not entry");
  }
  
  BOOL enableCustomSettings = NO;
  switch(source) {
    case MPOTPUpdateSourceType: {
      MPOTPType otpType = self.typePopUpButton.selectedTag;
      NSData *oldKey = self.generator.key;
      switch(otpType) {
        case MPOTPTypeCustom:
          enableCustomSettings = YES;
        case MPOTPTypeRFC:
          self.generator = [[KPKTimeOTPGenerator alloc] init]; // initialize a RFC otp generator for custom and rfc types
          self.generator.key = oldKey;
          break;
        case MPOTPTypeSteam:
          self.generator = [[KPKSteamOTPGenerator alloc] init]; // initialize a default Steam OTP generator
          self.generator.key = oldKey;
      }
    }
      break;
    case MPOTPUpdateSourceQRImage: {
      NSString *qrCodeString = self.qrCodeImageView.image.QRCodeString;
      KPKTimeOTPGenerator *generator = [self _generatorWithURLString:qrCodeString];
      if(!generator) {
        [self _rejectInputWithMessage:NSLocalizedStringWithDefaultValue(@"TOTP_SETUP_INVALID_QR_CODE", nil, NSBundle.mainBundle, @"This image contains no QR code for verification codes.", @"Shown when a dropped or pasted image holds no otpauth QR code")];
        return;
      }
      self.generator = generator;
      break;
    }
    case MPOTPUpdateSourceURL:{
      KPKTimeOTPGenerator *generator = [self _generatorWithURLString:self.urlTextField.stringValue];
      if(!generator) {
        [self _rejectInputWithMessage:NSLocalizedStringWithDefaultValue(@"TOTP_SETUP_INVALID_URL", nil, NSBundle.mainBundle, @"This is not an otpauth:// link for verification codes.", @"Shown when the entered setup URL is not a TOTP otpauth URL")];
        return;
      }
      self.generator = generator;
      break;
    }
      
    case MPOTPUpdateSourceEntry:
      if(self.representedEntry.hasTimeOTP) {
        if(self.representedEntry.hasSteamOTP) {
          self.generator = [[KPKSteamOTPGenerator alloc] initWithAttributes:self.representedEntry.attributes];
        }
        else {
          self.generator = [[KPKTimeOTPGenerator alloc] initWithAttributes:self.representedEntry.attributes];
        }
      }
      else {
        self.generator = [[KPKTimeOTPGenerator alloc] init];
      }
      break;
    case MPOTPUpdateSourceSecret: {
      NSString *setupKey = self.secretTextField.stringValue;
      NSData *key = [KPKEntry timeOTPKeyFromSetupKey:setupKey];
      if(!key && [setupKey stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0) {
        [self _rejectInputWithMessage:NSLocalizedStringWithDefaultValue(@"TOTP_SETUP_INVALID_SECRET", nil, NSBundle.mainBundle, @"This is not a valid setup key. It uses the letters A–Z and the digits 2–7; spaces do not matter.", @"Shown when the entered TOTP setup key is not Base32")];
        return;
      }
      self.generator.key = key ?: NSData.data;
      break;
    }
    case MPOTPUpdateSourceAlgorithm:
      self.generator.hashAlgorithm = (KPKOTPHashAlgorithm)self.algorithmPopUpButton.selectedTag;
      break;
    case MPOTPUpdateSourceTimeSlice:
      self.generator.timeSlice = self.timeStepStepper.integerValue;
      break;
    case MPOTPUpdateSourceDigits:
      self.generator.numberOfDigits = self.digitCountPopUpButton.selectedTag;
      break;
    default:
      break;
  }
  
  /*
   The KPKOTPGenerator is the sole data source. We do not need to query anything else
   */
  
  if(!self.generator) {
    self.generator = [[KPKTimeOTPGenerator alloc] init];
  }
  self.hasInvalidInput = NO;

  /* update display data with current generator */
  BOOL isSteam = [self.generator isKindOfClass:KPKSteamOTPGenerator.class];
  
  if((self.generator.isRFC6238 && !enableCustomSettings) || isSteam) {
    if(isSteam) {
      [self.typePopUpButton selectItemWithTag:MPOTPTypeSteam];
    }
    else {
      [self.typePopUpButton selectItemWithTag:MPOTPTypeRFC];
    }
    self.digitCountPopUpButton.enabled = NO;
    self.algorithmPopUpButton.enabled = NO;
    self.timeStepStepper.enabled = NO;
    self.timeStepTextField.enabled = NO;
  }
  else {
    [self.typePopUpButton selectItemWithTag:MPOTPTypeCustom];
    self.digitCountPopUpButton.enabled = YES;
    self.algorithmPopUpButton.enabled = YES;
    self.timeStepStepper.enabled = YES;
    self.timeStepTextField.enabled = YES;
  }
  
  BOOL hasKey = self.generator.key.length > 0;
  NSURL *authURL;
  if(hasKey && isSteam) {
    authURL = [NSURL URLWIthSteamOTPKey:self.generator.key issuer:self.representedEntry.title];
  }
  else if(hasKey) {
    authURL = [NSURL URLWithTimeOTPKey:self.generator.key
                             algorithm:self.generator.hashAlgorithm
                                issuer:self.representedEntry.title
                                period:self.generator.timeSlice
                                digits:self.generator.numberOfDigits];
  }

  /* without a key there is nothing to show as URL or QR code yet */
  BOOL validURL = authURL && authURL.isTimeOTPURL;
  self.urlTextField.stringValue = validURL ? authURL.absoluteString : @"";
  self.qrCodeImageView.image = validURL ? [NSImage QRCodeImageWithString:authURL.absoluteString] : nil;

  NSString *secret = hasKey ? [self.generator.key base32EncodedStringWithOptions:0] : nil;
  self.secretTextField.stringValue = secret ? secret : @"";
  [self.algorithmPopUpButton selectItemWithTag:self.generator.hashAlgorithm];
  [self.digitCountPopUpButton selectItemWithTag:self.generator.numberOfDigits];
  self.timeStepStepper.integerValue = self.generator.timeSlice;
  self.timeStepTextField.stringValue = self.timeStepStepper.stringValue;

  [self _showMessage:(hasKey ? nil : NSLocalizedStringWithDefaultValue(@"TOTP_SETUP_HINT", nil, NSBundle.mainBundle, @"Paste the setup key or the otpauth:// link from the website, or drop its QR code image above.", @"Hint in the verification code setup while no key is entered")) isError:NO];
  self.saveButton.enabled = self.canSave;
}

/* nil unless the string is an otpauth URL for time based codes */
- (KPKTimeOTPGenerator *)_generatorWithURLString:(NSString *)string {
  NSURL *url = string.length > 0 ? [NSURL URLWithString:[string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]] : nil;
  KPKTimeOTPGenerator *generator;
  if(url.isSteamOTPURL) {
    generator = [[KPKSteamOTPGenerator alloc] initWithURL:url.absoluteString];
  }
  else if(url.isTimeOTPURL) {
    generator = [[KPKTimeOTPGenerator alloc] initWithURL:url.absoluteString];
  }
  return generator.key.length > 0 ? generator : nil;
}

@end
