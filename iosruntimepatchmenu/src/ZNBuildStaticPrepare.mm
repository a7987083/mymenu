#import "ZNBuildStaticPrepare.h"

#import "ZNBinaryPatchWorkspace.h"
#import "ZNFeatureControlModel.h"
#import "ZNPatchCore.h"
#import "ZNPatchRuntimeValidator.h"

#import <mach/mach.h>
#include <errno.h>
#include <math.h>
#include <stdlib.h>

static NSString * const kZNBuildStaticSliderMaxDefaults =
    @"zonoe.m5.8.5.static-slider-max.v1";

static NSString *ZNBuildStaticTrim(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *ZNBuildStaticFeatureNameForRow(ZNBinaryPatchRow *row) {
    NSString *group=ZNBuildStaticTrim(row.group);
    if(group.length && [group caseInsensitiveCompare:@"Imported"]!=NSOrderedSame)
        return group;
    NSString *title=ZNBuildStaticTrim(row.title);
    return title.length ? title : @"功能";
}

static double ZNBuildStaticSliderMaximum(NSString *featureName) {
    NSString *key=[NSString stringWithFormat:@"%@.%@",
                   kZNBuildStaticSliderMaxDefaults,
                   ZNBuildStaticTrim(featureName).lowercaseString];
    id stored=[NSUserDefaults.standardUserDefaults objectForKey:key];
    return [stored isKindOfClass:NSNumber.class] ? [stored doubleValue] : 0.0;
}

static BOOL ZNBuildStaticParseRVA(NSString *text,uint64_t *out) {
    NSString *s=ZNBuildStaticTrim(text).lowercaseString;
    if(!s.length)return NO;
    const char *c=s.UTF8String;
    char *end=NULL;
    errno=0;
    unsigned long long v=strtoull(c,&end,0);
    if(errno || end==c || (end&&*end)) {
        errno=0;
        end=NULL;
        v=strtoull(c,&end,16);
    }
    if(errno || end==c || (end&&*end))return NO;
    if(out)*out=(uint64_t)v;
    return YES;
}

static NSString *ZNBuildStaticHex(NSData *data) {
    const uint8_t *p=(const uint8_t *)data.bytes;
    NSMutableString *s=[NSMutableString stringWithCapacity:data.length*2];
    for(NSUInteger i=0;i<data.length;i++)[s appendFormat:@"%02X",p[i]];
    return s;
}

@interface ZNBuildStaticSyntheticValidator : ZNPatchRuntimeValidator
@property(nonatomic,copy) NSString *buildTarget;
@property(nonatomic,assign) uint64_t buildRVA;
@property(nonatomic,copy) NSData *buildBytes;
@property(nonatomic,assign) uintptr_t buildAddress;
@end

@implementation ZNBuildStaticSyntheticValidator
- (NSString *)target{return self.buildTarget?:@"";}
- (uint64_t)rva{return self.buildRVA;}
- (NSData *)patchBytes{return self.buildBytes;}
- (NSData *)capturedOriginalBytes{return self.buildBytes;}
- (NSData *)currentBytes{return self.buildBytes;}
- (uintptr_t)runtimeAddress{return self.buildAddress;}
- (BOOL)isConfigured{return YES;}
- (BOOL)isValidated{return YES;}
- (BOOL)isApplied{return NO;}
- (NSString *)lastResult{return @"M6.8.4 BuildManifest Static provider prepared";}
@end

BOOL ZNBuildPrepareStaticWorkspaceV1(ZNBinaryPatchWorkspace *workspace,
                                     NSString **error) {
    if(!workspace) {
        if(error)*error=@"Static Build workspace 不存在";
        return NO;
    }

    for(ZNBinaryPatchRow *row in workspace.rows ?: @[]) {
        if(!ZNBuildStaticTrim(row.offsetText).length)continue;

        ZNFeatureControlType control=row.featureControlType;
        BOOL valueRow=(control==ZNFeatureControlTypeSlider ||
                       control==ZNFeatureControlTypeNumber);
        if(!valueRow)continue;

        NSString *featureName=ZNBuildStaticFeatureNameForRow(row);
        if(control==ZNFeatureControlTypeSlider) {
            double max=ZNBuildStaticSliderMaximum(featureName);
            if(!isfinite(max) || max<=0.0) {
                if(error)*error=[NSString stringWithFormat:
                    @"%@：滑块必须在生成时填写大于 0 的最大值（例如 31）",
                    featureName];
                return NO;
            }
            if(max>16383.0) {
                if(error)*error=[NSString stringWithFormat:
                    @"%@：Static Slider 当前最大值上限为 16383",
                    featureName];
                return NO;
            }
        }

        uint64_t rva=0;
        if(!ZNBuildStaticParseRVA(row.offsetText,&rva)) {
            if(error)*error=[NSString stringWithFormat:
                @"Offset 格式无效：%@",row.offsetText?:@""];
            return NO;
        }

        NSString *global=ZNBuildStaticTrim(workspace.defaultTarget);
        BOOL autoTarget=!global.length ||
            [global caseInsensitiveCompare:@"自动"]==NSOrderedSame ||
            [global caseInsensitiveCompare:@"auto"]==NSOrderedSame;
        NSString *target=autoTarget
            ? ((row.explicitTarget && ZNBuildStaticTrim(row.target).length)
               ? ZNBuildStaticTrim(row.target) : @"main")
            : global;

        uintptr_t address=[[ZNModuleManager sharedManager]
                           runtimeAddressForModule:target rva:rva];
        if(!address) {
            if(error)*error=[NSString stringWithFormat:
                @"%@+0x%llX 无法解析运行时地址",target,rva];
            return NO;
        }

        uint8_t bytes[4]={0};
        vm_size_t copied=0;
        kern_return_t kr=vm_read_overwrite(
            mach_task_self(),
            (vm_address_t)address,
            sizeof(bytes),
            (vm_address_t)bytes,
            &copied);
        if(kr!=KERN_SUCCESS || copied!=sizeof(bytes)) {
            if(error)*error=[NSString stringWithFormat:
                @"%@+0x%llX 无法读取最小 4-byte 原始窗口 kr=%d",
                target,rva,kr];
            return NO;
        }

        NSData *data=[NSData dataWithBytes:bytes length:sizeof(bytes)];
        ZNBuildStaticSyntheticValidator *validator=
            [ZNBuildStaticSyntheticValidator new];
        validator.buildTarget=target;
        validator.buildRVA=rva;
        validator.buildBytes=data;
        validator.buildAddress=address;
        row.validator=validator;
        row.validated=YES;
        row.originalHex=ZNBuildStaticHex(data);
        row.statusText=@"BuildManifest · Static provider 已准备";
    }

    [[ZNRuntimeLogger sharedLogger] log:
        @"[m6.8.4-build-manifest] Static provider prepare complete; legacy M585/M591 build prepare bypassed"];
    return YES;
}
