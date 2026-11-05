#import "NibTouchPaths.h"
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Dynamic lookup keeps SDK-private classes out of the app and gives a clear failure if XCTest changes its SPI.
@interface NSObject (NibXCTestTouchSPI)
- (instancetype)initForTextInput;
- (void)typeKey:(NSString *)key modifiers:(NSUInteger)flags atOffset:(NSTimeInterval)offset;
- (void)pressKey:(NSString *)key modifiers:(NSUInteger)flags atOffset:(NSTimeInterval)offset;
- (void)releaseKey:(NSString *)key modifiers:(NSUInteger)flags atOffset:(NSTimeInterval)offset;
- (void)setModifiers:(NSUInteger)flags mergeWithCurrentModifierFlags:(BOOL)merge atOffset:(NSTimeInterval)offset;
- (void)typeText:(NSString *)text atOffset:(NSTimeInterval)offset typingSpeed:(NSUInteger)speed shouldRedact:(BOOL)redact;
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(NSTimeInterval)offset;
- (instancetype)initWithName:(NSString *)name interfaceOrientation:(NSInteger)orientation;
- (void)moveToPoint:(CGPoint)point atOffset:(NSTimeInterval)offset;
- (void)liftUpAtOffset:(NSTimeInterval)offset;
- (void)addPointerEventPath:(id)path;
- (id)eventSynthesizer;
- (void)synthesizeEvent:(id)event completion:(void (^)(BOOL, NSError *))completion;
@end

@implementation NibTouchPaths
+ (NSArray<NSString *> *)selectorNamesForClassNamed:(NSString *)name {
    NSMutableArray<NSString *> *selectors = [NSMutableArray array];
    for (Class cls = NSClassFromString(name); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            [selectors addObject:NSStringFromSelector(method_getName(methods[i]))];
        }
        free(methods);
    }
    return [selectors sortedArrayUsingSelector:@selector(compare:)];
}

// Diagnostic only: force exactly one branch, without changing typeKey's fallback policy or timings.
+ (void)sendKey:(NSString *)key modifiers:(NSUInteger)flags route:(NSInteger)route
     completion:(void (^)(NSError *))completion {
    void (^unavailable)(NSString *) = ^(NSString *missing) {
        completion([NSError errorWithDomain:@"NibUITests" code:7 userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"Key probe route %ld unavailable: %@", (long)route, missing]}]);
    };
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    XCUIDevice *device = XCUIDevice.sharedDevice;
    if (!recordClass) { unavailable(@"class XCSynthesizedEventRecord"); return; }
    if (!pathClass) { unavailable(@"class XCPointerEventPath"); return; }
    if (![device respondsToSelector:@selector(eventSynthesizer)]) { unavailable(@"eventSynthesizer"); return; }
    for (NSString *name in @[@"initWithName:interfaceOrientation:", @"addPointerEventPath:"]) {
        if (![recordClass instancesRespondToSelector:NSSelectorFromString(name)]) { unavailable(name); return; }
    }
    if (![pathClass instancesRespondToSelector:@selector(initForTextInput)]) { unavailable(@"initForTextInput"); return; }
    id synthesizer = [device eventSynthesizer];
    if (![synthesizer respondsToSelector:@selector(synthesizeEvent:completion:)]) {
        unavailable(@"synthesizeEvent:completion:"); return;
    }
    NSArray<NSString *> *required;
    switch (route) {
        case 1: required = @[@"typeKey:modifiers:atOffset:"]; break;
        case 2: required = @[@"pressKey:modifiers:atOffset:", @"releaseKey:modifiers:atOffset:"]; break;
        case 3: required = @[@"setModifiers:mergeWithCurrentModifierFlags:atOffset:",
                             @"typeText:atOffset:typingSpeed:shouldRedact:"]; break;
        default: unavailable(@"unknown route (expected 1, 2 or 3)"); return;
    }
    for (NSString *name in required) {
        if (![pathClass instancesRespondToSelector:NSSelectorFromString(name)]) { unavailable(name); return; }
    }
    id path = [[pathClass alloc] initForTextInput];
    if (!path) { unavailable(@"initForTextInput returned nil"); return; }
    switch (route) {
        case 1:
            [path typeKey:key modifiers:flags atOffset:0];
            break;
        case 2:
            [path pressKey:key modifiers:flags atOffset:0];
            [path releaseKey:key modifiers:flags atOffset:0.05];
            break;
        case 3:
            [path setModifiers:flags mergeWithCurrentModifierFlags:NO atOffset:0];
            [path typeText:key atOffset:0.01 typingSpeed:60 shouldRedact:NO];
            [path setModifiers:0 mergeWithCurrentModifierFlags:NO atOffset:0.1 + key.length / 60.0];
            break;
    }
    NSInteger orientation = device.orientation == UIDeviceOrientationLandscapeLeft ? UIInterfaceOrientationLandscapeRight :
        device.orientation == UIDeviceOrientationLandscapeRight ? UIInterfaceOrientationLandscapeLeft : UIInterfaceOrientationPortrait;
    id record = [[recordClass alloc] initWithName:[NSString stringWithFormat:@"Nib key probe route %ld", (long)route]
                           interfaceOrientation:orientation];
    if (!record) { unavailable(@"initWithName:interfaceOrientation: returned nil"); return; }
    [record addPointerEventPath:path];
    [synthesizer synthesizeEvent:record completion:^(BOOL success, NSError *error) {
        completion(error ?: (success ? nil : [NSError errorWithDomain:@"NibUITests" code:8
            userInfo:@{NSLocalizedDescriptionKey: @"Key probe synthesis failed"}]));
    }];
}

