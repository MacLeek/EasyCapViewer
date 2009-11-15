/* Copyright (c) 2009, Ben Trask
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
	* Redistributions of source code must retain the above copyright
	  notice, this list of conditions and the following disclaimer.
	* Redistributions in binary form must reproduce the above copyright
	  notice, this list of conditions and the following disclaimer in the
	  documentation and/or other materials provided with the distribution.
	* The names of its contributors may be used to endorse or promote products
	  derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY BEN TRASK ''AS IS'' AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL BEN TRASK BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. */
#import "ECVCaptureController.h"
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOMessage.h>
#import <mach/mach_time.h>

// Models
#import "ECVVideoFrame.h"
#import "ECVVideoStorage.h"

// Views
#import "MPLWindow.h"
#import "ECVVideoView.h"
#import "ECVPlayButtonCell.h"
#import "ECVCropCell.h"

// Controllers
#import "ECVController.h"
#import "ECVConfigController.h"

// Other Sources
#import "ECVAudioDevice.h"
#import "ECVAudioPipe.h"
#import "ECVDebug.h"
#import "ECVSoundTrack.h"
#import "ECVQTKitAdditions.h"
#import "ECVVideoTrack.h"

NSString *const ECVDeinterlacingModeKey = @"ECVDeinterlacingMode";
NSString *const ECVBrightnessKey = @"ECVBrightness";
NSString *const ECVContrastKey = @"ECVContrast";
NSString *const ECVHueKey = @"ECVHue";
NSString *const ECVSaturationKey = @"ECVSaturation";

static NSString *const ECVAspectRatio2Key = @"ECVAspectRatio2";
static NSString *const ECVVsyncKey = @"ECVVsync";
static NSString *const ECVMagFilterKey = @"ECVMagFilter";
static NSString *const ECVShowDroppedFramesKey = @"ECVShowDroppedFrames";
static NSString *const ECVVideoCodecKey = @"ECVVideoCodec";
static NSString *const ECVVideoQualityKey = @"ECVVideoQuality";
static NSString *const ECVVolumeKey = @"ECVVolume";
static NSString *const ECVCropRectKey = @"ECVCropRect";

#if !__LP64__
#define ECVFramesPerPacket 1u
#define ECVChannelsPerFrame 2u
#define ECVBitsPerByte 8u
static AudioStreamBasicDescription const ECVAudioRecordingOutputDescription = {
	48000.0f,
	kAudioFormatLinearPCM,
	kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
	sizeof(Float32) * ECVChannelsPerFrame * ECVFramesPerPacket,
	ECVFramesPerPacket,
	sizeof(Float32) * ECVChannelsPerFrame,
	ECVChannelsPerFrame,
	sizeof(Float32) * ECVBitsPerByte,
	0u,
};
#endif

enum {
	ECVNotPlaying,
	ECVStartPlaying,
	ECVPlaying,
	ECVStopPlaying
}; // _playLock

static void ECVDeviceRemoved(ECVCaptureController *controller, io_service_t service, uint32_t messageType, void *messageArgument)
{
	if(kIOMessageServiceIsTerminated == messageType) [controller performSelector:@selector(noteDeviceRemoved) withObject:nil afterDelay:0.0f inModes:[NSArray arrayWithObject:NSDefaultRunLoopMode]]; // Make sure we don't do anything during a special run loop mode (eg. NSModalPanelRunLoopMode).
}
static void ECVDoNothing(void *refcon, IOReturn result, void *arg0) {}

@interface ECVCaptureController(Private)

- (void)_recordVideoFrame:(ECVVideoFrame *)frame;
- (void)_recordBufferedAudio;
- (void)_hideMenuBar;

@end

@implementation ECVCaptureController

#pragma mark +ECVCaptureController

+ (BOOL)deviceAddedWithIterator:(io_iterator_t)iterator
{
	io_service_t device = IO_OBJECT_NULL;
	BOOL created = NO;
	while((device = IOIteratorNext(iterator))) {
		NSError *error = nil;
		ECVCaptureController *const controller = [[self alloc] initWithDevice:device error:&error];
		if(controller) {
			[controller showWindow:nil];
			created = YES;
		} else if(error) [[NSAlert alertWithError:error] runModal];
		IOObjectRelease(device);
	}
	return created;
}

#pragma mark +NSObject

+ (void)initialize
{
	[[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithInteger:ECVWeave], ECVDeinterlacingModeKey,
		[NSNumber numberWithDouble:0.5f], ECVBrightnessKey,
		[NSNumber numberWithDouble:0.5f], ECVContrastKey,
		[NSNumber numberWithDouble:0.5f], ECVHueKey,
		[NSNumber numberWithDouble:0.5f], ECVSaturationKey,

		[NSNumber numberWithUnsignedInteger:ECV4x3AspectRatio], ECVAspectRatio2Key,
		[NSNumber numberWithBool:NO], ECVVsyncKey,
		[NSNumber numberWithInteger:GL_LINEAR], ECVMagFilterKey,
		[NSNumber numberWithBool:NO], ECVShowDroppedFramesKey,
#if !__LP64__
		NSFileTypeForHFSTypeCode(kJPEGCodecType), ECVVideoCodecKey,
#endif
		[NSNumber numberWithDouble:0.5f], ECVVideoQualityKey,
		[NSNumber numberWithDouble:1.0f], ECVVolumeKey,
		NSStringFromRect(ECVUncroppedRect), ECVCropRectKey,
		nil]];
}

#pragma mark -ECVCaptureController

