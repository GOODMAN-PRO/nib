#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// XCTest runner SPI, isolated here because the public API has no continuous polyline or two-finger pan.
@interface NibTouchPaths : NSObject
+ (void)perform:(NSArray<NSArray<NSValue *> *> *)paths duration:(NSTimeInterval)duration
     completion:(void (^)(NSError * _Nullable))completion;
@end
NS_ASSUME_NONNULL_END