+ (void)typeKey:(NSString *)key modifiers:(NSUInteger)flags completion:(void (^)(NSError *))completion {
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    XCUIDevice *device = XCUIDevice.sharedDevice;
    NSMutableArray<NSString *> *selectors = [NSMutableArray array];
    for (Class cls = pathClass; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            [selectors addObject:NSStringFromSelector(method_getName(methods[i]))];
        }
        free(methods);
    }
    void (^unavailable)(void) = ^{
        completion([NSError errorWithDomain:@"NibUITests" code:5 userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"Hardware key synthesis unavailable. XCPointerEventPath instance selectors: %@",
             [[selectors sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]]}]);
    };
    if (!recordClass || !pathClass || ![device respondsToSelector:@selector(eventSynthesizer)] ||
        ![recordClass instancesRespondToSelector:@selector(initWithName:interfaceOrientation:)] ||
        ![recordClass instancesRespondToSelector:@selector(addPointerEventPath:)] ||
        ![pathClass instancesRespondToSelector:@selector(initForTextInput)]) { unavailable(); return; }
    id synthesizer = [device eventSynthesizer];
    if (![synthesizer respondsToSelector:@selector(synthesizeEvent:completion:)]) { unavailable(); return; }
    id path = [[pathClass alloc] initForTextInput];
    NSString *route;
    if ([pathClass instancesRespondToSelector:@selector(typeKey:modifiers:atOffset:)]) {
        route = @"typeKey:modifiers:atOffset:";
        [path typeKey:key modifiers:flags atOffset:0];
    } else if ([pathClass instancesRespondToSelector:@selector(pressKey:modifiers:atOffset:)] &&
               [pathClass instancesRespondToSelector:@selector(releaseKey:modifiers:atOffset:)]) {
        route = @"pressKey/releaseKey:modifiers:atOffset:";
        [path pressKey:key modifiers:flags atOffset:0];
        [path releaseKey:key modifiers:flags atOffset:0.05];
    } else if ([pathClass instancesRespondToSelector:@selector(setModifiers:mergeWithCurrentModifierFlags:atOffset:)] &&
               [pathClass instancesRespondToSelector:@selector(typeText:atOffset:typingSpeed:shouldRedact:)]) {
        route = @"setModifiers/typeText/resetModifiers";
        [path setModifiers:flags mergeWithCurrentModifierFlags:NO atOffset:0];
        [path typeText:key atOffset:0.01 typingSpeed:60 shouldRedact:NO];
        [path setModifiers:0 mergeWithCurrentModifierFlags:NO atOffset:0.1 + key.length / 60.0];
    } else { unavailable(); return; }
    NSLog(@"[Nib hardware key] route=%@ key=%@ modifiers=%lu", route, key, (unsigned long)flags);
    NSInteger orientation = device.orientation == UIDeviceOrientationLandscapeLeft ? UIInterfaceOrientationLandscapeRight :
        device.orientation == UIDeviceOrientationLandscapeRight ? UIInterfaceOrientationLandscapeLeft : UIInterfaceOrientationPortrait;
    id record = [[recordClass alloc] initWithName:[@"Nib hardware key: " stringByAppendingString:route] interfaceOrientation:orientation];
    [record addPointerEventPath:path];
    [synthesizer synthesizeEvent:record completion:^(BOOL success, NSError *error) {
        completion(error ?: (success ? nil : [NSError errorWithDomain:@"NibUITests" code:6
            userInfo:@{NSLocalizedDescriptionKey: @"Hardware key synthesis failed"}]));
    }];
}