- (id)initWithDevice:(io_service_t)device error:(out NSError **)outError
{
	if(outError) *outError = nil;
	if(!(self = [self initWithWindowNibName:@"ECVCapture"])) return nil;

	[[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(workspaceWillSleep:) name:NSWorkspaceWillSleepNotification object:[NSWorkspace sharedWorkspace]];

	self.volume = [[NSUserDefaults standardUserDefaults] doubleForKey:ECVVolumeKey];

	ECVIOReturn(IOServiceAddInterestNotification([[ECVController sharedController] notificationPort], device, kIOGeneralInterest, (IOServiceInterestCallback)ECVDeviceRemoved, self, &_deviceRemovedNotification));

	_device = device;
	IOObjectRetain(_device);

	io_name_t productName = "";
	ECVIOReturn(IORegistryEntryGetName(device, productName));
	_productName = [[NSString alloc] initWithUTF8String:productName];

	SInt32 ignored = 0;
	IOCFPlugInInterface **devicePlugInInterface = NULL;
	ECVIOReturn(IOCreatePlugInInterfaceForService(device, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &devicePlugInInterface, &ignored));

	ECVIOReturn((*devicePlugInInterface)->QueryInterface(devicePlugInInterface, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID)&_deviceInterface));
	(*devicePlugInInterface)->Release(devicePlugInInterface);
	devicePlugInInterface = NULL;

	ECVIOReturn((*_deviceInterface)->USBDeviceOpen(_deviceInterface));
	ECVIOReturn((*_deviceInterface)->ResetDevice(_deviceInterface));

	IOUSBConfigurationDescriptorPtr configurationDescription = NULL;
	ECVIOReturn((*_deviceInterface)->GetConfigurationDescriptorPtr(_deviceInterface, 0, &configurationDescription));
	ECVIOReturn((*_deviceInterface)->SetConfiguration(_deviceInterface, configurationDescription->bConfigurationValue));

	IOUSBFindInterfaceRequest interfaceRequest = {
		kIOUSBFindInterfaceDontCare,
		kIOUSBFindInterfaceDontCare,
		kIOUSBFindInterfaceDontCare,
		kIOUSBFindInterfaceDontCare,
	};
	io_iterator_t interfaceIterator = IO_OBJECT_NULL;
	ECVIOReturn((*_deviceInterface)->CreateInterfaceIterator(_deviceInterface, &interfaceRequest, &interfaceIterator));
	io_service_t const interface = IOIteratorNext(interfaceIterator);
	NSParameterAssert(interface);

	IOCFPlugInInterface **interfacePlugInInterface = NULL;
	ECVIOReturn(IOCreatePlugInInterfaceForService(interface, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &interfacePlugInInterface, &ignored));

	CFUUIDRef const refs[] = {
		kIOUSBInterfaceInterfaceID300,
		kIOUSBInterfaceInterfaceID245,
		kIOUSBInterfaceInterfaceID220,
		kIOUSBInterfaceInterfaceID197,
	};
	NSUInteger i;
	for(i = 0; i < numberof(refs); i++) if(SUCCEEDED((*interfacePlugInInterface)->QueryInterface(interfacePlugInInterface, CFUUIDGetUUIDBytes(refs[i]), (LPVOID)&_interfaceInterface))) break;
	NSParameterAssert(_interfaceInterface);
	ECVIOReturn((*_interfaceInterface)->USBInterfaceOpenSeize(_interfaceInterface));

	ECVIOReturn((*_interfaceInterface)->GetFrameListTime(_interfaceInterface, &_frameTime));
	if(self.requiresHighSpeed && kUSBHighSpeedMicrosecondsInFrame != _frameTime) {
		if(outError) *outError = [NSError errorWithDomain:ECVGeneralErrorDomain code:0 userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
			NSLocalizedString(@"This device requires a USB 2.0 High Speed port in order to operate.", nil), NSLocalizedDescriptionKey,
			NSLocalizedString(@"Make sure it is plugged into a port that supports high speed.", nil), NSLocalizedRecoverySuggestionErrorKey,
			[NSArray array], NSLocalizedRecoveryOptionsErrorKey,
			nil]];
		[self release];
		return nil;
	}

	ECVIOReturn((*_interfaceInterface)->CreateInterfaceAsyncEventSource(_interfaceInterface, NULL));
	_playLock = [[NSConditionLock alloc] initWithCondition:ECVNotPlaying];

	return self;

ECVGenericError:
ECVNoDeviceError:
	[self release];
	return nil;
}
- (void)noteDeviceRemoved
{
	if([[self window] attachedSheet]) {
		_noteDeviceRemovedWhenSheetCloses = YES;
	} else {
		[[self window] close];
		[self release];
	}
}
- (void)workspaceWillSleep:(NSNotification *)aNotif
{
	self.playing = NO;
	[self noteDeviceRemoved];
}

#pragma mark -

- (IBAction)play:(id)sender
{
	self.playing = YES;
}
- (IBAction)pause:(id)sender
{
	self.playing = NO;
}
- (IBAction)togglePlaying:(id)sender
{
	[_playLock lock];
	switch([_playLock condition]) {
		case ECVNotPlaying:
		case ECVStopPlaying:
			[_playLock unlockWithCondition:ECVStartPlaying];
			[NSThread detachNewThreadSelector:@selector(threaded_readIsochPipeAsync) toTarget:self withObject:nil];
			break;
		case ECVStartPlaying:
		case ECVPlaying:
			[self stopRecording:self];
			[_playLock unlockWithCondition:ECVStopPlaying];
			[_playLock lockWhenCondition:ECVNotPlaying];
			usleep(0.5f * ECVMicrosecondsPerSecond); // Don't restart the device too quickly.
			[_playLock unlock];
			break;
	}
}

#pragma mark -

