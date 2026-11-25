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

#import <Cocoa/Cocoa.h>
#import "HSAppDelegate.h"

// No MainMenu.xib: the delegate builds the menu and the window in code.
int main(int argc, const char *argv[])
{
	@autoreleasepool
	{
		NSApplication *app = [NSApplication sharedApplication];
		HSAppDelegate *delegate = [[HSAppDelegate alloc] init];
		app.delegate = delegate;	// weak: delegate is kept alive by this frame
		[app setActivationPolicy:NSApplicationActivationPolicyRegular];
		[app run];
	}
	return 0;
}
