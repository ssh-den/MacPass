//
//  MPAppDelegate.m
//  MacPass
//
//  Created by Michael Starke on 19.07.12.
//  Copyright (c) 2012 HicknHack Software GmbH. All rights reserved.
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

#import "MPAppDelegate.h"
#import "MPAutoFillCoordinator.h"

#import "MPAutotypeDaemon.h"
#import "MPConstants.h"
#import "MPContextMenuHelper.h"
#import "MPDockTileHelper.h"
#import "MPDocument.h"
#import "MPDocumentController.h"
#import "MPDocumentWindowController.h"
#import "MPLockDaemon.h"
#import "MPPasswordCreatorViewController.h"
#import "MPPluginHost.h"
#import "MPSettingsHelper.h"
#import "MPPreferencesWindowController.h"
#import "MPStringLengthValueTransformer.h"
#import "MPPrettyPasswordTransformer.h"
#import "MPTemporaryFileStorageCenter.h"
#import "MPTouchIdCompositeKeyStore.h"
#import "MPValueTransformerHelper.h"
#import "MPUserNotificationCenterDelegate.h"
#import "MPWelcomeViewController.h"
#import "MPPlugin.h"
#import "MPEntryContextMenuDelegate.h"
#import "MPAutotypeDoctor.h"

#import "NSApplication+MPAdditions.h"
#import "NSTextView+MPTouchBarExtension.h"

#import "KeePassKit/KeePassKit.h"

#import <Sparkle/Sparkle.h>

NSString *const MPDidChangeStoredKeyFilesSettings = @"com.hicknhack.macpass.MPDidChangeStoredKeyFilesSettings";

typedef NS_OPTIONS(NSInteger, MPAppStartupState) {
  MPAppStartupStateNone = 0,
  MPAppStartupStateRestoredWindows = 1,
  MPAppStartupStateFinishedLaunch = 2
};

@interface MPAppDelegate () {
@private
  MPDockTileHelper *_dockTileHelper;
  MPUserNotificationCenterDelegate *_userNotificationCenterDelegate;
  BOOL _shouldOpenFile; // YES if app was started to open a
}

@property (strong) NSWindow *welcomeWindow;
@property (strong) SPUUpdater *updater;
@property (strong) MPAutoFillCoordinator *autoFillCoordinator API_AVAILABLE(macos(13.0));
@property (strong) IBOutlet NSWindow *passwordCreatorWindow;
@property (strong, nonatomic) MPPreferencesWindowController *preferencesController;
@property (strong, nonatomic) MPPasswordCreatorViewController *passwordCreatorController;
@property (assign, nonatomic) MPAppStartupState startupState;

@property (strong) MPEntryContextMenuDelegate *itemActionMenuDelegate;

@end

@implementation MPAppDelegate

+ (void)initialize {
  [MPSettingsHelper setupDefaults];
  [MPSettingsHelper migrateDefaults];
  [MPStringLengthValueTransformer registerTransformer];
  [MPPrettyPasswordTransformer registerTransformer];
  [MPValueTransformerHelper registerValueTransformer];
}

- (instancetype)init {
  self = [super init];
  if(self) {
    _userNotificationCenterDelegate = [[MPUserNotificationCenterDelegate alloc] init];
    self.itemActionMenuDelegate = [[MPEntryContextMenuDelegate alloc] init];
    _shouldOpenFile = NO;
    _isTerminating = NO;
    self.startupState = MPAppStartupStateNone;
    
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(_applicationDidFinishRestoringWindows:)
                                               name:NSApplicationDidFinishRestoringWindowsNotification
                                             object:nil];
    
    /* We know that we do not use the variable after instantiation */
    MPDocumentController *documentController = [[MPDocumentController alloc] init];
    NSAssert(documentController, @"Custom document controller cannot be nil");

    /* The store observes sleep to clear keys. Create it now so persisted keys are
       cleared even if no database was opened in this session */
    (void)MPTouchIdCompositeKeyStore.defaultStore;
  }
  return self;
}

