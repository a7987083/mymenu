#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#include <math.h>

#import "ZNBinaryPatchWorkspace.h"
#import "ZNFeatureControlModel.h"
#import "ZNPatchRuntimeValidator.h"
#import "ZNStaticBinaryBuilder.h"
#import "ZNValueTypeModel.h"
#import "ZNPatchCore.h"

// M5.9.2 — Offset Authoring Persistence + Validation Bypass
// No second UI/controller hierarchy is created.
// Number/Slider Offset rows are Offset-Hook authoring records, not Value-Cell
// templates. They therefore bypass the legacy M5.8.5 MOVZ/MOVK/FMOV gate.
// Static authoring rows are persisted independently from Runtime Method Call.

static NSString * const kZNM592PersistenceKey = @"zonoe.m5.9.2.offset-authoring.v1";
static NSString * const kZNM592SliderMaxPrefix = @"zonoe.m5.8.5.static-slider-max.v1";
static BOOL gZNM592Restoring = NO;

static NSString *ZNM592Trim(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *ZNM592FeatureName(ZNBinaryPatchRow *row) {
    NSString *group=ZNM592Trim(row.group);
    if(group.length && [group caseInsensitiveCompare:@"Imported"]!=NSOrderedSame) return group;
    NSString *title=ZNM592Trim(row.title);
    return title.length?title:@"功能";
}

static NSString *ZNM592SliderKey(NSString *featureName) {
    return [NSString stringWithFormat:@"%@.%@",kZNM592SliderMaxPrefix,ZNM592Trim(featureName).lowercaseString];
}

static BOOL ZNM592IsHookRow(ZNBinaryPatchRow *row) {
    if(!row.offsetText.length) return NO;
    ZNFeatureControlType type=row.featureControlType;
    return type==ZNFeatureControlTypeSlider || type==ZNFeatureControlTypeNumber;
}

static NSString *ZNM592Hex(NSData *data) {
    const uint8_t *p=(const uint8_t *)data.bytes;
    NSMutableString *s=[NSMutableString stringWithCapacity:data.length*2];
    for(NSUInteger i=0;i<data.length;i++) [s appendFormat:@"%02X",p[i]];
    return s;
}

static BOOL ZNM592ParseRVA(NSString *text,uint64_t *out) {
    NSString *s=ZNM592Trim(text).lowercaseString;
    if(!s.length) return NO;
    const char *c=s.UTF8String; char *end=NULL; errno=0;
    unsigned long long value=strtoull(c,&end,0);
    if(errno||end==c||(end&&*end)){errno=0;end=NULL;value=strtoull(c,&end,16);}
    if(errno||end==c||(end&&*end)) return NO;
    if(out) *out=(uint64_t)value;
    return YES;
}

@interface ZNM592SyntheticValidator : ZNPatchRuntimeValidator
@property(nonatomic,copy) NSString *mTarget;
@property(nonatomic,assign) uint64_t mRVA;
@property(nonatomic,copy) NSData *mBytes;
@property(nonatomic,assign) uintptr_t mAddress;
@end

@implementation ZNM592SyntheticValidator
- (NSString *)target { return self.mTarget ?: @""; }
- (uint64_t)rva { return self.mRVA; }
- (NSData *)patchBytes { return self.mBytes; }
- (NSData *)capturedOriginalBytes { return self.mBytes; }
- (NSData *)currentBytes { return self.mBytes; }
- (uintptr_t)runtimeAddress { return self.mAddress; }
- (BOOL)isConfigured { return YES; }
- (BOOL)isValidated { return YES; }
- (BOOL)isApplied { return NO; }
- (NSString *)lastResult { return @"M5.9.2 Offset Hook auto-prepared"; }
@end

static BOOL ZNM592PrepareHookRows(ZNBinaryPatchWorkspace *workspace,NSString **error) {
    for(ZNBinaryPatchRow *row in workspace.rows) {
        if(!ZNM592IsHookRow(row)) continue;
        NSString *feature=ZNM592FeatureName(row);
        if(row.featureValueType==ZNValueTypeAuto) {
            if(error) *error=[NSString stringWithFormat:@"%@：请选择 ValueType；M6.2 不根据字节自动猜测",feature];
            return NO;
        }
        if(row.featureControlType==ZNFeatureControlTypeSlider) {
            id stored=[NSUserDefaults.standardUserDefaults objectForKey:ZNM592SliderKey(feature)];
            double max=[stored isKindOfClass:NSNumber.class]?[stored doubleValue]:0.0;
            if(!isfinite(max)||max<=0.0) {
                if(error) *error=[NSString stringWithFormat:@"%@：滑块最大值必须大于 0",feature];
                return NO;
            }
        }
        uint64_t rva=0;
        if(!ZNM592ParseRVA(row.offsetText,&rva)) {
            if(error) *error=[NSString stringWithFormat:@"Offset 格式无效：%@",row.offsetText?:@""];
            return NO;
        }
        NSString *global=[workspace.defaultTarget ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        BOOL autoTarget=!global.length||[global caseInsensitiveCompare:@"自动"]==NSOrderedSame||[global caseInsensitiveCompare:@"auto"]==NSOrderedSame;
        NSString *target=autoTarget?((row.explicitTarget&&row.target.length)?row.target:@"main"):global;
        uintptr_t address=[[ZNModuleManager sharedManager] runtimeAddressForModule:target rva:rva];
        if(!address) {
            if(error) *error=[NSString stringWithFormat:@"%@+0x%llX 无法解析运行时地址",target,rva];
            return NO;
        }
        uint8_t bytes[4]={0}; vm_size_t copied=0;
        kern_return_t kr=vm_read_overwrite(mach_task_self(),(vm_address_t)address,sizeof(bytes),(vm_address_t)bytes,&copied);
        if(kr!=KERN_SUCCESS||copied!=sizeof(bytes)) {
            if(error) *error=[NSString stringWithFormat:@"%@+0x%llX 无法读取 4-byte 原始窗口 kr=%d",target,rva,kr];
            return NO;
        }
        NSData *data=[NSData dataWithBytes:bytes length:sizeof(bytes)];
        ZNM592SyntheticValidator *validator=[ZNM592SyntheticValidator new];
        validator.mTarget=target;
        validator.mRVA=rva;
        validator.mBytes=data;
        validator.mAddress=address;
        row.validator=validator;
        row.validated=YES;
        row.offsetText=[NSString stringWithFormat:@"0x%llX",rva];
        row.originalHex=ZNM592Hex(data);
        // Internal builder compatibility only. UI continues to show Max/auto
        // template because M5.9.0 rewires this field in-place.
        row.enabledText=ZNM592Hex(data);
        row.statusText=@"✅ Offset Hook · 自动准备（无指令类型硬检测）";
    }
    return YES;
}

static BOOL ZNM592MeaningfulRow(ZNBinaryPatchRow *row) {
    if(row.offsetText.length) return YES;
    if(row.enabledText.length && !ZNM592IsHookRow(row)) return YES;
    NSString *group=ZNM592Trim(row.group),*title=ZNM592Trim(row.title);
    if(group.length && [group caseInsensitiveCompare:@"Imported"]!=NSOrderedSame) return YES;
    return title.length>0;
}

static NSDictionary *ZNM592EncodeRow(ZNBinaryPatchRow *row) {
    BOOL hook=ZNM592IsHookRow(row);
    return @{
        @"target":row.target?:@"",
        @"explicitTarget":@(row.explicitTarget),
        @"offset":row.offsetText?:@"",
        @"enabled":hook?@"":(row.enabledText?:@""),
        @"title":row.title?:@"",
        @"group":row.group?:@"Imported",
        @"sourcePath":row.sourcePath?:@"",
        @"featureDescription":row.featureDescription?:@"",
        @"lowConfidence":@(row.lowConfidence),
        @"controlType":@((NSInteger)row.featureControlType),
        @"valueType":@((NSInteger)row.featureValueType)
    };
}

static void ZNM592SaveWorkspace(void) {
    if(gZNM592Restoring) return;
    ZNBinaryPatchWorkspace *workspace=[ZNBinaryPatchWorkspace sharedWorkspace];
    NSMutableArray *rows=[NSMutableArray array];
    for(ZNBinaryPatchRow *row in workspace.rows) {
        if(ZNM592MeaningfulRow(row)) [rows addObject:ZNM592EncodeRow(row)];
    }
    NSDictionary *root=@{
        @"version":@1,
        @"defaultTarget":workspace.defaultTarget?:@"main",
        @"rows":rows
    };
    [NSUserDefaults.standardUserDefaults setObject:root forKey:kZNM592PersistenceKey];
    [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[m5.9.2-offset-persist] saved %lu rows",(unsigned long)rows.count]];
}

static BOOL ZNM592HasMeaningfulCurrentRows(ZNBinaryPatchWorkspace *workspace) {
    for(ZNBinaryPatchRow *row in workspace.rows) if(ZNM592MeaningfulRow(row)) return YES;
    return NO;
}

static void ZNM592RestoreWorkspace(void) {
    ZNBinaryPatchWorkspace *workspace=[ZNBinaryPatchWorkspace sharedWorkspace];
    if(ZNM592HasMeaningfulCurrentRows(workspace)) return;
    NSDictionary *root=[NSUserDefaults.standardUserDefaults objectForKey:kZNM592PersistenceKey];
    if(![root isKindOfClass:NSDictionary.class]||[root[@"version"] integerValue]!=1) return;
    NSArray *items=[root[@"rows"] isKindOfClass:NSArray.class]?root[@"rows"]:@[];
    if(!items.count) return;

    gZNM592Restoring=YES;
    [workspace.rows removeAllObjects];
    NSUInteger restored=0;
    for(NSDictionary *item in items) {
        if(![item isKindOfClass:NSDictionary.class]) continue;
        ZNBinaryPatchRow *row=[ZNBinaryPatchRow new];
        row.target=[item[@"target"] isKindOfClass:NSString.class]?item[@"target"]:@"";
        row.explicitTarget=[item[@"explicitTarget"] boolValue];
        row.offsetText=[item[@"offset"] isKindOfClass:NSString.class]?item[@"offset"]:@"";
        row.enabledText=[item[@"enabled"] isKindOfClass:NSString.class]?item[@"enabled"]:@"";
        row.title=[item[@"title"] isKindOfClass:NSString.class]?item[@"title"]:@"";
        row.group=[item[@"group"] isKindOfClass:NSString.class]?item[@"group"]:@"Imported";
        row.sourcePath=[item[@"sourcePath"] isKindOfClass:NSString.class]?item[@"sourcePath"]:@"";
        row.featureDescription=[item[@"featureDescription"] isKindOfClass:NSString.class]?item[@"featureDescription"]:@"";
        row.lowConfidence=[item[@"lowConfidence"] boolValue];
        row.featureControlType=(ZNFeatureControlType)[item[@"controlType"] integerValue];
        row.featureValueType=(ZNValueType)[item[@"valueType"] integerValue];
        row.validated=NO;
        row.validator=nil;
        row.originalHex=@"";
        row.statusText=@"已恢复 · 待自动准备";
        [workspace.rows addObject:row];
        restored++;
    }
    NSString *target=[root[@"defaultTarget"] isKindOfClass:NSString.class]?root[@"defaultTarget"]:@"";
    if(target.length) workspace.defaultTarget=target;
    [workspace ensureDefaultRows];
    workspace.lastStatus=[NSString stringWithFormat:@"已恢复 Offset/Static 编辑记录：%lu",(unsigned long)restored];
    gZNM592Restoring=NO;
    [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[m5.9.2-offset-persist] restored %lu rows",(unsigned long)restored]];
}

@interface ZNBinaryPatchWorkspace (ZNM592Validation)
- (BOOL)znm592_validateAll:(NSString **)error;
@end

@implementation ZNBinaryPatchWorkspace (ZNM592Validation)
- (BOOL)znm592_validateAll:(NSString **)error {
    NSMutableArray<ZNBinaryPatchRow *> *hooks=[NSMutableArray array];
    NSMutableArray<ZNBinaryPatchRow *> *legacy=[NSMutableArray array];
    for(ZNBinaryPatchRow *row in self.rows) {
        if(!row.offsetText.length&&!row.enabledText.length) continue;
        if(ZNM592IsHookRow(row)) [hooks addObject:row];
        else [legacy addObject:row];
    }
    if(!hooks.count) return [self znm592_validateAll:error];
    if(self.hasAnyApplied) { if(error)*error=@"请先恢复当前临时 Patch"; return NO; }

    NSString *prepareError=nil;
    if(!ZNM592PrepareHookRows(self,&prepareError)) {
        self.lastStatus=[NSString stringWithFormat:@"Offset Hook 自动准备失败：%@",prepareError?:@"未知错误"];
        if(error) *error=prepareError?:@"Offset Hook 自动准备失败";
        return NO;
    }

    BOOL legacyOK=YES;
    NSString *legacyError=nil;
    if(legacy.count) {
        NSMutableArray<ZNBinaryPatchRow *> *storage=self.rows;
        NSArray<ZNBinaryPatchRow *> *snapshot=[storage copy];
        [storage removeAllObjects];
        [storage addObjectsFromArray:legacy];
        legacyOK=[self znm592_validateAll:&legacyError];
        [storage removeAllObjects];
        [storage addObjectsFromArray:snapshot];
    }
    if(!legacyOK) {
        self.lastStatus=[NSString stringWithFormat:@"传统 Patch 验证失败：%@",legacyError?:@"未知错误"];
        if(error) *error=legacyError?:@"传统 Patch 验证失败";
        return NO;
    }

    self.lastStatus=[NSString stringWithFormat:@"自动准备完成：Offset Hook %lu%@",
                     (unsigned long)hooks.count,
                     legacy.count?[NSString stringWithFormat:@" · 传统 Patch %lu 已验证",(unsigned long)legacy.count]:@""];
    ZNM592SaveWorkspace();
    [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[m5.9.2-validate] bypassed legacy MOV/FMOV gate for %lu Offset Hook rows",(unsigned long)hooks.count]];
    return YES;
}
@end

@interface ZNStaticBinaryBuilder (ZNM592Build)
+ (BOOL)znm592_buildWorkspace:(ZNBinaryPatchWorkspace *)workspace
                      outputs:(NSArray<NSString *> **)outputs
                       report:(NSString **)report
                        error:(NSString **)error;
@end

@implementation ZNStaticBinaryBuilder (ZNM592Build)
+ (BOOL)znm592_buildWorkspace:(ZNBinaryPatchWorkspace *)workspace
                      outputs:(NSArray<NSString *> **)outputs
                       report:(NSString **)report
                        error:(NSString **)error {
    NSString *prepareError=nil;
    // M6.2 has no separate user-facing Read/Validate step. Build performs the
    // same preparation internally: typed rows get synthetic build validators,
    // while Button/Switch rows capture and verify their live Original here.
    if(![workspace validateAll:&prepareError]) {
        if(error)*error=prepareError?:@"M6.2 Offset 自动准备失败";
        return NO;
    }
    return [self znm592_buildWorkspace:workspace outputs:outputs report:report error:error];
}
@end

@interface ZNBinaryPatchWorkspace (ZNM592PersistenceSwizzles)
- (void)znm592_updateOffset:(NSString *)text row:(NSUInteger)index;
- (void)znm592_updateEnabled:(NSString *)text row:(NSUInteger)index;
- (void)znm592_updateDefaultTarget:(NSString *)text;
- (void)znm592_addEmptyRow;
- (BOOL)znm592_importJSONAtPath:(NSString *)path error:(NSString **)error;
- (NSString *)znm592_addFeature;
- (void)znm592_addPatchToFeature:(NSString *)featureName;
- (BOOL)znm592_renameFeature:(NSString *)oldName to:(NSString *)newName error:(NSString **)error;
- (BOOL)znm592_setControlType:(ZNFeatureControlType)type forFeature:(NSString *)featureName error:(NSString **)error;
- (BOOL)znm592_setValueType:(ZNValueType)type forFeature:(NSString *)featureName error:(NSString **)error;
- (BOOL)znm592_removeFeatureNamed:(NSString *)featureName error:(NSString **)error;
- (BOOL)znm592_removePatchAtGlobalIndex:(NSUInteger)index error:(NSString **)error;
- (BOOL)znm592_setDescription:(NSString *)description forFeature:(NSString *)featureName error:(NSString **)error;
@end

@implementation ZNBinaryPatchWorkspace (ZNM592PersistenceSwizzles)
- (void)znm592_updateOffset:(NSString *)text row:(NSUInteger)index { [self znm592_updateOffset:text row:index]; ZNM592SaveWorkspace(); }
- (void)znm592_updateEnabled:(NSString *)text row:(NSUInteger)index { [self znm592_updateEnabled:text row:index]; ZNM592SaveWorkspace(); }
- (void)znm592_updateDefaultTarget:(NSString *)text { [self znm592_updateDefaultTarget:text]; ZNM592SaveWorkspace(); }
- (void)znm592_addEmptyRow { [self znm592_addEmptyRow]; ZNM592SaveWorkspace(); }
- (BOOL)znm592_importJSONAtPath:(NSString *)path error:(NSString **)error { BOOL ok=[self znm592_importJSONAtPath:path error:error]; if(ok)ZNM592SaveWorkspace(); return ok; }
- (NSString *)znm592_addFeature { NSString *name=[self znm592_addFeature]; if(name.length)ZNM592SaveWorkspace(); return name; }
- (void)znm592_addPatchToFeature:(NSString *)featureName { [self znm592_addPatchToFeature:featureName]; ZNM592SaveWorkspace(); }
- (BOOL)znm592_renameFeature:(NSString *)oldName to:(NSString *)newName error:(NSString **)error {
    id oldMax=[NSUserDefaults.standardUserDefaults objectForKey:ZNM592SliderKey(oldName)];
    BOOL ok=[self znm592_renameFeature:oldName to:newName error:error];
    if(ok) {
        if([oldMax isKindOfClass:NSNumber.class]) {
            [NSUserDefaults.standardUserDefaults setObject:oldMax forKey:ZNM592SliderKey(newName)];
            [NSUserDefaults.standardUserDefaults removeObjectForKey:ZNM592SliderKey(oldName)];
        }
        ZNM592SaveWorkspace();
    }
    return ok;
}
- (BOOL)znm592_setControlType:(ZNFeatureControlType)type forFeature:(NSString *)featureName error:(NSString **)error { BOOL ok=[self znm592_setControlType:type forFeature:featureName error:error]; if(ok)ZNM592SaveWorkspace(); return ok; }
- (BOOL)znm592_setValueType:(ZNValueType)type forFeature:(NSString *)featureName error:(NSString **)error { BOOL ok=[self znm592_setValueType:type forFeature:featureName error:error]; if(ok)ZNM592SaveWorkspace(); return ok; }
- (BOOL)znm592_removeFeatureNamed:(NSString *)featureName error:(NSString **)error { BOOL ok=[self znm592_removeFeatureNamed:featureName error:error]; if(ok){[NSUserDefaults.standardUserDefaults removeObjectForKey:ZNM592SliderKey(featureName)];ZNM592SaveWorkspace();} return ok; }
- (BOOL)znm592_removePatchAtGlobalIndex:(NSUInteger)index error:(NSString **)error { BOOL ok=[self znm592_removePatchAtGlobalIndex:index error:error]; if(ok)ZNM592SaveWorkspace(); return ok; }
@end

static void ZNM592SwapInstance(Class cls,SEL original,SEL replacement) {
    Method a=class_getInstanceMethod(cls,original),b=class_getInstanceMethod(cls,replacement);
    if(a&&b) method_exchangeImplementations(a,b);
}

extern "C" void ZNInstallM592OffsetAuthoringPersistenceDeferred(void) {
    static dispatch_once_t once; dispatch_once(&once,^{
        ZNM592RestoreWorkspace();

        Class workspace=NSClassFromString(@"ZNBinaryPatchWorkspace");
        ZNM592SwapInstance(workspace,@selector(validateAll:),@selector(znm592_validateAll:));
        ZNM592SwapInstance(workspace,@selector(updateOffset:row:),@selector(znm592_updateOffset:row:));
        ZNM592SwapInstance(workspace,@selector(updateEnabled:row:),@selector(znm592_updateEnabled:row:));
        ZNM592SwapInstance(workspace,@selector(updateDefaultTarget:),@selector(znm592_updateDefaultTarget:));
        ZNM592SwapInstance(workspace,@selector(addEmptyRow),@selector(znm592_addEmptyRow));
        ZNM592SwapInstance(workspace,@selector(importJSONAtPath:error:),@selector(znm592_importJSONAtPath:error:));
        ZNM592SwapInstance(workspace,@selector(addFeature),@selector(znm592_addFeature));
        ZNM592SwapInstance(workspace,@selector(addPatchToFeature:),@selector(znm592_addPatchToFeature:));
        ZNM592SwapInstance(workspace,@selector(renameFeature:to:error:),@selector(znm592_renameFeature:to:error:));
        ZNM592SwapInstance(workspace,@selector(setControlType:forFeature:error:),@selector(znm592_setControlType:forFeature:error:));
        ZNM592SwapInstance(workspace,@selector(setValueType:forFeature:error:),@selector(znm592_setValueType:forFeature:error:));
        ZNM592SwapInstance(workspace,@selector(removeFeatureNamed:error:),@selector(znm592_removeFeatureNamed:error:));
        ZNM592SwapInstance(workspace,@selector(removePatchAtGlobalIndex:error:),@selector(znm592_removePatchAtGlobalIndex:error:));
        ZNM592SwapInstance(workspace,@selector(setDescription:forFeature:error:),@selector(znm592_setDescription:forFeature:error:));

        Class builder=NSClassFromString(@"ZNStaticBinaryBuilder");
        Method b1=class_getClassMethod(builder,@selector(buildWorkspace:outputs:report:error:));
        Method b2=class_getClassMethod(builder,@selector(znm592_buildWorkspace:outputs:report:error:));
        if(b1&&b2) method_exchangeImplementations(b1,b2);

        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){ZNM592SaveWorkspace();}];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillTerminateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){ZNM592SaveWorkspace();}];

        [[ZNRuntimeLogger sharedLogger]log:@"[m5.9.2] Offset authoring persistence + preflight validation bypass installed in-place; no second UI hierarchy"];
    });
}