- (IBAction)startRecording:(id)sender
{
#if __LP64__
	NSAlert *const alert = [[[NSAlert alloc] init] autorelease];
	[alert setMessageText:NSLocalizedString(@"Recording is not supported in 64-bit mode.", nil)];
	[alert setInformativeText:NSLocalizedString(@"Relaunch EasyCapViewer in 32-bit mode to record.", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
	[alert runModal];
#else
	NSParameterAssert(!_movie);
	NSParameterAssert(!_videoTrack);
	NSSavePanel *const savePanel = [NSSavePanel savePanel];
	[savePanel setAllowedFileTypes:[NSArray arrayWithObject:@"mov"]];
	[savePanel setCanCreateDirectories:YES];
	[savePanel setCanSelectHiddenExtension:YES];
	[savePanel setPrompt:NSLocalizedString(@"Record", nil)];
	[savePanel setAccessoryView:exportAccessoryView];

	[videoCodecPopUp removeAllItems];
	NSArray *const videoCodecs = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"ECVVideoCodecs"];
	NSDictionary *const infoByVideoCodec = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"ECVInfoByVideoCodec"];
	for(NSString *const codec in videoCodecs) {
		NSDictionary *const codecInfo = [infoByVideoCodec objectForKey:codec];
		if(!codecInfo) continue;
		NSMenuItem *const item = [[[NSMenuItem alloc] initWithTitle:[codecInfo objectForKey:@"ECVCodecLabel"] action:NULL keyEquivalent:@""] autorelease];
		[item setTag:(NSInteger)NSHFSTypeCodeFromFileType(codec)];
		[[videoCodecPopUp menu] addItem:item];
	}
	(void)[videoCodecPopUp selectItemWithTag:NSHFSTypeCodeFromFileType([[NSUserDefaults standardUserDefaults] objectForKey:ECVVideoCodecKey])];
	[self changeCodec:videoCodecPopUp];
	[videoQualitySlider setDoubleValue:[[NSUserDefaults standardUserDefaults] doubleForKey:ECVVideoQualityKey]];

	NSInteger const returnCode = [savePanel runModalForDirectory:nil file:NSLocalizedString(@"untitled", nil)];
	[[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithDouble:[videoQualitySlider doubleValue]] forKey:ECVVideoQualityKey];
	if(NSFileHandlingPanelOKButton != returnCode) return;

	_movie = [[QTMovie alloc] initToWritableFile:[savePanel filename] error:NULL];

	ECVPixelSize const s = [self captureSize];
	NSRect const c = self.cropRect;
	ECVPixelSize const croppedSize = (ECVPixelSize){round(NSWidth(c) * s.width), round(NSHeight(c) * s.height)};
	CleanApertureImageDescriptionExtension const croppedAperture = {
		croppedSize.width, 1,
		croppedSize.height, 1,
		round(NSMinX(c) * s.width - (s.width - croppedSize.width) / 2.0f), 1,
		round(NSMinY(c) * s.height - (s.height - croppedSize.height) / 2.0f), 1,
	};
	_videoTrack = [[_movie ECV_videoTrackWithSize:[self outputSize] aperture:croppedAperture codec:(OSType)[videoCodecPopUp selectedTag] quality:[videoQualitySlider doubleValue] frameRate:self.frameRate] retain];

	ECVAudioStream *const inputStream = [[[self.audioInput streams] objectEnumerator] nextObject];
	if(inputStream) {
		_audioRecordingPipe = [[ECVAudioPipe alloc] initWithInputDescription:inputStream.basicDescription outputDescription:ECVAudioRecordingOutputDescription];
		_audioRecordingPipe.dropsBuffers = NO;
		_soundTrack = [[_movie ECV_soundTrackWithDescription:_audioRecordingPipe.outputStreamDescription volume:1.0f] retain];
	}

	[[_soundTrack.track media] ECV_beginEdits];
	[[_videoTrack.track media] ECV_beginEdits];
#endif
}
- (IBAction)stopRecording:(id)sender
{
#if !__LP64__
	if(!_movie) return;
	[_videoTrack finish];
	[_soundTrack.track ECV_insertMediaAtTime:QTZeroTime];
	[_videoTrack.track ECV_insertMediaAtTime:QTZeroTime];
	[[_soundTrack.track media] ECV_endEdits];
	[[_videoTrack.track media] ECV_endEdits];
	[_soundTrack release];
	[_videoTrack release];
	_soundTrack = nil;
	_videoTrack = nil;
	[_audioRecordingPipe release];
	_audioRecordingPipe = nil;
	[_movie updateMovieFile];
	[_movie release];
	_movie = nil;
#endif
}
- (IBAction)changeCodec:(id)sender
{
	NSString *const codec = NSFileTypeForHFSTypeCode((OSType)[sender selectedTag]);
	[[NSUserDefaults standardUserDefaults] setObject:codec forKey:ECVVideoCodecKey];
	NSNumber *const configurableQuality = [[[[NSBundle mainBundle] objectForInfoDictionaryKey:@"ECVInfoByVideoCodec"] objectForKey:codec] objectForKey:@"ECVConfigurableQuality"];
	[videoQualitySlider setEnabled:configurableQuality && [configurableQuality boolValue]];
}

#pragma mark -

- (IBAction)toggleFullScreen:(id)sender
{
	self.fullScreen = !self.fullScreen;
}
- (IBAction)toggleFloatOnTop:(id)sender
{
	[[self window] setLevel:[[self window] level] == NSFloatingWindowLevel ? NSNormalWindowLevel : NSFloatingWindowLevel];
}
- (IBAction)changeScale:(id)sender
{
	self.windowContentSize = [self outputSizeWithScale:[sender tag]];
}
- (IBAction)changeAspectRatio:(id)sender
{
	self.aspectRatio = [self sizeWithAspectRatio:[sender tag]];
	[[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithUnsignedInteger:[sender tag]] forKey:ECVAspectRatio2Key];
}
- (IBAction)changeCropType:(id)sender
{
	NSRect const r = [self cropRectWithType:[sender tag]];
	if([videoView.cell respondsToSelector:@selector(setCropRect:)]) {
		[(ECVCropCell *)videoView.cell setCropRect:r];
		[videoView setNeedsDisplay:YES];
		[[self window] invalidateCursorRectsForView:videoView];
	}else self.cropRect = r;
}
- (IBAction)enterCropMode:(id)sender
{
	ECVCropCell *const cell = [[[ECVCropCell alloc] initWithOpenGLContext:[videoView openGLContext]] autorelease];
	cell.delegate = self;
	cell.cropRect = self.cropRect;
	videoView.cropRect = ECVUncroppedRect;
	videoView.cell = cell;
}
- (IBAction)toggleVsync:(id)sender
{
	videoView.vsync = !videoView.vsync;
	[[NSUserDefaults standardUserDefaults] setBool:videoView.vsync forKey:ECVVsyncKey];
}
- (IBAction)toggleSmoothing:(id)sender
{
	switch(videoView.magFilter) {
		case GL_NEAREST: videoView.magFilter = GL_LINEAR; break;
		case GL_LINEAR: videoView.magFilter = GL_NEAREST; break;
	}
	[[NSUserDefaults standardUserDefaults] setInteger:videoView.magFilter forKey:ECVMagFilterKey];
}
- (IBAction)toggleShowDroppedFrames:(id)sender
{
	videoView.showDroppedFrames = !videoView.showDroppedFrames;
	[[NSUserDefaults standardUserDefaults] setBool:videoView.showDroppedFrames forKey:ECVShowDroppedFramesKey];
}

