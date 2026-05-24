#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 捕获 ObjC NSException 的工具类。
/// AVAudioEngine 的 installTap/removeTap 可能抛出 NSException，
/// Swift 无法捕获 NSException，需要通过 ObjC 的 @try/@catch 来捕获。
@interface ObjCExceptionCatcher : NSObject

/// 在 @try/@catch 中执行 block，如果抛出 NSException 则返回异常信息，否则返回 nil。
+ (nullable NSString *)catchException:(void(NS_NOESCAPE ^)(void))block;

@end

NS_ASSUME_NONNULL_END