- (void)dealloc {
  [self unbind:NSStringFromSelector(@selector(isAllowedToStoreKeyFile))];
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark Properties
- (void)setIsAllowedToStoreKeyFile:(BOOL)isAllowedToStoreKeyFile {
  if(_isAllowedToStoreKeyFile != isAllowedToStoreKeyFile) {
    _isAllowedToStoreKeyFile = isAllowedToStoreKeyFile;
    /* cleanup on disable */
    if(!self.isAllowedToStoreKeyFile) {
      [self clearRememberdKeyFiles:nil];
    }
    /* Inform anyone that might be interested that we can now no longer/ or can use keyfiles */
    [NSNotificationCenter.defaultCenter postNotificationName:MPDidChangeStoredKeyFilesSettings object:self];
  }
}

- (void)setStartupState:(MPAppStartupState)notificationState {
  if(notificationState != self.startupState) {
    _startupState = notificationState;
    BOOL restored = self.startupState & MPAppStartupStateRestoredWindows;
    BOOL launched = self.startupState & MPAppStartupStateFinishedLaunch;
    if(restored && launched ) {
      [self _applicationDidFinishLaunchingAndDidRestoreWindows];
    }
  }
}

- (void)awakeFromNib {
  _isAllowedToStoreKeyFile = NO;
  /* Update the … at the save menu */
  self.saveMenuItem.menu.delegate = self;
  
  /* We want to inform anyone about the changes to keyFile remembering */
  [self bind:NSStringFromSelector(@selector(isAllowedToStoreKeyFile))
    toObject:NSUserDefaultsController.sharedUserDefaultsController
 withKeyPath:[MPSettingsHelper defaultControllerPathForKey:kMPSettingsKeyRememberKeyFilesForDatabases]
     options:nil];
  
  NSMenu *fileMenu = self.fileNewMenuItem.menu;
  NSInteger insertIndex = [fileMenu indexOfItem:self.fileNewMenuItem]+1;
  NSArray *items = [MPContextMenuHelper contextMenuItemsWithItems:MPContextMenuCreate];
  for(NSMenuItem *item in items.reverseObjectEnumerator) {
    [fileMenu insertItem:item atIndex:insertIndex];
  }
  [self.itemMenu removeAllItems];
  for(NSMenuItem *item in [MPContextMenuHelper contextMenuItemsWithItems:MPContextMenuFull|MPContextMenuShowGroupInOutline]) {
    [self.itemMenu addItem:item];
  }
  self.itemMenu.delegate = self.itemActionMenuDelegate;
}

#pragma mark -
#pragma mark NSApplicationDelegate

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
  if(!flag) {
    BOOL reopen = [NSUserDefaults.standardUserDefaults boolForKey:kMPSettingsKeyReopenLastDatabaseOnLaunch];
    BOOL showWelcomeScreen = YES;
    if(reopen) {
      showWelcomeScreen = ![((MPDocumentController *)NSDocumentController.sharedDocumentController) reopenLastDocument];
    }
    if(showWelcomeScreen) {
      [self showWelcomeWindow];
    }
  }
  return YES;
}

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)sender {
  return [NSUserDefaults.standardUserDefaults boolForKey:kMPSettingsKeyOpenEmptyDatabaseOnLaunch];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  return [NSUserDefaults.standardUserDefaults boolForKey:kMPSettingsKeyQuitOnLastWindowClose];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
  _isTerminating = YES;
  [self hideWelcomeWindow];
  if(@available(macOS 13.0, *)) {
    // Only a listening coordinator can own published identities to clear.
    MPAutoFillCoordinator *coordinator = self.autoFillCoordinator;
    if(coordinator.isListening) {
      __block BOOL replied = NO;
      void (^finish)(void) = ^{
        if(replied) return;
        replied = YES;
        [MPTemporaryFileStorageCenter.defaultCenter cleanupStorages];
        [sender replyToApplicationShouldTerminate:YES];
      };
      // Keep the run loop alive for identity-store completion. Never start new
      // store work in applicationWillTerminate, when XPC is already tearing down.
      // Asynchronous, because the reply must follow the NSTerminateLater return.
      dispatch_async(dispatch_get_main_queue(), ^{ [coordinator prepareForTerminationWithCompletion:finish]; });
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if(!replied) { NSLog(@"AutoFill shutdown cleanup timed out"); finish(); }
      });
      return NSTerminateLater;
    }
  }
  if(MPTemporaryFileStorageCenter.defaultCenter.hasPendingStorages) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [MPTemporaryFileStorageCenter.defaultCenter cleanupStorages];
      [sender replyToApplicationShouldTerminate:YES];
    });
    return NSTerminateLater;
  }
  return NSTerminateNow;
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
  _shouldOpenFile = YES;
  NSURL *fileURL = [NSURL fileURLWithPath:filename];
  [NSDocumentController.sharedDocumentController openDocumentWithContentsOfURL:fileURL
                                                                       display:YES
                                                             completionHandler:^(NSDocument * _Nullable document, BOOL documentWasAlreadyOpen, NSError * _Nullable error){}];
  return YES;
}