#pragma mark -

- (NSSize)aspectRatio
{
	return videoView.aspectRatio;
}
- (void)setAspectRatio:(NSSize)ratio
{
	videoView.aspectRatio = ratio;
	[[self window] setContentAspectRatio:ratio];
	CGFloat const r = ratio.height / ratio.width;
	NSSize s = self.windowContentSize;
	s.height = s.width * r;
	self.windowContentSize = s;
	[[self window] setMinSize:NSMakeSize(200.0f, 200.0f * r)];
}
- (NSRect)cropRect
{
	return [videoView.cell respondsToSelector:@selector(cropRect)] ? [(ECVCropCell *)videoView.cell cropRect] : videoView.cropRect;
}
- (void)setCropRect:(NSRect)aRect
{
	videoView.cropRect = aRect;
	[[NSUserDefaults standardUserDefaults] setObject:NSStringFromRect(aRect) forKey:ECVCropRectKey];
}
@synthesize deinterlacingMode = _deinterlacingMode;
- (void)setDeinterlacingMode:(ECVDeinterlacingMode)mode
{
	if(mode == _deinterlacingMode) return;
	BOOL const playing = self.playing;
	if(playing) self.playing = NO;
	_deinterlacingMode = mode;
	[[NSUserDefaults standardUserDefaults] setInteger:mode forKey:ECVDeinterlacingModeKey];
	if(playing) self.playing = YES;
}
@synthesize fullScreen = _fullScreen;
- (void)setFullScreen:(BOOL)flag
{
	if(flag == _fullScreen) return;
	_fullScreen = flag;
	NSDisableScreenUpdates();
	[[self window] close];
	NSUInteger styleMask = NSBorderlessWindowMask;
	NSRect frame = NSZeroRect;
	if(flag) {
		NSArray *const screens = [NSScreen screens];
		if([screens count]) frame = [[screens objectAtIndex:0] frame];
	} else {
		styleMask = NSTitledWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask;
		frame = (NSRect){{100, 100}, self.outputSize};
	}
	NSWindow *const w = [[[MPLWindow alloc] initWithContentRect:frame styleMask:styleMask backing:NSBackingStoreBuffered defer:YES] autorelease];
	NSView *const contentView = [[[[self window] contentView] retain] autorelease];
	[[self window] setContentView:nil];
	[w setContentView:contentView];
	[w setDelegate:self];
	[w setLevel:[[self window] level]];
	[w setContentAspectRatio:[[self window] contentAspectRatio]];
	[w setMinSize:[[self window] minSize]];
	[self setWindow:w];
	[self synchronizeWindowTitleWithDocumentName];
	[w makeKeyAndOrderFront:self];
	if(!flag) [w center];
	NSEnableScreenUpdates();
}
- (BOOL)isPlaying
{
	switch([_playLock condition]) {
		case ECVNotPlaying:
		case ECVStopPlaying:
			return NO;
		case ECVPlaying:
		case ECVStartPlaying:
			return YES;
	}
	return NO;
}
- (void)setPlaying:(BOOL)flag
{
	[_playLock lock];
	if(flag) {
		if(![self isPlaying]) {
			[_playLock unlockWithCondition:ECVStartPlaying];
			[NSThread detachNewThreadSelector:@selector(threaded_readIsochPipeAsync) toTarget:self withObject:nil];
		}
	} else {
		if([self isPlaying]) {
			[self stopRecording:self];
			[_playLock unlockWithCondition:ECVStopPlaying];
			[_playLock lockWhenCondition:ECVNotPlaying];
			usleep(0.5f * ECVMicrosecondsPerSecond); // Don't restart the device too quickly.
			[_playLock unlock];
		}
	}
}
- (NSSize)windowContentSize
{
	NSWindow *const w = [self window];
	return [w contentRectForFrameRect:[w frame]].size;
}
- (void)setWindowContentSize:(NSSize)size
{
	if(self.fullScreen || ![self isWindowLoaded]) return;
	NSWindow *const w = [self window];
	NSRect f = [w contentRectForFrameRect:[w frame]];
	f.origin.y += NSHeight(f) - size.height;
	f.size = size;
	[w setFrame:[w frameRectForContentRect:f] display:YES];
}
- (NSSize)outputSize
{
	NSSize const ratio = videoView.aspectRatio;
	ECVPixelSize const s = self.captureSize;
	return NSMakeSize(s.width, s.width / ratio.width * ratio.height);
}
- (NSSize)outputSizeWithScale:(NSInteger)scale
{
	NSSize const s = self.outputSize;
	CGFloat const factor = powf(2, (CGFloat)scale);
	return NSMakeSize(s.width * factor, s.height * factor);
}
- (NSSize)sizeWithAspectRatio:(ECVAspectRatio)ratio
{
	switch(ratio) {
		case ECV1x1AspectRatio:   return NSMakeSize( 1.0f,  1.0f);
		case ECV4x3AspectRatio:   return NSMakeSize( 4.0f,  3.0f);
		case ECV3x2AspectRatio:   return NSMakeSize( 3.0f,  2.0f);
		case ECV16x10AspectRatio: return NSMakeSize(16.0f, 10.0f);
		case ECV16x9AspectRatio:  return NSMakeSize(16.0f,  9.0f);
	}
	return NSZeroSize;
}
- (NSRect)cropRectWithType:(ECVCropType)type
{
	switch(type) {
		case ECVCrop2_5Percent:     return NSMakeRect(0.025f, 0.025f, 0.95f, 0.95f);
		case ECVCrop5Percent:       return NSMakeRect(0.05f, 0.05f, 0.9f, 0.9f);
		case ECVCrop10Percent:      return NSMakeRect(0.1f, 0.1f, 0.8f, 0.8f);
		case ECVCropLetterbox16x9:  return [self cropRectWithAspectRatio:ECV16x9AspectRatio];
		case ECVCropLetterbox16x10: return [self cropRectWithAspectRatio:ECV16x10AspectRatio];
		default: return ECVUncroppedRect;
	}
}
- (NSRect)cropRectWithAspectRatio:(ECVAspectRatio)ratio
{
	NSSize const standard = [self sizeWithAspectRatio:ECV4x3AspectRatio];
	NSSize const user = [self sizeWithAspectRatio:ratio];
	CGFloat const correction = (user.height / user.width) / (standard.height / standard.width);
	return NSMakeRect(0.0f, (1.0f - correction) / 2.0f, 1.0f, correction);
}

