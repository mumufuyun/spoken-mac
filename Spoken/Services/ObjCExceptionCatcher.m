#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (nullable NSString *)catchException:(void(NS_NOESCAPE ^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"unknown"];
    }
}

@end