- (BOOL)isAutoFillActivationURL:(NSURL *)url {
  NSString *scheme = [NSBundle.mainBundle.bundleIdentifier.lowercaseString stringByAppendingString:@".autofill"];
  return [url.scheme.lowercaseString isEqual:scheme] && [url.host isEqual:@"open"] &&
    url.path.length == 0 && !url.query && !url.fragment && !url.user && !url.password && !url.port;
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
  for(NSURL *url in urls) {
    if(url.isFileURL) [self application:application openFile:url.path];
    // A cold launch through the AutoFill URL keeps the regular startup
    // (restoration, reopening the last database); only a running app is revealed.
    else if([self isAutoFillActivationURL:url] && self.startupState == (MPAppStartupStateRestoredWindows | MPAppStartupStateFinishedLaunch)) {
      [self revealAutoFillApplication];
    }
  }
}

// Any app or web page can open the activation URL, so it only brings MacPass
// forward: it never names files, opens databases or returns data.
// Only the AutoFill database's window is raised: showing another document's
// window could make it main and so switch the database AutoFill serves.
- (void)revealAutoFillApplication {
  MPDocument *document = nil;
  if(@available(macOS 13.0, *)) document = self.autoFillCoordinator.documentToReveal;
  if(document) [document showWindows];
  else if(NSDocumentController.sharedDocumentController.documents.count == 0) [self showWelcomeWindow];
  if(@available(macOS 14.0, *)) [NSApp activate];
  else [NSApp activateIgnoringOtherApps:YES];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  // Unit tests use fake stores and must not change the user's system catalog.
  if(@available(macOS 13.0, *)) {
    if(!NSApp.isRunningTests) self.autoFillCoordinator = [MPAutoFillCoordinator start];
  }
#if defined(NO_SPARKLE)
  NSLog(@"Sparkle explicitly disabled!!!");
#endif
  /* Initalizes Global Daemons */
  [MPLockDaemon defaultDaemon];
  [MPAutotypeDaemon defaultDaemon];
  [MPPluginHost sharedHost];
#if !defined(DEBUG) && !defined(NO_SPARKLE)
  /* Disable updates if in debug or nosparkle  */
  SPUStandardUserDriver *userDriver = [[SPUStandardUserDriver alloc] initWithHostBundle:NSBundle.mainBundle delegate:nil];
  self.updater = [[SPUUpdater alloc] initWithHostBundle:NSBundle.mainBundle applicationBundle:NSBundle.mainBundle userDriver:userDriver delegate:nil];
  [self.updater startUpdater:nil];
#endif
  self.startupState |= MPAppStartupStateFinishedLaunch;
  // Here we just opt-in for allowing our bar to be customized throughout the app.
  NSApplication.sharedApplication.automaticCustomizeTouchBarMenuItemEnabled = YES;
}

