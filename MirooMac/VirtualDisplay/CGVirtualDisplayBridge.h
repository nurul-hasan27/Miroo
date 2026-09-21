//
//  CGVirtualDisplayBridge.h
//  MirooMac
//
//  Private CoreGraphics Virtual Display Bridge
//
//  =============================================================================
//  IMPORTANT NOTICE ON PRIVATE APIS:
//  -----------------------------------------------------------------------------
//  The classes CGVirtualDisplay, CGVirtualDisplayDescriptor, CGVirtualDisplayMode,
//  and CGVirtualDisplaySettings are PRIVATE and UNDOCUMENTED Apple CoreGraphics
//  runtime classes.
//
//  - They reside inside /System/Library/Frameworks/CoreGraphics.framework.
//  - Apple provides NO public header files or documentation for them.
//  - Applications linking or calling these private symbols CANNOT be distributed
//    through the Mac App Store.
//  - However, they run entirely in user-space, require NO kernel extensions (kexts),
//    require NO special Apple Developer entitlements, and are supported across all
//    Apple Silicon Macs (M1/M2/M3/M4) as well as Intel Macs from macOS 10.14+.
//  - This technique is the identical mechanism used by BetterDisplay, DeskPad,
//    FluffyDisplay, OpenDisplay, and Chromium's macOS virtual display tests.
//  =============================================================================
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Private CoreGraphics Class Interfaces

@class CGVirtualDisplayDescriptor;

/// Private CoreGraphics display mode interface.
@interface CGVirtualDisplayMode : NSObject

@property (readonly, nonatomic) CGFloat refreshRate;
@property (readonly, nonatomic) NSUInteger width;
@property (readonly, nonatomic) NSUInteger height;

- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(CGFloat)refreshRate;

- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(CGFloat)refreshRate
             transferFunction:(uint32_t)transferFunction;

@end

/// Private CoreGraphics display settings interface.
@interface CGVirtualDisplaySettings : NSObject

@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic) unsigned int rotation;

- (instancetype)init;

@end

/// Private CoreGraphics virtual display handle interface.
@interface CGVirtualDisplay : NSObject

@property (readonly, nonatomic) CGDirectDisplayID displayID;
@property (readonly, nonatomic) NSArray *modes;
@property (readonly, nonatomic) unsigned int hiDPI;
@property (readonly, nonatomic) NSString *name;
@property (readonly, nonatomic) unsigned int serialNum;
@property (readonly, nonatomic) unsigned int productID;
@property (readonly, nonatomic) unsigned int vendorID;
@property (readonly, nonatomic) CGSize sizeInMillimeters;
@property (readonly, nonatomic) unsigned int maxPixelsWide;
@property (readonly, nonatomic) unsigned int maxPixelsHigh;
@property (readonly, nonatomic) dispatch_queue_t queue;
@property (readonly, nonatomic) id terminationHandler;

- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;

@end

/// Private CoreGraphics display descriptor interface.
@interface CGVirtualDisplayDescriptor : NSObject

@property (retain, nonatomic) dispatch_queue_t queue;
@property (strong, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);

- (instancetype)init;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
- (nullable dispatch_queue_t)dispatchQueue;

@end

#pragma mark - High-Level Safe Bridge Interface

/// Safe bridge wrapper that insulates Swift code from direct private class handling.
@interface CGVirtualDisplayBridge : NSObject

/// Underlying CoreGraphics display identifier allocated by WindowServer.
@property (nonatomic, readonly) CGDirectDisplayID displayID;

/// Whether the underlying virtual display is valid and currently recognized by macOS.
@property (nonatomic, readonly) BOOL isValid;

/// The display name registered with macOS.
@property (nonatomic, readonly, copy) NSString *name;

/// Logical resolution in points (e.g. 585 x 1266).
@property (nonatomic, readonly) CGSize logicalSize;

/// Physical resolution in pixels (e.g. 1170 x 2532).
@property (nonatomic, readonly) CGSize physicalSize;

/// Pixel scale factor (2 for Retina @2x).
@property (nonatomic, readonly) uint32_t scaleFactor;

/// Checks if the private CoreGraphics virtual display runtime classes are available on this OS.
+ (BOOL)isSupported;

/// Initializes and creates a virtual display with the specified dimensions and identifiers.
/// Returns nil and sets error if private classes are unavailable or WindowServer fails to register it.
- (nullable instancetype)initWithName:(NSString *)name
                          logicalWidth:(uint32_t)logicalWidth
                         logicalHeight:(uint32_t)logicalHeight
                           scaleFactor:(uint32_t)scaleFactor
                              vendorID:(uint32_t)vendorID
                             productID:(uint32_t)productID
                             serialNum:(uint32_t)serialNum
                     sizeInMillimeters:(CGSize)sizeInMillimeters
                                 queue:(dispatch_queue_t)queue
                                 error:(NSError * _Nullable * _Nullable)error;

/// Dynamically updates the active virtual display mode resolution without destroying the display.
- (BOOL)applyModeWithWidth:(uint32_t)width height:(uint32_t)height;

/// Tears down and unregisters the virtual display from macOS WindowServer.
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
