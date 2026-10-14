#import "MPAutoFillDomain.h"
#import <arpa/inet.h>

// Canonical spelling of an IP address literal, or nil.
static NSString *MPCanonicalAddress(int family, NSString *value) {
  unsigned char address[sizeof(struct in6_addr)];
  char result[INET6_ADDRSTRLEN];
  if(inet_pton(family, value.UTF8String, address) != 1 || !inet_ntop(family, address, result, sizeof(result))) return nil;
  return [NSString stringWithUTF8String:result];
}

static NSString *MPUnbracketed(NSString *value) {
  return [value hasPrefix:@"["] && [value hasSuffix:@"]"] ? [value substringWithRange:NSMakeRange(1, value.length - 2)] : value;
}

NSDictionary<NSString *, NSString *> *MPAutoFillNormalizedService(NSString *value) {
  if(![value isKindOfClass:NSString.class] || value.length == 0 || value.length > 4096) return nil;
  NSString *input = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if([input rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
  if([input rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return nil;
  NSString *address = MPCanonicalAddress(AF_INET6, MPUnbracketed(input));
  if(address) return @{@"host": address, @"port": @""};
  NSString *urlString = [input containsString:@"://"] ? input : [@"https://" stringByAppendingString:input];
  NSURLComponents *url = [NSURLComponents componentsWithString:urlString];
  NSString *scheme = url.scheme.lowercaseString;
  if(![@[@"https", @"http"] containsObject:scheme] || url.user || url.password) return nil;
  // An invalid explicit port must not become an unrestricted host identity.
  NSInteger number = url.port.integerValue;
  if(url.port && (number <= 0 || number > 65535)) return nil;
  BOOL defaultPort = !url.port || ([scheme isEqual:@"https"] && number == 443) || ([scheme isEqual:@"http"] && number == 80);
  NSString *port = defaultPort ? @"" : [NSString stringWithFormat:@"%ld", (long)number];
  // NSURL's host is the ASCII IDNA representation, including on macOS 13.
  NSString *host = MPUnbracketed(url.URL.host.lowercaseString ?: @"");
  if(host.length == 0) return nil;
  address = MPCanonicalAddress(AF_INET6, host);
  if(address) return @{@"host": address, @"port": port};
  if([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
  if(host.length == 0 || host.length > 253) return nil;
  address = MPCanonicalAddress(AF_INET, host);
  if(address) return @{@"host": address, @"port": port};
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-."];
  if([host rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
  // Reject alternate numeric IPv4 spellings instead of interpreting them as domains.
  if([host rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789."].invertedSet].location == NSNotFound) return nil;
  for(NSString *label in [host componentsSeparatedByString:@"."]) {
    if(label.length == 0 || label.length > 63 || [label hasPrefix:@"-"] || [label hasSuffix:@"-"]) return nil;
  }
  return @{@"host": host, @"port": port};
}

NSString *MPAutoFillNormalizedHost(NSString *value) { return MPAutoFillNormalizedService(value)[@"host"] ?: @""; }

BOOL MPAutoFillServiceMatches(NSString *entryHost, NSString *entryPort, NSString *requestHost, NSString *requestPort) {
  if(![entryHost isKindOfClass:NSString.class] || ![requestHost isKindOfClass:NSString.class] ||
     entryHost.length == 0 || requestHost.length == 0) return NO;
  // Match by host regardless of port.
  return [entryHost isEqual:requestHost] || [entryHost isEqual:[@"www." stringByAppendingString:requestHost]] ||
    [requestHost isEqual:[@"www." stringByAppendingString:entryHost]];
}

BOOL MPAutoFillEntryMatchesServices(NSDictionary *entry, NSArray<NSDictionary *> *services) {
  for(NSDictionary *service in services) {
    if(MPAutoFillServiceMatches(entry[@"host"], entry[@"port"], service[@"host"], service[@"port"])) return YES;
  }
  return NO;
}

// Where the query first occurs in the text it searches: title, user, database
// name and host, joined so a query can span fields, e.g. a title and a user.
static NSUInteger MPQueryLocation(NSDictionary *entry, NSString *query) {
  NSMutableArray *fields = NSMutableArray.array;
  for(NSString *key in @[@"title", @"user", @"database", @"host"]) {
    if([entry[key] isKindOfClass:NSString.class]) [fields addObject:entry[key]];
  }
  NSString *text = [fields componentsJoinedByString:@" "];
  return [text rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location;
}

BOOL MPAutoFillEntryMatchesQuery(NSDictionary *entry, NSString *query) {
  return query.length == 0 || MPQueryLocation(entry, query) != NSNotFound;
}

BOOL MPAutoFillEntryBeginsWithQuery(NSDictionary *entry, NSString *query) {
  return query.length == 0 || MPQueryLocation(entry, query) == 0;
}
