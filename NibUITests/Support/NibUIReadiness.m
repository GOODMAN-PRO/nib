#import <XCTest/XCTest.h>

// Loaded by name from Swift so the protected NibTouchPaths bridging header stays unchanged.
@interface NibUIReadiness : NSObject
+ (NSNumber * _Nullable)hittabilityOfElement:(XCUIElement *)element;
@end

@implementation NibUIReadiness
+ (NSNumber * _Nullable)hittabilityOfElement:(XCUIElement *)element {
    @try {
        return @(element.hittable);
    } @catch (NSException *exception) {
        // A transient invalid AX activation point is unknown readiness, never successful dismissal.
        return nil;
    }
}
@end
