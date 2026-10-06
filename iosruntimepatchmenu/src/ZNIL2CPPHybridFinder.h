#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZNIL2CPPHybridFinder : NSObject
+ (instancetype)sharedFinder;

@property(nonatomic,copy,readonly) NSString *lastError;
@property(nonatomic,copy,readonly) NSDictionary<NSString *, id> *lastSearchStats;

// Low-memory authoring-time resolver used by v0.5.7 Method Finder / Named Offset.
// It never builds a global method index. Qualified class lookups use
// il2cpp_class_from_name; bare/class-only lookups stream through runtime metadata
// with strict candidate/class/time budgets and Assembly-CSharp priority.
- (nullable NSDictionary<NSString *, id> *)resolveExpression:(NSString *)expression
                                                       error:(NSString * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
