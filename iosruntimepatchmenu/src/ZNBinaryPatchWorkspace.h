#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@class ZNPatchRuntimeValidator;

@interface ZNBinaryPatchRow : NSObject
@property(nonatomic,copy) NSString *target;
@property(nonatomic,assign) BOOL explicitTarget;
@property(nonatomic,copy) NSString *offsetText;
@property(nonatomic,copy) NSString *enabledText;
@property(nonatomic,copy) NSString *originalHex;
@property(nonatomic,copy) NSString *title;
@property(nonatomic,copy) NSString *group;
@property(nonatomic,copy) NSString *sourcePath;
@property(nonatomic,copy) NSString *statusText;
@property(nonatomic,copy) NSString *featureDescription;
@property(nonatomic,assign) BOOL validated;
@property(nonatomic,assign) BOOL lowConfidence;
@property(nonatomic,assign) BOOL conflict;
@property(nonatomic,strong,nullable) ZNPatchRuntimeValidator *validator;
@end

@interface ZNBinaryPatchWorkspace : NSObject
+ (instancetype)sharedWorkspace;
@property(nonatomic,copy) NSString *defaultTarget;
@property(nonatomic,strong,readonly) NSMutableArray<ZNBinaryPatchRow *> *rows;
@property(nonatomic,copy,readonly) NSArray<NSString *> *jsonFiles;
@property(nonatomic,assign) BOOL showJSONFiles;
@property(nonatomic,copy) NSString *lastStatus;
@property(nonatomic,copy,readonly) NSArray<NSString *> *lastOutputPaths;
@property(nonatomic,assign,getter=isBuilding) BOOL building;

- (void)ensureDefaultRows;
- (void)addEmptyRow;
- (void)updateOffset:(NSString *)text row:(NSUInteger)index;
- (void)updateEnabled:(NSString *)text row:(NSUInteger)index;
- (void)updateDefaultTarget:(NSString *)text;

- (void)refreshJSONFiles;
- (BOOL)importJSONAtPath:(NSString *)path error:(NSString * _Nullable * _Nullable)error;

- (NSUInteger)filledCount;
- (NSUInteger)validatedCount;
- (BOOL)hasAnyApplied;
- (BOOL)validateAll:(NSString * _Nullable * _Nullable)error;
- (BOOL)applyAll:(NSString * _Nullable * _Nullable)error;
- (BOOL)restoreAll:(NSString * _Nullable * _Nullable)error;
- (void)setBuildOutputs:(NSArray<NSString *> *)paths status:(NSString *)status;
- (ZNBinaryPatchWorkspace *)buildSnapshotForRowIndexes:(NSArray<NSNumber *> *)rowIndexes;
@end

@interface ZNBinaryPatchWorkspace (ZNFeatureEditing)
- (NSString *)addFeature;
- (void)addPatchToFeature:(NSString *)featureName;
- (BOOL)renameFeature:(NSString *)oldName to:(NSString *)newName error:(NSString * _Nullable * _Nullable)error;
- (BOOL)setDescription:(NSString *)description forFeature:(NSString *)featureName error:(NSString * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
