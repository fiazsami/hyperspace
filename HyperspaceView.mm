//
//  HyperspaceView.m
//  Hyperspace
//
//  Created by Nick Zitzmann on 2/19/06.
//  Copyright (c) 2006, Nick Zitzmann. All rights reserved.
//

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
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#import "HyperspaceView.h"
#import "Hyperspace.h"
#import "flare.h"
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import "Hyperspace/rendererMetal.h"

// The most time one frame may move the scene by.
static const float kMaxFrameTime = 0.1f;
// The frame interval when no screen answers with its refresh.
static const NSTimeInterval kFallbackInterval = 1.0 / 60.0;

@interface HyperspaceView (Private)
- (void)readDefaults:(ScreenSaverDefaults *)inDefaults;
- (void)setDialogValue;
@end

@implementation HyperspaceView

- (id)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
	NSString *identifier = [[NSBundle bundleForClass:[self class]] bundleIdentifier];
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:identifier];
	
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self)
	{
		lSettings.doingPreview = isPreview;
		if (isPreview)
			lMainScreen = YES;
		else
			lMainScreen = (frame.origin.x == 0 && frame.origin.y == 0) ? YES : NO;
		lIsConfiguring = NO;
		lMainScreenOnly = [defaults boolForKey:@"MainScreenOnly"];
		if (lMainScreen || !lMainScreenOnly)
		{
			id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            if (device)
            {
				// A layer-hosting view: the layer is set before wantsLayer.
				lLayer = [CAMetalLayer layer];
				lLayer.device = device;
				lLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
				lLayer.framebufferOnly = YES;
				lLayer.opaque = YES;
                lView = [[NSView alloc] initWithFrame:self.bounds];
				lView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
				lView.layer = lLayer;
				lView.wantsLayer = YES;
                [self addSubview:lView];
				
                lSettings.frameTime = 0;
                
				setDefaults(&lSettings);
                if ([defaults objectForKey:@"Speed"])
                {
                    [self readDefaults:defaults];
                }
				// Metal draws the shaded look only, whatever an older version saved.
				lSettings.dShaders = 1;
                
				self.animationTimeInterval = kFallbackInterval;
				lSettings.first = 1;
            }
		}
    }
    return self;
}


- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	if (lView)
		[lView setFrameSize:size];
	[self matchBacking];
}


// Paces frames to the fastest refresh of the screen the view is on.
// minimumRefreshInterval is the shortest interval; maximumRefreshInterval is
// the longest, the slowest rate a variable-refresh display drops to. The
// window's screen is nil for most windows inside legacyScreenSaver (hills
// measured 25 in 32), and a nil screen answers 0 -- a timer that runs flat
// out -- so the main screen is used instead, then kFallbackInterval.
- (void)matchRefresh
{
	NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
	NSTimeInterval refresh = screen.minimumRefreshInterval;
	self.animationTimeInterval = refresh > 0 ? refresh : kFallbackInterval;
}


// The drawable and the viewport are both in pixels, so a Retina screen draws
// at full resolution and the two always agree.
- (void)matchBacking
{
	if (lView == nil)
		return;
	NSRect backing = [self convertRectToBacking:self.bounds];
	lLayer.contentsScale = self.window ? self.window.backingScaleFactor : 1.0;
	lLayer.drawableSize = backing.size;
	reshape(int(backing.size.width), int(backing.size.height), &lSettings);
}


// A renderer that cannot run is dropped, and the view shows the
// could-not-start message instead of taking the screen saver down with it.
- (void)rendererFailed:(const HSRendererMetalError &)error
{
	NSLog(@"Hyperspace: %s", error.what());
	lRenderer = NULL;	// leaked: its state after a throw cannot be trusted to clean up
	lSettings.renderer = NULL;
	lSettings.readyToDraw = 0;
	[lView removeFromSuperview];
	lView = nil;
	lLayer = nil;
	[self setNeedsDisplay:YES];
}


- (void)viewDidChangeBackingProperties
{
	[super viewDidChangeBackingProperties];
	[self matchBacking];
}


- (void)viewDidMoveToWindow
{
	[super viewDidMoveToWindow];
	[self matchRefresh];
	[self matchBacking];
}


- (void)startAnimation
{
	// Before super, which starts the timer at the interval set now. The window,
	// and so the screen, may have changed since the view moved to it.
	[self matchRefresh];
	lLastFrame = 0;	// the first frame after a start takes no step
    [super startAnimation];
	
	if (lIsConfiguring == NO && lView)
    {
        if (lMainScreen || !lMainScreenOnly)
        {
			// A stopAnimation skipped while the configure sheet was up left the
			// last scene alive; end it before building the next.
			if (lRenderer)
			{
				cleanUp(&lSettings);
				lRenderer = NULL;
			}
			// The shaders are compiled from source in the bundle's metal folder.
			NSString *metalDir = [[NSBundle bundleForClass:[self class]].resourcePath stringByAppendingPathComponent:@"metal"];
			try
			{
				lRenderer = new HSRendererMetal((__bridge void *)lLayer.device, metalDir.fileSystemRepresentation);
				initSaver(&lSettings, lRenderer);
			}
			catch (const HSRendererMetalError &e)
			{
				[self rendererFailed:e];
				return;
			}
			[self matchBacking];
        }
    }
}


