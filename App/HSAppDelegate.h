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

// The desktop application: one window whose content view is the screen
// saver's own HyperspaceView, so the app draws, paces and configures exactly
// as the saver does.
@interface HSAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation>
- (IBAction)showPreferences:(id)sender;
@end
