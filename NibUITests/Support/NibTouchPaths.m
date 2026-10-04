#import "NibTouchPaths.h"
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>

// Dynamic lookup keeps SDK-private classes out of the app and gives a clear failure if XCTest changes its SPI.
@interface NSObject (NibXCTestTouchSPI)
+ (id)sharedSession;
- (BOOL)useLegacyEventCoordinateTransformationPath;
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(NSTimeInterval)offset;
- (instancetype)initWithName:(NSString *)name interfaceOrientation:(NSInteger)orientation;
- (void)moveToPoint:(CGPoint)point atOffset:(NSTimeInterval)offset;
- (void)liftUpAtOffset:(NSTimeInterval)offset;
- (void)addPointerEventPath:(id)path;
- (id)eventSynthesizer;
- (void)synthesizeEvent:(id)event completion:(void (^)(BOOL, NSError *))completion;
+ (id)deviceEventWithPage:(unsigned int)page usage:(unsigned int)usage duration:(double)duration;
- (BOOL)performDeviceEvent:(id)event error:(NSError **)error;
@end

@implementation NibTouchPaths
+ (BOOL)pressKeyboardUsage:(unsigned int)usage error:(NSError **)error {
    Class eventClass = NSClassFromString(@"XCDeviceEvent");
    XCUIDevice *device = XCUIDevice.sharedDevice;
    if (![eventClass respondsToSelector:@selector(deviceEventWithPage:usage:duration:)] ||
        ![device respondsToSelector:@selector(performDeviceEvent:error:)]) {
        if (error) *error = [NSError errorWithDomain:@"NibUITests" code:4
            userInfo:@{NSLocalizedDescriptionKey: @"XCTest physical keyboard event synthesis is unavailable"}];
        return NO;
    }
    // USB HID keyboard page, with both down and up supplied by XCTest. This
    // follows the real hardware path; it never calls into the app or its commands.
    id event = [eventClass deviceEventWithPage:0x07 usage:usage duration:0.05];
    return [device performDeviceEvent:event error:error];
}

+ (void)perform:(NSArray<NSArray<NSValue *> *> *)paths duration:(NSTimeInterval)duration
     completion:(void (^)(NSError *))completion {
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    XCUIDevice *device = XCUIDevice.sharedDevice;
    if (!recordClass || !pathClass || ![device respondsToSelector:@selector(eventSynthesizer)] ||
        ![recordClass instancesRespondToSelector:@selector(initWithName:interfaceOrientation:)] ||
        ![pathClass instancesRespondToSelector:@selector(initForTouchAtPoint:offset:)] ||
        ![pathClass instancesRespondToSelector:@selector(moveToPoint:atOffset:)] ||
        ![pathClass instancesRespondToSelector:@selector(liftUpAtOffset:)] ||
        ![recordClass instancesRespondToSelector:@selector(addPointerEventPath:)]) {
        completion([NSError errorWithDomain:@"NibUITests" code:1 userInfo:@{NSLocalizedDescriptionKey: @"This XCTest SDK does not expose touch-path synthesis"}]);
        return;
    }
    id synthesizer = [device eventSynthesizer];
    if (![synthesizer respondsToSelector:@selector(synthesizeEvent:completion:)]) {
        completion([NSError errorWithDomain:@"NibUITests" code:2 userInfo:@{NSLocalizedDescriptionKey: @"XCTest event synthesizer unavailable"}]);
        return;
    }
    // Modern XCTest transforms screen points in the daemon. Supplying the
    // interface rotation as well rotates them twice (a landscape centre becomes
    // the portrait centre). Only the legacy event path needs that rotation.
    NSInteger orientation = UIInterfaceOrientationPortrait;
    Class sessionClass = NSClassFromString(@"XCTRunnerDaemonSession");
    id session = [sessionClass respondsToSelector:@selector(sharedSession)] ? [sessionClass sharedSession] : nil;
    if ([session respondsToSelector:@selector(useLegacyEventCoordinateTransformationPath)] &&
        [session useLegacyEventCoordinateTransformationPath]) {
        orientation = device.orientation == UIDeviceOrientationLandscapeLeft ? UIInterfaceOrientationLandscapeRight :
            device.orientation == UIDeviceOrientationLandscapeRight ? UIInterfaceOrientationLandscapeLeft : UIInterfaceOrientationPortrait;
    }
    id record = [[recordClass alloc] initWithName:@"Nib touch path" interfaceOrientation:orientation];
    NSTimeInterval settle = paths.count > 1 ? 0.1 : 0;
    NSUInteger finger = 0;
    for (NSArray<NSValue *> *points in paths) {
        // Give UIKit a hit-test turn per finger before moving the pair (as with physical fingers).
        id path = [[pathClass alloc] initForTouchAtPoint:points.firstObject.CGPointValue offset:finger++ * 0.05];
        if (settle > 0) { [path moveToPoint:points.firstObject.CGPointValue atOffset:settle]; }
        for (NSUInteger i = 1; i < points.count; i++) {
            [path moveToPoint:points[i].CGPointValue atOffset:settle + duration * i / (points.count - 1)];
        }
        [path liftUpAtOffset:settle + duration + 0.01];
        [record addPointerEventPath:path];
    }
    [synthesizer synthesizeEvent:record completion:^(BOOL success, NSError *error) {
        completion(error ?: (success ? nil : [NSError errorWithDomain:@"NibUITests" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Touch synthesis failed"}]));
    }];
}
@end
