#pragma once

#import <Foundation/Foundation.h>
#import "ZNIL2CPPHybridFinder.h"

NS_ASSUME_NONNULL_BEGIN

// v0.5.8-dev multi-candidate search surface. Named Offset continues to use the
// proven single-result resolver; this API is for the interactive debugger UI.
@interface ZNIL2CPPHybridFinder (ZNMethodFinderV3Search)
// Class search returns identities only (assembly / namespace / class), never
// runtime class pointers. Caller runs on a worker queue.
- (nullable NSArray<NSDictionary<NSString *, id> *> *)zn64_searchClasses:(NSString *)keyword
                                                                 assembly:(nullable NSString *)assembly
                                                                    limit:(NSUInteger)limit
                                                                   cancel:(nullable BOOL (^)(void))cancel
                                                                    error:(NSString * _Nullable * _Nullable)error;
// Resolve the selected class into existing V3 method-candidate dictionaries.
- (nullable NSArray<NSDictionary<NSString *, id> *> *)zn64_methodsForClass:(NSDictionary<NSString *, id> *)classIdentity
                                                                     limit:(NSUInteger)limit
                                                                    cancel:(nullable BOOL (^)(void))cancel
                                                                     error:(NSString * _Nullable * _Nullable)error;

- (nullable NSArray<NSDictionary<NSString *, id> *> *)zn60_searchCandidates:(NSString *)expression
                                                                        limit:(NSUInteger)limit
                                                                        error:(NSString * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
