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

// How long the pointer may rest in full screen before it is hidden, and how
// often that is checked.
static const NSTimeInterval kCursorIdle = 2.0;
static const NSTimeInterval kCursorPoll = 0.5;

// One window only. draw() keeps the camera and starburst timers in statics
// that every view shares (ss-qlj), so a second view would speed up the scene
// in both. A New Window command waits on that.

@implementation HSAppDelegate
{
	NSWindow *window;
	HyperspaceView *saverView;
	id escapeMonitor;
	NSTimer *cursorPoll;	// runs only in full screen, while the app is active
	NSTimeInterval pollStart;	// systemUptime the poll started
	NSTimeInterval hiddenRestBegan;	// systemUptime the last hidden rest began
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
	[self stopCursorPoll];
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

// HyperspaceView sets its frame pacing from its screen when it moves to a
// window or starts. A saver's window never changes screen; this app's does.
// The notification can come during setFrameUsingName:, before the view
// exists, which is harmless: viewDidMoveToWindow paces it when it arrives.
- (void)windowDidChangeScreen:(NSNotification *)notification
{
	[saverView matchRefresh];
}

// In full screen the pointer hides once there has been no input -- no move,
// click or key -- for kCursorIdle, and again after each later rest.
// setHiddenUntilMouseMoves alone would show it for good after the first
// nudge. The rest is the system's own count of seconds since the last input,
// so a move between two polls, or a click on a sheet's button, is never
// missed, however late a poll runs. Input of every source counts, so Screen
// Sharing, Universal Control and accessibility pointers keep the pointer up as
// a mouse does; a utility posting synthetic events keeps it up too, which is
// the lesser harm. The poll is a plain
// timer, so it waits while a menu is tracking; the pointer is over the menu
// then anyway.
- (void)windowDidEnterFullScreen:(NSNotification *)notification
{
	[self startCursorPoll];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification
{
	[self stopCursorPoll];
}

- (void)applicationDidResignActive:(NSNotification *)notification
{
	[self stopCursorPoll];	// shows the pointer over whatever comes to the front
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
	if (window.styleMask & NSWindowStyleMaskFullScreen)
		[self startCursorPoll];
}

- (void)startCursorPoll
{
	[self stopCursorPoll];	// enter and exit are not guaranteed to pair
	// Full screen can finish after the app has resigned (cmd-tab during the
	// animation); becoming active again starts the poll then.
	if (!NSApp.active)
		return;
	pollStart = NSProcessInfo.processInfo.systemUptime;
	hiddenRestBegan = -DBL_MAX;
	__weak HSAppDelegate *weakSelf = self;
	cursorPoll = [NSTimer scheduledTimerWithTimeInterval:kCursorPoll repeats:YES block:^(NSTimer *timer) {
		[weakSelf pollCursor];
	}];
	cursorPoll.tolerance = 0.2;
}

// A rest qualifies once it has lasted kCursorIdle, is not the rest the pointer
// was last hidden in (so one rest hides it once), and the poll itself has
// run kCursorIdle (so coming to the front after a long idle does not hide the
// pointer at once). The rest's start is a time, not a comparison between
// polls, so a late poll cannot miss or merge rests.
- (void)pollCursor
{
	NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
	CFTimeInterval idle = CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
	NSTimeInterval restBegan = now - idle;
	// The same rest, read again, gives a start that wobbles by however long
	// the two clocks are read apart. A new rest starts at least kCursorIdle
	// after the hidden one did (that one lasted kCursorIdle before it was
	// hidden), so half of that separates the two cases with room to spare.
	if (idle >= kCursorIdle && now - pollStart >= kCursorIdle
		&& restBegan > hiddenRestBegan + kCursorIdle / 2
		&& [self cursorMayHide])
	{
		[NSCursor setHiddenUntilMouseMoves:YES];
		hiddenRestBegan = restBegan;
	}
}

// Only over the scene itself, with the app in front, in full screen and with
// no sheet up. An open menu, the menu bar and a sheet are windows above the
// scene, so the window under the pointer rules them out.
- (BOOL)cursorMayHide
{
	if (!NSApp.active || !(window.styleMask & NSWindowStyleMaskFullScreen) || window.attachedSheet)
		return NO;
	// Only on this window's screen. mouseLocation puts the top row at the
	// screen's maxY, so its rows run (minY, maxY] and minY is the top row of a
	// display below. maxY is just outside every window's frame, so that row, and
	// only that row, is brought inside; a pointer on a display above is left
	// where it is.
	NSPoint mouse = NSEvent.mouseLocation;
	NSRect screen = window.screen.frame;
	if (mouse.x < NSMinX(screen) || mouse.x >= NSMaxX(screen) || mouse.y <= NSMinY(screen) || mouse.y > NSMaxY(screen))
		return NO;
	mouse.y = MIN(mouse.y, NSMaxY(screen) - 1);
	return [NSWindow windowNumberAtPoint:mouse belowWindowWithWindowNumber:0] == window.windowNumber;
}

- (void)stopCursorPoll
{
	[cursorPoll invalidate];
	cursorPoll = nil;
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
	// configureSheet marks the view configuring -- every frame skipped --
	// before it loads the nib, and nothing clears the mark if the load fails
	// (ss-23j.4). So the nib is looked for first, in the bundle configureSheet
	// loads from; CI asserts it is there too. A nib present but unloadable
	// still freezes the scene until ss-23j.4 is fixed in the view.
	if ([[NSBundle bundleForClass:HyperspaceView.class] pathForResource:@"ConfigureSheet" ofType:@"nib"] == nil)
	{
		NSLog(@"Hyperspace: ConfigureSheet.nib is missing from the app bundle");
		NSBeep();
		return;
	}
	NSWindow *sheet = saverView.configureSheet;
	if (sheet)
	{
		[NSCursor setHiddenUntilMouseMoves:NO];	// the sheet's controls need a pointer
		[window beginSheet:sheet completionHandler:nil];
	}
	else
	{
		// configureSheet has logged a failed load itself; a nil return after a
		// load is an unwired ibConfigureSheet outlet.
		NSLog(@"Hyperspace: no Settings sheet (configureSheet returned nil); the scene stops drawing (ss-23j.4)");
		NSBeep();
	}
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
