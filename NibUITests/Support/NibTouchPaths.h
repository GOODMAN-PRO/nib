#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// XCTest runner SPI, isolated here because the public API has no continuous polyline or two-finger pan.
@interface NibTouchPaths : NSObject
+ (void)typeKey:(NSString *)key modifiers:(NSUInteger)flags
     completion:(void (^)(NSError * _Nullable))completion NS_SWIFT_NAME(typeKey(_:modifiers:completion:));
+ (void)perform:(NSArray<NSArray<NSValue *> *> *)paths duration:(NSTimeInterval)duration
     completion:(void (^)(NSError * _Nullable))completion;
/// Explicit stationary fingers; XCTest's element multi-tap distributes fingers along the window edges.
+ (void)tapAtPoints:(NSArray<NSValue *> *)points count:(NSUInteger)count
         completion:(void (^)(NSError * _Nullable))completion NS_SWIFT_NAME(tap(at:count:completion:));
@end
NS_ASSUME_NONNULL_END
