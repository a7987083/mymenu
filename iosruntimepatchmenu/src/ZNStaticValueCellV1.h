#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL ZNStaticValueCellAugmentAtPath(NSString *path,
                                                       NSUInteger * _Nullable convertedEntries,
                                                       NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