#pragma mark -
#pragma mark NSMenuDelegate
- (void)menuNeedsUpdate:(NSMenu *)menu {
  if(menu == self.saveMenuItem.menu) {
    MPDocument *document = NSDocumentController.sharedDocumentController.currentDocument;
    BOOL displayDots = (document.fileURL == nil || !document.compositeKey.hasKeys);
    NSString *saveTitle =  displayDots ? NSLocalizedString(@"SAVE_WITH_DOTS", "Save file menu item title when save will prompt for a location to save or ask for a password/key") : NSLocalizedString(@"SAVE", "Save file menu item title when save will just save the file");
    self.saveMenuItem.title = saveTitle;
  }
  else if(menu == self.fixAutotypeMenuItem.menu) {
    self.fixAutotypeMenuItem.hidden = !(NSEvent.modifierFlags & NSEventModifierFlagOption);
  }
  else if(menu == self.importMenu) {
    NSMenuItem *exportXML = menu.itemArray.firstObject;
    [menu removeAllItems];
    [menu addItem:exportXML];
    for(MPPlugin<MPImportPlugin> * plugin in MPPluginHost.sharedHost.importPlugins) {
      NSMenuItem *importItem = [[NSMenuItem alloc] init];
      [plugin prepareImportMenuItem:importItem];
      importItem.submenu = nil; // kill any potential submenu!
      importItem.representedObject = plugin.identifier;
      importItem.target = nil;
      importItem.action = @selector(importWithPlugin:);
      [menu addItem:importItem];
    }
  }
  else if(menu == self.exportMenu) {
    NSMenuItem *importXML = menu.itemArray.firstObject;
    [menu removeAllItems];
    [menu addItem:importXML];
    for(MPPlugin<MPExportPlugin> * plugin in MPPluginHost.sharedHost.exportPlugins) {
      NSMenuItem *exportItem = [[NSMenuItem alloc] init];
      [plugin prepareExportMenuItem:exportItem];
      exportItem.submenu = nil; // kill any potential submenu!
      exportItem.representedObject = plugin.identifier;
      exportItem.target = nil;
      exportItem.action = @selector(exportWithPlugin:);
      [menu addItem:exportItem];
    }
  }
}

#pragma mark -
#pragma mark Actions

- (void)showPluginPrefences:(id)sender {
  [self _showPreferencesTab:MPPreferencesTabPlugins];
}

- (void)showPreferences:(id)sender {
  [self _showPreferencesTab:MPPreferencesTabGeneral];
}

- (void)_showPreferencesTab:(MPPreferencesTab)tab {
  if(self.preferencesController == nil) {
    self.preferencesController = [[MPPreferencesWindowController alloc] init];
  }
  [self.preferencesController showPreferencesTab:tab];
}

- (void)showPasswordCreator:(id)sender {
  if(!self.passwordCreatorWindow) {
    self.passwordCreatorWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100)
                                                             styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
                                                               backing:NSBackingStoreBuffered
                                                                 defer:NO];
    self.passwordCreatorWindow.releasedWhenClosed = NO;
    self.passwordCreatorWindow.title = NSLocalizedString(@"PASSWORD_CREATOR_WINDOW_TITLE", @"Window title for the stand-alone password creator window");
  }
  if(!self.passwordCreatorController) {
    self.passwordCreatorController = [[MPPasswordCreatorViewController alloc] init];
    self.passwordCreatorWindow.contentViewController = self.passwordCreatorController;
  }
  [self.passwordCreatorController reset];
  [self.passwordCreatorWindow center];
  [self.passwordCreatorWindow makeKeyAndOrderFront:self.passwordCreatorWindow];
}

