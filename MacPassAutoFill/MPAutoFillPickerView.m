#import "MPAutoFillPickerView.h"

// Margin around the panel's content.
static const CGFloat MPAutoFillPanelInset = 20;

@interface MPAutoFillPickerView () <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
@property (weak) id<MPAutoFillPickerViewDelegate> delegate;
@property (copy) NSArray<NSDictionary *> *entries;
// Set while showEntries: selects a row, so only user selections are reported.
@property BOOL selectingEntries;
@property NSTextField *titleLabel;
@property NSTextField *statusLabel;
@property NSView *authenticationContainer;
@property NSSearchField *search;
@property NSButton *allEntriesButton;
@property NSTableView *table;
@property NSScrollView *scrollView;
@property NSButton *fillButton;
@property NSButton *handoffButton;
@property NSStackView *footer;
@property NSStackView *content;
@property NSButton *openButton;
@property NSButton *systemAuthenticationButton;
@property NSAlert *confirmation;
@end

@implementation MPAutoFillPickerView

- (instancetype)initWithDelegate:(id<MPAutoFillPickerViewDelegate>)delegate {
  if((self = [super initWithFrame:NSMakeRect(0, 0, 420, 180)])) {
    _delegate = delegate;
    _entries = @[];
    _interactive = YES;
    [self buildViews];
    [self applyState];
  }
  return self;
}

- (void)buildViews {
  self.titleLabel = [NSTextField labelWithString:MPAutoFillLocalized(@"AUTOFILL_EXT_TITLE", @"MacPass AutoFill")];
  self.titleLabel.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
  self.statusLabel = [NSTextField wrappingLabelWithString:@""];
  self.statusLabel.accessibilityLabel = MPAutoFillLocalized(@"AUTOFILL_EXT_STATUS", @"AutoFill status");
  self.authenticationContainer = [[NSView alloc] initWithFrame:NSZeroRect];
  [self.authenticationContainer.heightAnchor constraintEqualToConstant:72].active = YES;
  self.search = [[NSSearchField alloc] initWithFrame:NSZeroRect];
  self.search.placeholderString = MPAutoFillLocalized(@"AUTOFILL_EXT_SEARCH", @"Search accounts");
  self.search.accessibilityLabel = self.search.placeholderString;
  self.search.delegate = self;
  self.allEntriesButton = [NSButton checkboxWithTitle:MPAutoFillLocalized(@"AUTOFILL_EXT_SHOW_ALL", @"Show all entries") target:self.delegate action:@selector(toggleAllEntries:)];
  self.allEntriesButton.toolTip = MPAutoFillLocalized(@"AUTOFILL_EXT_SHOW_ALL_TOOLTIP", @"Requires Touch ID or your macOS password.");
  self.table = [[NSTableView alloc] initWithFrame:NSZeroRect];
  self.table.delegate = self;
  self.table.dataSource = self;
  self.table.rowHeight = 44;
  self.table.allowsEmptySelection = NO;
  self.table.target = self.delegate;
  self.table.doubleAction = @selector(fill:);
  self.table.accessibilityLabel = MPAutoFillLocalized(@"AUTOFILL_EXT_TABLE", @"Accounts in the active MacPass database");
  NSTableColumn *account = [[NSTableColumn alloc] initWithIdentifier:@"account"];
  account.title = MPAutoFillLocalized(@"AUTOFILL_EXT_COLUMN_ACCOUNT", @"Account / database"); account.width = 340;
  [self.table addTableColumn:account];
  NSTableColumn *site = [[NSTableColumn alloc] initWithIdentifier:@"site"];
  site.title = MPAutoFillLocalized(@"AUTOFILL_EXT_COLUMN_SITE", @"Website"); site.width = 160;
  [self.table addTableColumn:site];
  self.scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  self.scrollView.hasVerticalScroller = YES;
  self.scrollView.documentView = self.table;
  self.scrollView.borderType = NSBezelBorder;
  [self.scrollView.heightAnchor constraintEqualToConstant:180].active = YES;
  self.fillButton = [NSButton buttonWithTitle:MPAutoFillLocalized(@"AUTOFILL_EXT_FILL", @"Fill password") target:self.delegate action:@selector(fill:)];
  self.fillButton.keyEquivalent = @"\r";
  self.handoffButton = [NSButton buttonWithTitle:MPAutoFillLocalized(@"AUTOFILL_EXT_UNLOCK", @"Unlock in MacPass") target:self.delegate action:@selector(handoff:)];
  self.handoffButton.keyEquivalent = @"\r";
  self.openButton = [NSButton buttonWithTitle:MPAutoFillLocalized(@"AUTOFILL_EXT_OPEN", @"Open MacPass") target:self.delegate action:@selector(openMacPass:)];
  self.systemAuthenticationButton = [NSButton buttonWithTitle:MPAutoFillLocalized(@"AUTOFILL_EXT_OTHER_SIGN_IN", @"Other sign-in options…") target:self.delegate action:@selector(useSystemAuthentication:)];
  self.systemAuthenticationButton.toolTip = MPAutoFillLocalized(@"AUTOFILL_EXT_OTHER_SIGN_IN_TOOLTIP", @"Open system authentication to use your macOS password.");
  NSButton *cancelButton = [NSButton buttonWithTitle:MPAutoFillLocalized(@"AUTOFILL_EXT_CANCEL", @"Cancel") target:self.delegate action:@selector(cancel:)];
  cancelButton.keyEquivalent = @"\e";
  // One row in the macOS order: alternatives at the leading edge, Cancel and
  // the default button at the trailing edge.
  self.footer = [[NSStackView alloc] initWithFrame:NSZeroRect];
  [self.footer setViews:@[self.openButton, self.systemAuthenticationButton] inGravity:NSStackViewGravityLeading];
  [self.footer setViews:@[cancelButton, self.handoffButton, self.fillButton] inGravity:NSStackViewGravityTrailing];
  NSStackView *stack = [NSStackView stackViewWithViews:@[self.titleLabel, self.statusLabel, self.authenticationContainer, self.search, self.allEntriesButton, self.scrollView, self.footer]];
  self.content = stack;
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 12;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:MPAutoFillPanelInset],
    [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-MPAutoFillPanelInset],
    [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:MPAutoFillPanelInset],
    [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-MPAutoFillPanelInset],
    [self.search.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    [self.authenticationContainer.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    [self.scrollView.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    [self.footer.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
  ]];
}

#pragma mark State

- (void)setMode:(MPAutoFillPickerMode)mode { _mode = mode; [self applyState]; }
- (void)setFillEnabled:(BOOL)fillEnabled { _fillEnabled = fillEnabled; [self applyState]; }
- (void)setUnlockEnabled:(BOOL)unlockEnabled { _unlockEnabled = unlockEnabled; [self applyState]; }
- (void)setInteractive:(BOOL)interactive { _interactive = interactive; [self applyState]; }
- (void)setShowsAllEntries:(BOOL)showsAllEntries { _showsAllEntries = showsAllEntries; [self applyState]; }
- (NSString *)status { return self.statusLabel.stringValue; }
- (void)setStatus:(NSString *)status { self.statusLabel.stringValue = status; }

- (void)setAuthenticationView:(NSView *)view {
  [_authenticationView removeFromSuperview];
  _authenticationView = view;
  if(view) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.authenticationContainer addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
      [view.centerXAnchor constraintEqualToAnchor:self.authenticationContainer.centerXAnchor],
      [view.centerYAnchor constraintEqualToAnchor:self.authenticationContainer.centerYAnchor],
      [view.widthAnchor constraintEqualToConstant:64],
      [view.heightAnchor constraintEqualToConstant:64],
    ]];
  }
  [self applyState];
  if(view) [self layoutSubtreeIfNeeded];
}