+ (void)tapAtPoints:(NSArray<NSValue *> *)points count:(NSUInteger)count
         completion:(void (^)(NSError *))completion {
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    XCUIDevice *device = XCUIDevice.sharedDevice;
    if (!recordClass || !pathClass || points.count < 2 || count == 0 ||
        ![device respondsToSelector:@selector(eventSynthesizer)] ||
        ![recordClass instancesRespondToSelector:@selector(initWithName:interfaceOrientation:)] ||
        ![pathClass instancesRespondToSelector:@selector(initForTouchAtPoint:offset:)] ||
        ![pathClass instancesRespondToSelector:@selector(liftUpAtOffset:)] ||
        ![recordClass instancesRespondToSelector:@selector(addPointerEventPath:)]) {
        completion([NSError errorWithDomain:@"NibUITests" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Stationary multi-tap synthesis unavailable"}]);
        return;
    }
    id synthesizer = [device eventSynthesizer];
    if (![synthesizer respondsToSelector:@selector(synthesizeEvent:completion:)]) {
        completion([NSError errorWithDomain:@"NibUITests" code:2 userInfo:@{NSLocalizedDescriptionKey: @"XCTest event synthesizer unavailable"}]);
        return;
    }
    NSInteger orientation = device.orientation == UIDeviceOrientationLandscapeLeft ? UIInterfaceOrientationLandscapeRight :
        device.orientation == UIDeviceOrientationLandscapeRight ? UIInterfaceOrientationLandscapeLeft : UIInterfaceOrientationPortrait;
    id record = [[recordClass alloc] initWithName:@"Nib stationary multi-tap" interfaceOrientation:orientation];
    for (NSUInteger tap = 0; tap < count; tap++) {
        NSTimeInterval down = tap * 0.16;
        for (NSValue *point in points) {
            id path = [[pathClass alloc] initForTouchAtPoint:point.CGPointValue offset:down];
            [path liftUpAtOffset:down + 0.06];
            [record addPointerEventPath:path];
        }
    }
    [synthesizer synthesizeEvent:record completion:^(BOOL success, NSError *error) {
        completion(error ?: (success ? nil : [NSError errorWithDomain:@"NibUITests" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Multi-tap synthesis failed"}]));
    }];
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
    // Use XCTest screen points with the interface orientation corresponding to the device orientation.
    NSInteger orientation = device.orientation == UIDeviceOrientationLandscapeLeft ? UIInterfaceOrientationLandscapeRight :
        device.orientation == UIDeviceOrientationLandscapeRight ? UIInterfaceOrientationLandscapeLeft : UIInterfaceOrientationPortrait;
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
