//
//  CGVirtualDisplayBridge.m
//  MirooMac
//
//  Private CoreGraphics Virtual Display Bridge Implementation
//

#import "CGVirtualDisplayBridge.h"

@interface CGVirtualDisplayBridge ()
@property (nonatomic, strong, nullable) CGVirtualDisplay *display;
@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) CGSize logicalSize;
@property (nonatomic, assign) CGSize physicalSize;
@property (nonatomic, assign) uint32_t scaleFactor;
@end

@implementation CGVirtualDisplayBridge

+ (BOOL)isSupported {
    Class descClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class dispClass = NSClassFromString(@"CGVirtualDisplay");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settClass = NSClassFromString(@"CGVirtualDisplaySettings");

    return (descClass != Nil && dispClass != Nil && modeClass != Nil && settClass != Nil);
}

- (nullable instancetype)initWithName:(NSString *)name
                          logicalWidth:(uint32_t)logicalWidth
                         logicalHeight:(uint32_t)logicalHeight
                           scaleFactor:(uint32_t)scaleFactor
                              vendorID:(uint32_t)vendorID
                             productID:(uint32_t)productID
                             serialNum:(uint32_t)serialNum
                     sizeInMillimeters:(CGSize)sizeInMillimeters
                                 queue:(dispatch_queue_t)queue
                                 error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (!self) return nil;

    if (![CGVirtualDisplayBridge isSupported]) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.miroo.virtualdisplay"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"CGVirtualDisplay CoreGraphics private classes not found on this system."}];
        }
        return nil;
    }

    _name = [name copy];
    _scaleFactor = (scaleFactor > 0) ? scaleFactor : 1;
    _logicalSize = CGSizeMake(logicalWidth, logicalHeight);
    _physicalSize = CGSizeMake(logicalWidth * _scaleFactor, logicalHeight * _scaleFactor);

    // 1. Configure the virtual display descriptor
    CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
    dispatch_queue_t targetQueue = queue ?: dispatch_get_main_queue();
    [descriptor setDispatchQueue:targetQueue];

    descriptor.name = name;
    descriptor.maxPixelsWide = (uint32_t)_physicalSize.width;
    descriptor.maxPixelsHigh = (uint32_t)_physicalSize.height;
    descriptor.sizeInMillimeters = sizeInMillimeters;
    descriptor.vendorID = vendorID;
    descriptor.productID = productID;
    descriptor.serialNum = serialNum;

    // Standard D65 Apple Display colorimetry
    descriptor.whitePoint = CGPointMake(0.3125, 0.3291);
    descriptor.bluePrimary = CGPointMake(0.1494, 0.0557);
    descriptor.greenPrimary = CGPointMake(0.2559, 0.6983);
    descriptor.redPrimary = CGPointMake(0.6797, 0.3203);

    __weak typeof(self) weakSelf = self;
    descriptor.terminationHandler = ^(id desc, CGVirtualDisplay *disp) {
        NSLog(@"[Miroo] Virtual display ID %u terminated by system WindowServer.", disp.displayID);
        typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf.displayID = 0;
            strongSelf.display = nil;
        }
    };

    // 2. Instantiate the virtual display
    _display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (!_display) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.miroo.virtualdisplay"
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to allocate CGVirtualDisplay instance."}];
        }
        return nil;
    }

    _displayID = _display.displayID;
    if (_displayID == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.miroo.virtualdisplay"
                                         code:-3
                                     userInfo:@{NSLocalizedDescriptionKey: @"CGVirtualDisplay returned invalid displayID (0)."}];
        }
        _display = nil;
        return nil;
    }

    // 3. Apply settings and display modes
    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = (_scaleFactor > 1) ? 1 : 0;

    CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:logicalWidth
                                                                      height:logicalHeight
                                                                 refreshRate:60.0];
    settings.modes = @[mode];

    BOOL success = [_display applySettings:settings];
    if (!success) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.miroo.virtualdisplay"
                                         code:-4
                                     userInfo:@{NSLocalizedDescriptionKey: @"CGVirtualDisplay applySettings failed to commit mode configuration."}];
        }
        _display = nil;
        _displayID = 0;
        return nil;
    }

    return self;
}

- (BOOL)isValid {
    return (_display != nil && _displayID != 0 && CGDisplayIsOnline(_displayID));
}

- (void)destroy {
    if (_display) {
        NSLog(@"[Miroo] Destroying virtual display (ID: %u)...", _displayID);
        _display = nil;
        _displayID = 0;
    }
}

- (void)dealloc {
    [self destroy];
}

@end