#pragma mark -

- (ECVAudioDevice *)audioInputOfCaptureHardware
{
	ECVAudioDevice *const input = [ECVAudioDevice deviceWithIODevice:_device input:YES];
	input.name = _productName;
	return input;
}
- (ECVAudioDevice *)audioInput
{
	if(!_audioInput) _audioInput = [self.audioInputOfCaptureHardware retain];
	if(!_audioInput) _audioInput = [[ECVAudioDevice defaultInputDevice] retain];
	return [[_audioInput retain] autorelease];
}
- (void)setAudioInput:(ECVAudioDevice *)device
{
	if(device) NSParameterAssert(device.isInput);
	if(ECVEqualObjects(device, _audioInput)) return;
	BOOL const playing = self.playing;
	if(playing) self.playing = NO;
	[_audioInput release];
	_audioInput = [device retain];
	[_audioPreviewingPipe release];
	_audioPreviewingPipe = nil;
	if(playing) self.playing = YES;
}
- (ECVAudioDevice *)audioOutput
{
	if(!_audioOutput) return _audioOutput = [[ECVAudioDevice defaultOutputDevice] retain];
	return [[_audioOutput retain] autorelease];
}
- (void)setAudioOutput:(ECVAudioDevice *)device
{
	if(device) NSParameterAssert(!device.isInput);
	if(ECVEqualObjects(device, _audioOutput)) return;
	BOOL const playing = self.playing;
	if(playing) self.playing = NO;
	[_audioOutput release];
	_audioOutput = [device retain];
	[_audioPreviewingPipe release];
	_audioPreviewingPipe = nil;
	if(playing) self.playing = YES;
}
- (BOOL)startAudio
{
	NSAssert(!_audioPreviewingPipe, @"Audio pipe should be cleared before restarting audio.");

	ECVAudioDevice *const input = self.audioInput;
	ECVAudioDevice *const output = self.audioOutput;

	ECVAudioStream *const inputStream = [[[input streams] objectEnumerator] nextObject];
	if(!inputStream) {
		ECVLog(ECVNotice, @"This device may not support audio (input: %@; stream: %@).", input, inputStream);
		return NO;
	}
	ECVAudioStream *const outputStream = [[[output streams] objectEnumerator] nextObject];
	if(!outputStream) {
		ECVLog(ECVWarning, @"Audio output could not be started (output: %@; stream: %@).", output, outputStream);
		return NO;
	}

	_audioPreviewingPipe = [[ECVAudioPipe alloc] initWithInputDescription:[inputStream basicDescription] outputDescription:[outputStream basicDescription]];
	_audioPreviewingPipe.volume = _volume;
	input.delegate = self;
	output.delegate = self;

	if(![input start]) {
		ECVLog(ECVWarning, @"Audio input could not be restarted (input: %@).", input);
		return NO;
	}
	if(![output start]) {
		[output stop];
		ECVLog(ECVWarning, @"Audio output could not be restarted (output: %@).", output);
		return NO;
	}
	return YES;
}
- (void)stopAudio
{
	ECVAudioDevice *const input = self.audioInput;
	ECVAudioDevice *const output = self.audioOutput;
	[input stop];
	[output stop];
	input.delegate = nil;
	output.delegate = nil;
	[_audioPreviewingPipe release];
	_audioPreviewingPipe = nil;
}

#pragma mark -