- (void)stopAnimation
{
    [super stopAnimation];
	
	if (lIsConfiguring == NO && lView)
    {
        if (lMainScreen || !lMainScreenOnly)
		{
			cleanUp(&lSettings);	// deletes lRenderer
			lRenderer = NULL;
            lSettings.frameTime=0;
		}
	}
}


- (void)drawRect:(NSRect)rect
{
    [[NSColor blackColor] set];
    NSRectFill(rect);
    
    if (lView == nil)
    {    
		if (lMainScreen || !lMainScreenOnly)
        {
            NSRect tFrame=[self frame];
            NSRect tStringFrame;
            NSDictionary * tAttributes;
            NSString * tString;
            NSMutableParagraphStyle * tParagraphStyle;
            
            tParagraphStyle=[[NSParagraphStyle defaultParagraphStyle] mutableCopy];
            [tParagraphStyle setAlignment:NSCenterTextAlignment];
            
            tAttributes = [NSDictionary dictionaryWithObjectsAndKeys:[NSFont systemFontOfSize:[NSFont systemFontSize]],NSFontAttributeName,[NSColor whiteColor],NSForegroundColorAttributeName,tParagraphStyle,NSParagraphStyleAttributeName,nil];
            
            tString=NSLocalizedStringFromTableInBundle(@"This Screen Effect could not start\rits Metal graphics\ron this Mac.",@"Localizable",[NSBundle bundleForClass:[self class]],@"No comment");
            
            tStringFrame.origin=NSZeroPoint;
            tStringFrame.size=[tString sizeWithAttributes:tAttributes];
            
            tStringFrame=SSCenteredRectInRect(tStringFrame,tFrame);
            
            [tString drawInRect:tStringFrame withAttributes:tAttributes];
        }
    }
}


- (void)animateOneFrame
{
	if (lIsConfiguring == NO && lView)
    {
        if (lMainScreen || !lMainScreenOnly)
        {
			if (lSettings.readyToDraw && lRenderer)
			{
				@autoreleasepool	// so each frame's drawable goes back to the layer promptly
				{
					// Waits while every drawable is in flight, which is what paces
					// the saver to the display; nil only after the layer's
					// one-second timeout, as when the display sleeps.
					CFTimeInterval asked = CACurrentMediaTime();
					id<CAMetalDrawable> drawable = [lLayer nextDrawable];
					CFTimeInterval now = CACurrentMediaTime();
					// A stall is dropped, not replayed: the scene resumes where
					// it stopped instead of lurching ahead. Alike whether the
					// wait timed out (nil) or ended just short of it.
					if (drawable == nil || now - asked > kMaxFrameTime)
						lLastFrame = now;
					if (drawable == nil)
						return;
					// The step is the time since the last frame, from a
					// monotonic clock, so never negative. A throttled host
					// would otherwise move the scene by a whole gap at once;
					// past kMaxFrameTime the scene slows instead, which also
					// slows it on a host drawing under 10 fps.
					lSettings.frameTime = lLastFrame > 0 ? float(fmin(now - lLastFrame, kMaxFrameTime)) : 0.0f;
					lLastFrame = now;
					try
					{
						lRenderer->setDrawable((__bridge void *)drawable);
						draw(&lSettings);
					}
					catch (const HSRendererMetalError &e)
					{
						[self rendererFailed:e];
					}
				}
			}
        }
    }
}


- (BOOL)hasConfigureSheet
{
    return (lView != nil);
}


- (NSWindow*)configureSheet
{
    lIsConfiguring = YES;
	if (ibConfigureSheet == nil)
	{
		if ([[NSBundle bundleForClass:self.class] loadNibNamed:@"ConfigureSheet" owner:self topLevelObjects:NULL])
		{
			[ibVersionTxt setStringValue:[[[NSBundle bundleForClass:[self class]] infoDictionary] objectForKey:@"CFBundleVersion"]];	// set the version text
			// Metal always draws the shaded look, so there is nothing to choose.
			[ibShaderCbx setHidden:YES];
			[self setDialogValue];
		}
		else
			NSLog(@"Warning: %@ couldn't load ConfigureSheet.nib.", [self className]);
	}
	return ibConfigureSheet;
}


#pragma mark -


