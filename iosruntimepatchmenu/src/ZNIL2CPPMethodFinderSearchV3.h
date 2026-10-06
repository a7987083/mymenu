#pragma once

#import <Foundation/Foundation.h>
#import "ZNIL2CPPHybridFinder.h"

NS_ASSUME_NONNULL_BEGIN

// v0.5.8-dev multi-candidate search surface. Named Offset continues to use the
// proven single-result resolver; this API is for the interactive debugger UI.
@interface ZNIL2CPPHybridFinder (ZNMethodFinderV3Search)
- (nullable NSArray<NSDictionary<NSString *, id> *> *)zn60_searchCandidates:(NSString *)expression
                                                                        limit:(NSUInteger)limit
                                                                        error:(NSString * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