- (void)threaded_readIsochPipeAsync
{
	NSAutoreleasePool *const pool = [[NSAutoreleasePool alloc] init];

	UInt8 *fullFrameData = NULL;
	IOUSBLowLatencyIsocFrame *fullFrameList = NULL;

	[_playLock lock];
	if([_playLock condition] != ECVStartPlaying) {
		[_playLock unlock];
		[pool release];
		return;
	}
	ECVLog(ECVNotice, @"Starting playback.");
	[NSThread setThreadPriority:1.0f];
	if(![self threaded_play]) goto bail;
	[_playLock unlockWithCondition:ECVPlaying];

	NSUInteger const simultaneousTransfers = self.simultaneousTransfers;
	NSUInteger const microframesPerTransfer = self.microframesPerTransfer;
	UInt8 const pipe = self.isochReadingPipe;
	NSUInteger i;

	UInt16 frameRequestSize = 0;
	UInt8 ignored1 = 0, ignored2 = 0, ignored3 = 0 , ignored4 = 0;
	ECVIOReturn((*_interfaceInterface)->GetPipeProperties(_interfaceInterface, pipe, &ignored1, &ignored2, &ignored3, &frameRequestSize, &ignored4));
	NSParameterAssert(frameRequestSize);

	ECVIOReturn((*_interfaceInterface)->LowLatencyCreateBuffer(_interfaceInterface, (void **)&fullFrameData, frameRequestSize * microframesPerTransfer * simultaneousTransfers, kUSBLowLatencyReadBuffer));
	ECVIOReturn((*_interfaceInterface)->LowLatencyCreateBuffer(_interfaceInterface, (void **)&fullFrameList, sizeof(IOUSBLowLatencyIsocFrame) * microframesPerTransfer * simultaneousTransfers, kUSBLowLatencyFrameListBuffer));
	for(i = 0; i < microframesPerTransfer * simultaneousTransfers; i++) {
		fullFrameList[i].frStatus = kIOReturnInvalid; // Ignore them to start out.
		fullFrameList[i].frReqCount = frameRequestSize;
	}

	UInt64 currentFrame = 0;
	AbsoluteTime ignored;
	ECVIOReturn((*_interfaceInterface)->GetBusFrameNumber(_interfaceInterface, &currentFrame, &ignored));
	currentFrame += 10;

	ECVPixelSize s = [self captureSize];
	if(ECVLineDouble == _deinterlacingMode || ECVBlur == _deinterlacingMode) s.height /= 2;
	[videoView setVideoStorage:[[[ECVVideoStorage alloc] initWithNumberOfBuffers:5 pixelFormatType:k2vuyPixelFormat size:s] autorelease]]; // AKA kCVPixelFormatType_422YpCbCr8.
	_pendingImageLength = 0;
	_firstFrame = YES;

	[videoView performSelectorOnMainThread:@selector(startDrawing) withObject:nil waitUntilDone:NO];
	(void)[self startAudio];
	[[ECVController sharedController] performSelectorOnMainThread:@selector(noteCaptureControllerStartedPlaying:) withObject:self waitUntilDone:NO];

	while([_playLock condition] == ECVPlaying) {
		NSAutoreleasePool *const innerPool = [[NSAutoreleasePool alloc] init];
		if(![self threaded_watchdog]) {
			ECVLog(ECVError, @"Invalid device watchdog result.");
			[innerPool release];
			break;
		}
		NSUInteger transfer = 0;
		for(; transfer < simultaneousTransfers; transfer++ ) {
			UInt8 *const frameData = fullFrameData + frameRequestSize * microframesPerTransfer * transfer;
			IOUSBLowLatencyIsocFrame *const frameList = fullFrameList + microframesPerTransfer * transfer;
			for(i = 0; i < microframesPerTransfer; i++) {
				if(kUSBLowLatencyIsochTransferKey == frameList[i].frStatus && i) {
					Nanoseconds const nextUpdateTime = UInt64ToUnsignedWide(UnsignedWideToUInt64(AbsoluteToNanoseconds(frameList[i - 1].frTimeStamp)) + 1e6); // LowLatencyReadIsochPipeAsync() only updates every millisecond at most.
					mach_wait_until(UnsignedWideToUInt64(NanosecondsToAbsolute(nextUpdateTime)));
				}
				while(kUSBLowLatencyIsochTransferKey == frameList[i].frStatus) usleep(100); // In case we haven't slept long enough already.
				[self threaded_readFrame:frameList + i bytes:frameData + i * frameRequestSize];
				frameList[i].frStatus = kUSBLowLatencyIsochTransferKey;
			}
			ECVIOReturn((*_interfaceInterface)->LowLatencyReadIsochPipeAsync(_interfaceInterface, pipe, frameData, currentFrame, microframesPerTransfer, 1, frameList, ECVDoNothing, NULL));
			currentFrame += microframesPerTransfer / (kUSBFullSpeedMicrosecondsInFrame / _frameTime);
		}
		[innerPool drain];
	}

	[self threaded_pause];
ECVGenericError:
ECVNoDeviceError:
	[[ECVController sharedController] performSelectorOnMainThread:@selector(noteCaptureControllerStoppedPlaying:) withObject:self waitUntilDone:NO];
	[self stopAudio];
	[videoView performSelectorOnMainThread:@selector(stopDrawing) withObject:nil waitUntilDone:NO];
	if(fullFrameData) (*_interfaceInterface)->LowLatencyDestroyBuffer(_interfaceInterface, fullFrameData);
	if(fullFrameList) (*_interfaceInterface)->LowLatencyDestroyBuffer(_interfaceInterface, fullFrameList);
	[_pendingFrame release];
	_pendingFrame = nil;
	[_lastCompletedFrame release];
	_lastCompletedFrame = nil;
	[_playLock lock];
bail:
	ECVLog(ECVNotice, @"Stopping playback.");
	NSParameterAssert([_playLock condition] != ECVNotPlaying);
	[_playLock unlockWithCondition:ECVNotPlaying];
	[pool drain];
}
- (void)threaded_readImageBytes:(UInt8 const *)bytes length:(size_t)length
{
	if(!bytes || !length) return;
	ECVVideoStorage *const storage = [videoView videoStorage];
	UInt8 *const dest = [_pendingFrame bufferBytes];
	if(!dest) return;
	size_t const maxLength = [storage bufferSize];
	size_t const theoreticalRowLength = self.captureSize.width * 2; // YUYV is effectively 2Bpp.
	size_t const actualRowLength = [storage bytesPerRow];
	size_t const rowPadding = actualRowLength - theoreticalRowLength;
	BOOL const skipLines = ECVFullFrame != _fieldType && (ECVWeave == _deinterlacingMode || ECVAlternate == _deinterlacingMode);

	size_t used = 0;
	size_t rowOffset = _pendingImageLength % actualRowLength;
	while(used < length) {
		size_t const remainingRowLength = theoreticalRowLength - rowOffset;
		size_t const unused = length - used;
		BOOL isFinishingRow = unused >= remainingRowLength;
		size_t const rowFillLength = MIN(maxLength - _pendingImageLength, MIN(remainingRowLength, unused));
		memcpy(dest + _pendingImageLength, bytes + used, rowFillLength);
		_pendingImageLength += rowFillLength;
		if(_pendingImageLength >= maxLength) break;
		if(isFinishingRow) {
			_pendingImageLength += rowPadding;
			if(skipLines) _pendingImageLength += actualRowLength;
		}
		used += rowFillLength;
		rowOffset = 0;
	}
}
- (void)threaded_startNewImageWithFieldType:(ECVFieldType)fieldType
{
	if(_firstFrame) {
		_firstFrame = NO;
		return;
	}

	ECVVideoFrame *frameToDraw = _pendingFrame;
	if(ECVBlur == _deinterlacingMode && _lastCompletedFrame) {
		[_lastCompletedFrame blurWithFrame:_pendingFrame]; // TODO: _lastCompletedFrame might still be in use, so this method needs to create a new frame.
		frameToDraw = _lastCompletedFrame;
	}
	if(frameToDraw) {
		[videoView pushFrame:frameToDraw];
		if(_videoTrack) [self performSelectorOnMainThread:@selector(_recordVideoFrame:) withObject:frameToDraw waitUntilDone:NO];
	}

	ECVVideoStorage *const storage = [videoView videoStorage];
	ECVVideoFrame *const frame = [storage nextFrame];
	switch(_deinterlacingMode) {
		case ECVWeave: [frame fillWithFrame:_pendingFrame]; break;
		case ECVAlternate: [frame clear]; break;
	}
	[_lastCompletedFrame becomeDroppable];
	[_lastCompletedFrame release];
	_lastCompletedFrame = _pendingFrame;
	_pendingFrame = [frame retain];

	_pendingImageLength = ECVLowField == fieldType && (ECVWeave == _deinterlacingMode || ECVAlternate == _deinterlacingMode) ? [storage bytesPerRow] : 0;
	_fieldType = fieldType;
}

