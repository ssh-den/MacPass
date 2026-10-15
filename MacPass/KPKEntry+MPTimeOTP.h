//
//  KPKEntry+MPTimeOTP.h
//  MacPass
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

#import <KeePassKit/KeePassKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface KPKEntry (MPTimeOTP)

/// The attributes holding TOTP settings in every format KeePassKit reads:
/// KeePass (TimeOtp-*), TrayTOTP (TOTP Seed, TOTP Settings) and the otpauth URL
/// (otp). HMAC-OTP settings, including an otpauth://hotp URL, are not included.
@property (nonatomic, readonly, copy) NSArray<KPKAttribute *> *timeOTPAttributes;

/// The key of a setup key as websites show it: Base32, in any case, with
/// optional spaces, hyphens and padding. nil if it is empty or not Base32.
+ (nullable NSData *)timeOTPKeyFromSetupKey:(NSString *)setupKey;

/// Saves the generator like -[KPKOTPGenerator saveToEntry:], but always replaces
/// the stored secret and keeps TOTP Settings readable. KeePassKit alone leaves an
/// older secret in TimeOtp-Secret-Base32/-Base64 and writes the settings as
/// "period:digits", which neither it nor TrayTOTP reads back.
- (void)saveTimeOTPGenerator:(KPKTimeOTPGenerator *)generator;

@end

NS_ASSUME_NONNULL_END