// The only place that shows, hides, enables or disables controls.
- (void)applyState {
  MPAutoFillPickerMode mode = self.mode;
  BOOL list = mode == MPAutoFillPickerModeList;
  BOOL system = mode == MPAutoFillPickerModeSystemAuthentication;
  BOOL authenticating = system || mode == MPAutoFillPickerModeEmbeddedAuthentication;
  BOOL embeddedView = mode == MPAutoFillPickerModeEmbeddedAuthentication && self.authenticationView;
  // The system dialog brings its own title and Cancel.
  self.titleLabel.hidden = system;
  self.footer.hidden = system;
  self.openButton.hidden = authenticating;
  self.authenticationContainer.hidden = !embeddedView;
  self.systemAuthenticationButton.hidden = !embeddedView;
  self.search.hidden = !list;
  self.allEntriesButton.hidden = !list;
  self.scrollView.hidden = !list;
  self.fillButton.hidden = !(list || mode == MPAutoFillPickerModeSelected);
  self.handoffButton.hidden = mode != MPAutoFillPickerModeUnlock;
  self.statusLabel.preferredMaxLayoutWidth = self.preferredWidth - 2 * MPAutoFillPanelInset;
  self.fillButton.enabled = !self.fillButton.hidden && self.fillEnabled;
  self.handoffButton.enabled = !self.handoffButton.hidden && self.unlockEnabled;
  self.search.enabled = self.interactive;
  self.table.enabled = self.interactive;
  self.allEntriesButton.enabled = self.interactive;
  self.allEntriesButton.state = self.showsAllEntries ? NSControlStateValueOn : NSControlStateValueOff;
}

