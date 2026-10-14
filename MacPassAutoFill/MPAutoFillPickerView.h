#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

#define MPAutoFillLocalized(key, value) NSLocalizedStringWithDefaultValue(key, nil, NSBundle.mainBundle, value, @"Password AutoFill extension")

typedef NS_ENUM(NSInteger, MPAutoFillPickerMode) {
  MPAutoFillPickerModeMessage,                // Status text only
  MPAutoFillPickerModeUnlock,                 // Status and "Unlock in MacPass"
  MPAutoFillPickerModeList,                   // Search, "Show all entries", accounts and "Fill"
  MPAutoFillPickerModeSelected,               // The selected system suggestion and "Fill"
  MPAutoFillPickerModeEmbeddedAuthentication, // Touch ID view with a system fallback
  MPAutoFillPickerModeSystemAuthentication    // Waits for the system dialog
};

@class MPAutoFillPickerView;

// User input. The delegate decides what it means; the view never interprets
// catalog or request state.
@protocol MPAutoFillPickerViewDelegate <NSObject>
- (void)fill:(nullable id)sender;
- (void)handoff:(nullable id)sender;
- (void)openMacPass:(nullable id)sender;
- (void)useSystemAuthentication:(nullable id)sender;
- (void)cancel:(nullable id)sender;
- (void)toggleAllEntries:(nullable id)sender;
- (void)pickerViewSelectionDidChange:(MPAutoFillPickerView *)view;
- (void)pickerViewQueryDidChange:(MPAutoFillPickerView *)view;
@end

// The extension's account picker. It renders what its controller sets: the
// mode decides which controls exist, the flags whether they can be used.
API_AVAILABLE(macos(13.0))
@interface MPAutoFillPickerView : NSView
- (instancetype)initWithDelegate:(id<MPAutoFillPickerViewDelegate>)delegate;
@property (nonatomic) MPAutoFillPickerMode mode;
@property (readonly) NSSize preferredSize; // For the current mode.
@property (nonatomic, copy) NSString *status;
@property (nonatomic) BOOL fillEnabled;
@property (nonatomic) BOOL unlockEnabled;
@property (nonatomic) BOOL interactive; // Search, list and "Show all entries".
@property (nonatomic) BOOL showsAllEntries;
// Shown in the embedded authentication mode; nil removes it.
@property (nonatomic, nullable) NSView *authenticationView;

@property (readonly, copy) NSString *query;
@property (readonly, copy) NSArray<NSDictionary *> *entries;
@property (readonly, nullable) NSDictionary *selectedEntry;
// Selects the record if listed, else the first entry. Reports no selection
// change: the caller reads selectedEntry afterwards.
- (void)showEntries:(NSArray<NSDictionary *> *)entries selecting:(nullable NSString *)record;
- (void)clearQuery;
- (void)confirmFillOfEntry:(NSDictionary *)entry forServices:(NSArray<NSDictionary *> *)services completion:(void (^)(BOOL fill))completion;
- (void)cancelConfirmation;

@property (readonly) NSTextField *titleLabel;
@property (readonly) NSTextField *statusLabel;
@property (readonly) NSView *authenticationContainer;
@property (readonly) NSSearchField *search;
@property (readonly) NSButton *allEntriesButton;
@property (readonly) NSTableView *table;
@property (readonly) NSScrollView *scrollView;
@property (readonly) NSButton *fillButton;
@property (readonly) NSButton *handoffButton;
@property (readonly) NSStackView *footer;
@property (readonly) NSButton *openButton;
@property (readonly) NSButton *systemAuthenticationButton;
@end

NS_ASSUME_NONNULL_END