#pragma mark -

- (BOOL)setAlternateInterface:(UInt8)alternateSetting
{
	IOReturn const error = (*_interfaceInterface)->SetAlternateInterface(_interfaceInterface, alternateSetting);
	switch(error) {
		case kIOReturnSuccess: return YES;
		case kIOReturnNoDevice:
		case kIOReturnNotResponding: return NO;
	}
	ECVIOReturn(error);
ECVGenericError:
ECVNoDeviceError:
	return NO;
}
- (BOOL)controlRequestWithType:(UInt8)type request:(UInt8)request value:(UInt16)value index:(UInt16)index length:(UInt16)length data:(void *)data
{
	IOUSBDevRequest r = { type, request, value, index, length, data, 0 };
	IOReturn const error = (*_interfaceInterface)->ControlRequest(_interfaceInterface, 0, &r);
	switch(error) {
		case kIOReturnSuccess: return YES;
		case kIOUSBPipeStalled: ECVIOReturn((*_interfaceInterface)->ClearPipeStall(_interfaceInterface, 0)); return YES;
		case kIOReturnNotResponding: return NO;
	}
	ECVIOReturn(error);
ECVGenericError:
ECVNoDeviceError:
	return NO;
}
- (BOOL)writeValue:(UInt16)value atIndex:(UInt16)index
{
	return [self controlRequestWithType:USBmakebmRequestType(kUSBOut, kUSBVendor, kUSBDevice) request:kUSBRqClearFeature value:value index:index length:0 data:NULL];
}
- (BOOL)readValue:(out SInt32 *)outValue atIndex:(UInt16)index
{
	SInt32 v = 0;
	BOOL const r = [self controlRequestWithType:USBmakebmRequestType(kUSBIn, kUSBVendor, kUSBDevice) request:kUSBRqGetStatus value:0 index:index length:sizeof(v) data:&v];
	if(outValue) *outValue = CFSwapInt32LittleToHost(v);
	return r;
}
- (BOOL)setFeatureAtIndex:(UInt16)index
{
	return [self controlRequestWithType:USBmakebmRequestType(kUSBOut, kUSBStandard, kUSBDevice) request:kUSBRqSetFeature value:0 index:index length:0 data:NULL];
}

#pragma mark -ECVCaptureController(Private)

- (void)_recordVideoFrame:(ECVVideoFrame *)frame
{
#if !__LP64__
	[_videoTrack addFrame:frame];
#endif
}
- (void)_recordBufferedAudio
{
#if !__LP64__
	UInt32 const bufferSize = ECVAudioRecordingOutputDescription.mBytesPerPacket * 1000; // Should be more than enough to keep up with the incoming data.
	static u_int8_t *bytes;
	if(!bytes) bytes = malloc(bufferSize);
	AudioBufferList outputBufferList = {1, {2, bufferSize, bytes}};
	[_audioRecordingPipe requestOutputBufferList:&outputBufferList];
	[_soundTrack addSamples:&outputBufferList];
#endif
}
- (void)_hideMenuBar
{
#if __LP64__
	[NSApp setPresentationOptions:NSApplicationPresentationAutoHideMenuBar | NSApplicationPresentationAutoHideDock];
#else
	SetSystemUIMode(kUIModeAllSuppressed, kNilOptions);
#endif
}

#pragma mark -NSWindowController

- (void)windowDidLoad
{
	NSWindow *const w = [self window];
	ECVPixelSize const s = self.captureSize;
	[w setFrame:[w frameRectForContentRect:NSMakeRect(0.0f, 0.0f, s.width, s.height)] display:NO];
	self.aspectRatio = [self sizeWithAspectRatio:[[[NSUserDefaults standardUserDefaults] objectForKey:ECVAspectRatio2Key] unsignedIntegerValue]];

	self.deinterlacingMode = [[NSUserDefaults standardUserDefaults] integerForKey:ECVDeinterlacingModeKey];

	videoView.cropRect = NSRectFromString([[NSUserDefaults standardUserDefaults] stringForKey:ECVCropRectKey]);
	videoView.vsync = [[NSUserDefaults standardUserDefaults] boolForKey:ECVVsyncKey];
	videoView.showDroppedFrames = [[NSUserDefaults standardUserDefaults] boolForKey:ECVShowDroppedFramesKey];
	videoView.magFilter = [[NSUserDefaults standardUserDefaults] integerForKey:ECVMagFilterKey];

	_playButtonCell = [[ECVPlayButtonCell alloc] initWithOpenGLContext:[videoView openGLContext]];
	[_playButtonCell setImage:[ECVPlayButtonCell playButtonImage]];
	_playButtonCell.target = self;
	_playButtonCell.action = @selector(togglePlaying:);
	videoView.cell = _playButtonCell;

	[w center];
	[super windowDidLoad];
}
- (void)synchronizeWindowTitleWithDocumentName
{
	[[self window] setTitle:_productName ? _productName : @""];
}

#pragma mark -NSObject

