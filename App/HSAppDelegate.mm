/*
 * This file is part of Hyperspace.
 *
 * Hyperspace is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 *
 * Hyperspace is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */

#import "HSAppDelegate.h"
#import "HyperspaceView.h"

// HyperspaceView sets its frame pacing from the screen it is on when it moves
// to a window or starts (matchRefresh). A saver's window never changes screen;
// this app's does, so the delegate asks again when it moves. Declared here
// rather than in HyperspaceView.h to leave the saver's interface as it is;
// checked with respondsToSelector:, so a rename logs instead of crashing.
@interface HyperspaceView (HSAppPacing)
- (void)matchRefresh;
@end

// How long the pointer may rest in full screen before it is hidden again.
static const NSTimeInterval kCursorIdle = 2.0;

// One window only. draw() keeps the camera and starburst timers in statics
// that every view shares (ss-qlj), so a second view would speed up the scene
// in both. A New Window command waits on that.

@implementation HSAppDelegate
{
	NSWindow *window;
	HyperspaceView *saverView;
	id escapeMonitor;
	id mouseMonitor;
	NSTimer *cursorTimer;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
	[self buildMenu];
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app
{
	return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 720)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
		backing:NSBackingStoreBuffered
		defer:NO];
	window.title = @"Hyperspace";
	window.releasedWhenClosed = NO;
	window.backgroundColor = NSColor.blackColor;
	window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
	window.contentMinSize = NSMakeSize(320, 180);
	window.delegate = self;
	window.frameAutosaveName = @"HyperspaceMainWindow";
	if (![window setFrameUsingName:window.frameAutosaveName])
		[window center];

	// isPreview:NO is the full saver: the preview never pauses an unseen
	// window, and this one should (hsShouldDraw), as when it is minimized.
	// The view is created at the content size (the autosaved one, if any),
	// origin zero, which is what HyperspaceView takes as the main screen.
	NSSize content = [window contentRectForFrameRect:window.frame].size;
	saverView = [[HyperspaceView alloc] initWithFrame:NSMakeRect(0, 0, content.width, content.height) isPreview:NO];
	saverView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	window.contentView = saverView;

	[window makeKeyAndOrderFront:nil];
	[saverView startAnimation];

	// Escape leaves full screen. A local monitor, because the saver view is
	// the first responder and a ScreenSaverView does nothing with the key.
	__weak HSAppDelegate *weakSelf = self;
	escapeMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
		HSAppDelegate *strongSelf = weakSelf;
		if (strongSelf && event.keyCode == 53 /* kVK_Escape */ && event.window == strongSelf->window
			&& (strongSelf->window.styleMask & NSWindowStyleMaskFullScreen) && strongSelf->window.attachedSheet == nil)
		{
			[strongSelf->window toggleFullScreen:nil];
			return nil;
		}
		return event;
	}];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
	return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
	[self stopSaver];
	[self stopCursorHiding];
	if (escapeMonitor)
	{
		[NSEvent removeMonitor:escapeMonitor];
		escapeMonitor = nil;
	}
}

- (void)stopSaver
{
	if (saverView.isAnimating)
		[saverView stopAnimation];	// cleanUp: frees the renderer and the scene
}

#pragma mark - Window

- (void)windowWillClose:(NSNotification *)notification
{
	[self stopSaver];
}

- (void)windowDidChangeScreen:(NSNotification *)notification
{
	if ([saverView respondsToSelector:@selector(matchRefresh)])
		[saverView matchRefresh];
	else
		NSLog(@"Hyperspace: HyperspaceView has no matchRefresh; pacing keeps the first screen's refresh");
}

// In full screen the pointer hides, and hides again each time it has rested
// for kCursorIdle: setHiddenUntilMouseMoves alone shows it for good after the
// first nudge.
- (void)windowDidEnterFullScreen:(NSNotification *)notification
{
	window.acceptsMouseMovedEvents = YES;
	__weak HSAppDelegate *weakSelf = self;
	mouseMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved handler:^NSEvent *(NSEvent *event) {
		[weakSelf scheduleCursorHide];
		return event;
	}];
	[NSCursor setHiddenUntilMouseMoves:YES];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification
{
	[self stopCursorHiding];
}

- (void)scheduleCursorHide
{
	[cursorTimer invalidate];
	cursorTimer = [NSTimer scheduledTimerWithTimeInterval:kCursorIdle repeats:NO block:^(NSTimer *timer) {
		[NSCursor setHiddenUntilMouseMoves:YES];
	}];
}

- (void)stopCursorHiding
{
	[cursorTimer invalidate];
	cursorTimer = nil;
	if (mouseMonitor)
	{
		[NSEvent removeMonitor:mouseMonitor];
		mouseMonitor = nil;
	}
	window.acceptsMouseMovedEvents = NO;
	[NSCursor setHiddenUntilMouseMoves:NO];
}

#pragma mark - Preferences

// The saver's own Options sheet. Its OK button (closeSheet:) saves the
// settings under this app's bundle identifier -- apart from the installed
// saver's -- ends the sheet and restarts the scene with them.
- (IBAction)showPreferences:(id)sender
{
	if (window.attachedSheet || !saverView.hasConfigureSheet)
		return;
	NSWindow *sheet = saverView.configureSheet;
	if (sheet)
		[window beginSheet:sheet completionHandler:nil];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
	if (item.action == @selector(showPreferences:))
		return saverView.hasConfigureSheet && window.attachedSheet == nil && window.visible;
	return YES;
}

#pragma mark - Menu

- (void)buildMenu
{
	NSString *appName = NSProcessInfo.processInfo.processName;
	NSMenu *mainMenu = [[NSMenu alloc] init];

	NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
	[appMenu addItemWithTitle:[NSString stringWithFormat:@"About %@", appName]
		action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
	[appMenu addItem:NSMenuItem.separatorItem];
	NSMenuItem *prefs = [appMenu addItemWithTitle:@"Settings…" action:@selector(showPreferences:) keyEquivalent:@","];
	prefs.target = self;
	[appMenu addItem:NSMenuItem.separatorItem];
	[appMenu addItemWithTitle:[NSString stringWithFormat:@"Hide %@", appName]
		action:@selector(hide:) keyEquivalent:@"h"];
	NSMenuItem *hideOthers = [appMenu addItemWithTitle:@"Hide Others"
		action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
	hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
	[appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
	[appMenu addItem:NSMenuItem.separatorItem];
	[appMenu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
		action:@selector(terminate:) keyEquivalent:@"q"];
	NSMenuItem *appItem = [[NSMenuItem alloc] init];
	appItem.submenu = appMenu;
	[mainMenu addItem:appItem];

	NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
	[fileMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
	NSMenuItem *fileItem = [[NSMenuItem alloc] init];
	fileItem.submenu = fileMenu;
	[mainMenu addItem:fileItem];

	// AppKit retitles this item Enter/Exit Full Screen as the window changes.
	NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
	NSMenuItem *fullScreen = [viewMenu addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
	fullScreen.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
	NSMenuItem *viewItem = [[NSMenuItem alloc] init];
	viewItem.submenu = viewMenu;
	[mainMenu addItem:viewItem];

	NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
	[windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
	[windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
	NSMenuItem *windowItem = [[NSMenuItem alloc] init];
	windowItem.submenu = windowMenu;
	[mainMenu addItem:windowItem];

	NSApp.mainMenu = mainMenu;
	NSApp.windowsMenu = windowMenu;
}

@end
