//
//  KPKEntry+MPTimeOTP.m
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

#import "KPKEntry+MPTimeOTP.h"

@implementation KPKEntry (MPTimeOTP)

- (NSArray<KPKAttribute *> *)timeOTPAttributes {
  NSArray *keys = @[kKPKAttributeKeyTimeOTPSecret, kKPKAttributeKeyTimeOTPSecretHex, kKPKAttributeKeyTimeOTPSecretBase32,
                    kKPKAttributeKeyTimeOTPSecretBase64, kKPKAttributeKeyTimeOTPLength, kKPKAttributeKeyTimeOTPPeriod,
                    kKPKAttributeKeyTimeOTPAlgorithm, kKPKAttributeKeyTimeOTPSeed, kKPKAttributeKeyTimeOTPSettings];
  NSMutableArray *attributes = [[NSMutableArray alloc] init];
  for(NSString *key in keys) {
    KPKAttribute *attribute = [self attributeWithKey:key];
    if(attribute) {
      [attributes addObject:attribute];
    }
  }
  KPKAttribute *url = [self attributeWithKey:kKPKAttributeKeyOTPOAuthURL];
  /* an otpauth://hotp URL belongs to the counter based settings */
  if(url && ![NSURL URLWithString:url.value].isHmacOTPURL) {
    [attributes addObject:url];
  }
  return [attributes copy];
}

+ (NSData *)timeOTPKeyFromSetupKey:(NSString *)setupKey {
  NSMutableString *key = [[NSMutableString alloc] init];
  for(NSString *part in [setupKey.uppercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
    [key appendString:[part stringByReplacingOccurrencesOfString:@"-" withString:@""]];
  }
  while([key hasSuffix:@"="]) {
    [key deleteCharactersInRange:NSMakeRange(key.length - 1, 1)];
  }
  NSCharacterSet *alphabet = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"];
  if(key.length == 0 || [key rangeOfCharacterFromSet:alphabet.invertedSet].location != NSNotFound) {
    return nil;
  }
  /* Base32 leaves 0, 2, 4, 5 or 7 characters in the last block of 8 */
  if(![@[@0, @2, @4, @5, @7] containsObject:@(key.length % 8)]) {
    return nil;
  }
  NSData *data = [NSData dataWithBase32EncodedString:key];
  return data.length > 0 ? data : nil;
}

- (void)saveTimeOTPGenerator:(KPKTimeOTPGenerator *)generator {
  NSArray *secretKeys = @[kKPKAttributeKeyTimeOTPSecret, kKPKAttributeKeyTimeOTPSecretHex, kKPKAttributeKeyTimeOTPSecretBase32,
                          kKPKAttributeKeyTimeOTPSecretBase64];
  for(NSString *key in secretKeys) {
    KPKAttribute *attribute = [self attributeWithKey:key];
    if(attribute) {
      [self removeCustomAttribute:attribute];
    }
  }
  /* without a secret attribute KeePassKit stores the key as TimeOtp-Secret-Base32 */
  [generator saveToEntry:self];
  KPKAttribute *settings = [self attributeWithKey:kKPKAttributeKeyTimeOTPSettings];
  if(settings && ![generator isKindOfClass:KPKSteamOTPGenerator.class]) {
    settings.value = [NSString stringWithFormat:@"%ld;%ld", (long)generator.timeSlice, (long)generator.numberOfDigits];
  }
}

@end