- (void)dealloc
{
	[[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
	ECVConfigController *const config = [ECVConfigController sharedConfigController];
	if([config captureController] == self) [config setCaptureController:nil];

	if(_deviceInterface) (*_deviceInterface)->USBDeviceClose(_deviceInterface);
	if(_deviceInterface) (*_deviceInterface)->Release(_deviceInterface);
	if(_interfaceInterface) (*_interfaceInterface)->Release(_interfaceInterface);

	IOObjectRelease(_device);
	[_productName release];
	IOObjectRelease(_deviceRemovedNotification);
	[_playLock release];
	[_audioInput release];
	[_audioOutput release];
	[_audioPreviewingPipe release];
	[_movie release];
	[_videoTrack release];
	[_soundTrack release];
	[_audioRecordingPipe release];
	[_playButtonCell release];
	[super dealloc];
}

#pragma mark -NSObject(NSMenuValidation)

- (BOOL)validateMenuItem:(NSMenuItem *)anItem
{
	SEL const action = [anItem action];
	if(@selector(toggleFullScreen:) == action) [anItem setTitle:self.fullScreen ? NSLocalizedString(@"Exit Full Screen", nil) : NSLocalizedString(@"Enter Full Screen", nil)];
	if(@selector(togglePlaying:) == action) [anItem setTitle:[self isPlaying] ? NSLocalizedString(@"Pause", nil) : NSLocalizedString(@"Play", nil)];
	if(@selector(changeAspectRatio:) == action) {
		NSSize const s1 = [self sizeWithAspectRatio:[anItem tag]];
		NSSize const s2 = videoView.aspectRatio;
		[anItem setState:s1.width / s1.height == s2.width / s2.height];
	}
	if(@selector(changeCropType:) == action) [anItem setState:NSEqualRects([self cropRectWithType:[anItem tag]], self.cropRect)];
	if(@selector(changeScale:) == action) [anItem setState:!!NSEqualSizes(self.windowContentSize, [self outputSizeWithScale:[anItem tag]])];
	if(@selector(toggleFloatOnTop:) == action) [anItem setTitle:[[self window] level] == NSFloatingWindowLevel ? NSLocalizedString(@"Turn Floating Off", nil) : NSLocalizedString(@"Turn Floating On", nil)];
	if(@selector(toggleVsync:) == action) [anItem setTitle:videoView.vsync ? NSLocalizedString(@"Turn V-Sync Off", nil) : NSLocalizedString(@"Turn V-Sync On", nil)];
	if(@selector(toggleSmoothing:) == action) [anItem setTitle:GL_LINEAR == videoView.magFilter ? NSLocalizedString(@"Turn Smoothing Off", nil) : NSLocalizedString(@"Turn Smoothing On", nil)];
	if(@selector(toggleShowDroppedFrames:) == action) [anItem setTitle:videoView.showDroppedFrames ? NSLocalizedString(@"Hide Dropped Frames", nil) : NSLocalizedString(@"Show Dropped Frames", nil)];

	if(![self conformsToProtocol:@protocol(ECVCaptureControllerConfiguring)]) {
		if(@selector(configureDevice:) == action) return NO;
	}
	if(self.fullScreen) {
		if(@selector(changeScale:) == action) return NO;
	}
	if(_movie) {
		if(@selector(startRecording:) == action) return NO;
	} else {
		if(@selector(stopRecording:) == action) return NO;
	}
	if(!self.isPlaying) {
		if(@selector(startRecording:) == action) return NO;
	}
	return [self respondsToSelector:action];
}

#pragma mark -<ECVAudioDeviceDelegate>

- (void)audioDevice:(ECVAudioDevice *)sender didReceiveInput:(AudioBufferList const *)bufferList atTime:(AudioTimeStamp const *)time
{
	NSParameterAssert(sender == _audioInput);
	[_audioPreviewingPipe receiveInputBufferList:bufferList];
	[_audioRecordingPipe receiveInputBufferList:bufferList];
	if(_soundTrack) [self performSelectorOnMainThread:@selector(_recordBufferedAudio) withObject:nil waitUntilDone:NO];
}
- (void)audioDevice:(ECVAudioDevice *)sender didRequestOutput:(inout AudioBufferList *)bufferList forTime:(AudioTimeStamp const *)time
{
	NSParameterAssert(sender == _audioOutput);
	[_audioPreviewingPipe requestOutputBufferList:bufferList];
}

#pragma mark -<ECVCaptureControllerConfiguring>

- (CGFloat)volume
{
	return _volume;
}
- (void)setVolume:(CGFloat)value
{
	_volume = value;
	_audioPreviewingPipe.volume = value;
	[[NSUserDefaults standardUserDefaults] setDouble:value forKey:ECVVolumeKey];
}

#pragma mark -<ECVCropCellDelegate>

- (void)cropCellDidFinishCropping:(ECVCropCell *)sender
{
	self.cropRect = sender.cropRect;
	videoView.cell = _playButtonCell;
}

#pragma mark -<ECVVideoViewDelegate>

- (BOOL)videoView:(ECVVideoView *)sender handleKeyDown:(NSEvent *)anEvent
{
	if([@" " isEqualToString:[anEvent charactersIgnoringModifiers]]) {
		[self togglePlaying:self];
		return YES;
	}
	return NO;
}

#pragma mark -<NSWindowDelegate>

- (void)windowDidBecomeMain:(NSNotification *)aNotif
{
	if(self.fullScreen) [self performSelector:@selector(_hideMenuBar) withObject:nil afterDelay:0.0f inModes:[NSArray arrayWithObject:(NSString *)kCFRunLoopCommonModes]];
	[[ECVConfigController sharedConfigController] setCaptureController:self];
}
- (void)windowDidResignMain:(NSNotification *)aNotif
{
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_hideMenuBar) object:nil];
#if __LP64__
	[NSApp setPresentationOptions:NSApplicationPresentationDefault];
#else
	SetSystemUIMode(kUIModeNormal, kNilOptions);
#endif
}

- (void)windowDidEndSheet:(NSNotification *)aNotif
{
	if(_noteDeviceRemovedWhenSheetCloses) [self noteDeviceRemoved];
}

@end