- (CGFloat)preferredWidth {
  CGFloat width = 420;
  switch(self.mode) {
    case MPAutoFillPickerModeList: width = 570; break;
    case MPAutoFillPickerModeEmbeddedAuthentication:
    case MPAutoFillPickerModeSystemAuthentication: width = 360; break;
    default: break;
  }
  // Longer localized button titles widen the panel instead of overflowing it.
  return MAX(width, ceil(self.footer.fittingSize.width) + 2 * MPAutoFillPanelInset);
}

// Exactly as tall as the visible controls: no empty space below them, and
// longer status or localized text never overflows.
- (NSSize)preferredSize {
  return NSMakeSize(self.preferredWidth, ceil(self.content.fittingSize.height) + 2 * MPAutoFillPanelInset);
}

#pragma mark Entries

- (NSString *)query { return self.search.stringValue; }
- (void)clearQuery { self.search.stringValue = @""; }

- (void)showEntries:(NSArray<NSDictionary *> *)entries selecting:(NSString *)record {
  self.selectingEntries = YES;
  self.entries = entries;
  [self.table reloadData];
  NSUInteger index = [entries indexOfObjectPassingTest:^BOOL(NSDictionary *entry, NSUInteger index, BOOL *stop) { return [entry[@"record"] isEqual:record]; }];
  if(entries.count) [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:index == NSNotFound ? 0 : index] byExtendingSelection:NO];
  self.selectingEntries = NO;
}

- (NSDictionary *)selectedEntry {
  NSInteger row = self.table.selectedRow;
  return row >= 0 && row < (NSInteger)self.entries.count ? self.entries[row] : nil;
}

- (NSString *)serviceDescription:(NSDictionary *)service {
  NSString *port = [service[@"port"] isKindOfClass:NSString.class] ? service[@"port"] : @"";
  return port.length ? [NSString stringWithFormat:@"%@:%@", service[@"host"], port] : service[@"host"];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return self.entries.count; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
  NSDictionary *entry = self.entries[row];
  NSString *text = [column.identifier isEqual:@"site"] ? [self serviceDescription:entry] : [NSString stringWithFormat:@"%@ — %@\n%@", entry[@"user"], entry[@"title"], entry[@"database"]];
  NSTextField *label = [NSTextField wrappingLabelWithString:text];
  label.accessibilityLabel = text;
  return label;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
  if(!self.selectingEntries) [self.delegate pickerViewSelectionDidChange:self];
}

- (void)controlTextDidChange:(NSNotification *)notification { [self.delegate pickerViewQueryDidChange:self]; }

#pragma mark Confirmation

// Cancel is the default button: a repeated Return from the list never fills
// another site's account.
- (NSAlert *)confirmationForEntry:(NSDictionary *)entry services:(NSArray<NSDictionary *> *)services {
  NSMutableArray *requested = NSMutableArray.array;
  for(NSDictionary *service in services) [requested addObject:[self serviceDescription:service]];
  NSString *current = requested.count ? [requested componentsJoinedByString:@", "] : MPAutoFillLocalized(@"AUTOFILL_EXT_NO_REQUESTED_SITE", @"Website not provided by the system");
  NSString *saved = [entry[@"host"] length] ? [self serviceDescription:entry] : MPAutoFillLocalized(@"AUTOFILL_EXT_NO_SAVED_SITE", @"No website saved");
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = MPAutoFillLocalized(@"AUTOFILL_EXT_OTHER_SITE", @"Fill an account for another website?");
  alert.informativeText = [NSString stringWithFormat:MPAutoFillLocalized(@"AUTOFILL_EXT_OTHER_SITE_DETAIL", @"Requested website: %@\nAccount website: %@"), current, saved];
  [alert addButtonWithTitle:MPAutoFillLocalized(@"AUTOFILL_EXT_CANCEL", @"Cancel")].keyEquivalent = @"\r";
  [alert addButtonWithTitle:MPAutoFillLocalized(@"AUTOFILL_EXT_FILL", @"Fill password")];
  return alert;
}

- (void)confirmFillOfEntry:(NSDictionary *)entry forServices:(NSArray<NSDictionary *> *)services completion:(void (^)(BOOL))completion {
  NSAlert *alert = [self confirmationForEntry:entry services:services];
  self.confirmation = alert;
  __weak MPAutoFillPickerView *weakSelf = self;
  __weak NSAlert *weakAlert = alert;
  [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
    if(weakSelf.confirmation == weakAlert) weakSelf.confirmation = nil;
    completion(response == NSAlertSecondButtonReturn);
  }];
}

- (void)cancelConfirmation {
  NSAlert *alert = self.confirmation;
  self.confirmation = nil;
  if(alert) [NSApp endSheet:alert.window returnCode:NSModalResponseCancel];
}
@end