- (void)createNewDatabase:(id)sender {
  [self.welcomeWindow orderOut:sender];
  [NSDocumentController.sharedDocumentController newDocument:sender];
}

- (void)openDatabase:(id)sender {
  [self.welcomeWindow orderOut:sender];
  [NSDocumentController.sharedDocumentController openDocument:sender];
}

- (void)lockAllDocuments {
  for(NSDocument *document in NSDocumentController.sharedDocumentController.documents) {
    for(id windowController in [document.windowControllers reverseObjectEnumerator]) {
      if([windowController respondsToSelector:@selector(lock:)]) {
        [windowController lock:self];
      }
    }
  }
}

- (void)showWelcomeWindow {
  if(!self.welcomeWindow) {
    self.welcomeWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100)
                                                     styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
    self.welcomeWindow.restorable = NO; // do not restore the welcome window!
    self.welcomeWindow.releasedWhenClosed = NO;
  }
  if(!self.welcomeWindow.contentViewController) {
    self.welcomeWindow.contentViewController = [[MPWelcomeViewController alloc] init];
  }
  
  [self.welcomeWindow center];
  [self.welcomeWindow makeKeyAndOrderFront:nil];
}

- (void)hideWelcomeWindow {
  [self.welcomeWindow orderOut:nil];
}

- (void)clearRememberdKeyFiles:(id)sender {
  [NSUserDefaults.standardUserDefaults removeObjectForKey:kMPSettingsKeyRememeberdKeysForDatabases];
}

- (void)clearStoredTouchIdKeys:(id)sender {
  [MPTouchIdCompositeKeyStore.defaultStore clearStoredCompositeKeys];
}

- (void)showHelp:(id)sender {
  NSString *urlString = NSBundle.mainBundle.infoDictionary[MPBundleHelpURLKey];
  [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:urlString]];
}

- (void)showAutotypeDoctor:(id)sender {
  [MPAutotypeDoctor.defaultDoctor runChecksAndPresentResults];
}

- (void)checkForUpdates:(id)sender {
#if defined(DEBUG) || defined(NO_SPARKLE)
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = NSLocalizedString(@"ALERT_UPDATES_DISABLED_MESSAGE_TEXT", @"Message text for disabled updates alert!");
  alert.informativeText = [NSString stringWithFormat:NSLocalizedString(@"ALERT_UPDATES_DISABLED_INFORMATIVE_TEXT_%@!", @"Informative text of the disabled updates alert!"), NSApp.applicationName];
  [alert addButtonWithTitle:NSLocalizedString(@"OK", @"Ok Button to dismiss disabled updates alert")];
  [alert runModal];
#else
  [self.updater checkForUpdates];
#endif
}

#pragma mark -
#pragma mark Private Helper
- (void)_applicationDidFinishRestoringWindows:(NSNotification *)notification {
  self.startupState |= MPAppStartupStateRestoredWindows;
}

- (void)_applicationDidFinishLaunchingAndDidRestoreWindows {
  NSArray *documents = NSDocumentController.sharedDocumentController.documents;
  BOOL hasOpenDocuments = documents.count > 0;
  
  for(NSDocument *document in documents) {
    for(NSWindowController *windowController in document.windowControllers) {
      [windowController.window.contentView layout];
    }
  }
  
  BOOL reopen = [NSUserDefaults.standardUserDefaults boolForKey:kMPSettingsKeyReopenLastDatabaseOnLaunch];
  BOOL showWelcomeScreen = !hasOpenDocuments && !_shouldOpenFile;
  if(reopen && !hasOpenDocuments && !_shouldOpenFile) {
    showWelcomeScreen = ![((MPDocumentController *)NSDocumentController.sharedDocumentController) reopenLastDocument];
  }
  if(showWelcomeScreen) {
    [self showWelcomeWindow];
  }
}

@end