- (IBAction)closeSheet:(id)sender
{
	NSString *identifier = [[NSBundle bundleForClass:[self class]] bundleIdentifier];
    ScreenSaverDefaults *inDefaults = [ScreenSaverDefaults defaultsForModuleWithName:identifier];
	
	[inDefaults setInteger:lSettings.dSpeed forKey:@"Speed"];
	[inDefaults setInteger:lSettings.dStars forKey:@"Stars"];
	[inDefaults setInteger:lSettings.dStarSize forKey:@"StarSize"];
	[inDefaults setInteger:lSettings.dResolution forKey:@"Resolution"];
	[inDefaults setInteger:lSettings.dDepth forKey:@"Depth"];
	[inDefaults setInteger:lSettings.dFov forKey:@"Fov"];
	[inDefaults setBool:lSettings.dShaders forKey:@"UseShaders"];
	[inDefaults setBool:lSettings.dUseGoo forKey:@"UseGoo"];
	[inDefaults setBool:lSettings.dUseTunnels forKey:@"UseTunnels"];
	[inDefaults setBool:lMainScreenOnly forKey:@"MainScreenOnly"];
	[inDefaults synchronize];
	
	lIsConfiguring = NO;
	if ([self isAnimating])
	{
		[self stopAnimation];
		[self startAnimation];
	}
	[NSApp endSheet:ibConfigureSheet];
	[ibConfigureSheet orderOut:self];
}


- (IBAction)reset:(id)sender
{
	setDefaults(&lSettings);
	[self setDialogValue];
}


- (IBAction)setValueForSender:(id)sender
{
	switch ([sender tag])
	{
		case 1:	// resolution of geometry
			lSettings.dResolution = [sender intValue];
			[ibResolutionTxt setIntValue:[sender intValue]];
			break;
		case 2:	// number of stars
			lSettings.dStars = [sender intValue];
			[ibStarsTxt setIntValue:[sender intValue]];
			break;
		case 3:	// speed
			lSettings.dSpeed = [sender intValue];
			[ibSpeedTxt setIntValue:[sender intValue]];
			break;
		case 4:	// size of stars
			lSettings.dStarSize = [sender intValue];
			[ibStarSizeTxt setIntValue:[sender intValue]];
			break;
		case 5:	// view depth
			lSettings.dDepth = [sender intValue];
			[ibDepthTxt setIntValue:[sender intValue]];
			break;
		case 6:	// field of view
			lSettings.dFov = [sender intValue];
			[ibFovTxt setIntValue:[sender intValue]];
			break;
		case 7:	// shaders: hidden, Metal always draws the shaded look
			break;
		case 8:	// main screen
			lMainScreenOnly = ([sender state] == NSOnState ? true : false);
			break;
		case 9:	// goo
			lSettings.dUseGoo = ([sender state] == NSOnState ? true : false);
			break;
		case 10:	// tunnels
			lSettings.dUseTunnels = ([sender state] == NSOnState ? true : false);
			break;
	}
}

@end


@implementation HyperspaceView (Private)

- (void)readDefaults:(ScreenSaverDefaults *)inDefaults
{
    lSettings.dSpeed = int([inDefaults integerForKey:@"Speed"]);
	lSettings.dStars = int([inDefaults integerForKey:@"Stars"]);
	lSettings.dStarSize = int([inDefaults integerForKey:@"StarSize"]);
	lSettings.dResolution = int([inDefaults integerForKey:@"Resolution"]);
	lSettings.dDepth = int([inDefaults integerForKey:@"Depth"]);
	lSettings.dFov = int([inDefaults integerForKey:@"Fov"]);
	lSettings.dShaders = [inDefaults integerForKey:@"UseShaders"];
	if ([inDefaults objectForKey:@"UseGoo"])
		lSettings.dUseGoo = [inDefaults integerForKey:@"UseGoo"];
	if ([inDefaults objectForKey:@"UseTunnels"])
		lSettings.dUseTunnels = [inDefaults integerForKey:@"UseTunnels"];
	lMainScreenOnly = [inDefaults boolForKey:@"MainScreenOnly"];
}


- (void)setDialogValue
{
	[ibResolution setIntValue:lSettings.dResolution];
	[ibResolutionTxt setIntValue:lSettings.dResolution];
	[ibStars setIntValue:lSettings.dStars];
	[ibStarsTxt setIntValue:lSettings.dStars];
	[ibSpeed setIntValue:lSettings.dSpeed];
	[ibSpeedTxt setIntValue:lSettings.dSpeed];
	[ibStarSize setIntValue:lSettings.dStarSize];
	[ibStarSizeTxt setIntValue:lSettings.dStarSize];
	[ibDepth setIntValue:lSettings.dDepth];
	[ibDepthTxt setIntValue:lSettings.dDepth];
	[ibFov setIntValue:lSettings.dFov];
	[ibFovTxt setIntValue:lSettings.dFov];
	[ibShaderCbx setState:(lSettings.dShaders ? NSOnState : NSOffState)];
	[ibGooCbx setState:(lSettings.dUseGoo ? NSOnState : NSOffState)];
	[ibTunnelCbx setState:(lSettings.dUseTunnels ? NSOnState : NSOffState)];
	[ibMainScreenOnlyCbx setState:(lMainScreenOnly ? NSOnState : NSOffState)];
}

@end
