#import <Foundation/Foundation.h>

// {"host", "port"} from one parse, or nil without a valid host. The host is
// exact (no suffix or substring matching); the port is an explicit non-default
// port or an empty string.
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *MPAutoFillNormalizedService(NSString *value);
// The host part of MPAutoFillNormalizedService, or an empty string.
FOUNDATION_EXPORT NSString *MPAutoFillNormalizedHost(NSString *value);
// Same host, or the same host with one leading "www." label. No other
// subdomain or registrable-domain matching. Ports do not affect matching.
FOUNDATION_EXPORT BOOL MPAutoFillServiceMatches(NSString *entryHost, NSString *entryPort, NSString *requestHost, NSString *requestPort);
// Whether a catalog entry's host matches any of the requesting services.
FOUNDATION_EXPORT BOOL MPAutoFillEntryMatchesServices(NSDictionary *entry, NSArray<NSDictionary *> *services);
// The picker's search, applied by the host and the extension alike: a case- and
// diacritic-insensitive substring of title, user, database name and host, in
// that order. An empty or nil query matches every entry.
FOUNDATION_EXPORT BOOL MPAutoFillEntryMatchesQuery(NSDictionary *entry, NSString *query);
// Whether that text begins with the query: the title does, and the query may
// run on into the user. Such accounts are listed ahead of other matches.
FOUNDATION_EXPORT BOOL MPAutoFillEntryBeginsWithQuery(NSDictionary *entry, NSString *query);
