#import "ZNPatchJSONImporter.h"
#import "ZNDeveloperGate.h"
#import <errno.h>
#import <stdlib.h>
#import <dirent.h>
#import <string.h>

static NSString *gZNJIDiscoveryStatus = @"尚未扫描 JSON";

static NSString *ZNJIKey(id key) {
    if (![key isKindOfClass:NSString.class]) return @"";
    NSString *s = [(NSString *)key lowercaseString];
    NSCharacterSet *drop = [NSCharacterSet characterSetWithCharactersInString:@"_- .\t\r\n"];
    return [[s componentsSeparatedByCharactersInSet:drop] componentsJoinedByString:@""];
}

static id ZNJIValue(NSDictionary *d, NSArray<NSString *> *names) {
    NSSet *wanted = [NSSet setWithArray:names];
    for (id key in d) if ([wanted containsObject:ZNJIKey(key)]) return d[key];
    return nil;
}

static NSString *ZNJIString(id v) {
    return [v isKindOfClass:NSString.class] ? [(NSString *)v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
}

static BOOL ZNJIParseRVA(id v, uint64_t *out) {
    if ([v isKindOfClass:NSNumber.class]) { if (out) *out = [(NSNumber *)v unsignedLongLongValue]; return YES; }
    NSString *s = [ZNJIString(v) lowercaseString];
    if (!s.length) return NO;
    const char *c = s.UTF8String; char *end = NULL; errno = 0;
    unsigned long long n = strtoull(c, &end, 0);
    if (errno || end == c || (end && *end)) { errno = 0; end = NULL; n = strtoull(c, &end, 16); }
    if (errno || end == c || (end && *end)) return NO;
    if (out) *out = n; return YES;
}

static NSString *ZNJIHex(id value) {
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableString *s = [NSMutableString string];
        for (id x in (NSArray *)value) {
            if (![x isKindOfClass:NSNumber.class]) return nil;
            NSInteger n = [x integerValue]; if (n < 0 || n > 255) return nil;
            [s appendFormat:@"%02lX", (long)n];
        }
        return s.length ? s : nil;
    }
    NSString *input = ZNJIString(value); if (!input.length) return nil;
    NSMutableString *s = [NSMutableString string];
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    for (NSUInteger i=0;i<input.length;i++) {
        unichar c=[input characterAtIndex:i];
        if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c] || c==':' || c=='-' || c==',' || c=='_') continue;
        if ((c=='x'||c=='X') && s.length==1 && [s isEqualToString:@"0"]) { [s setString:@""]; continue; }
        if (![hex characterIsMember:c]) return nil;
        [s appendFormat:@"%C",c];
    }
    if (!s.length || (s.length&1)) return nil;
    return s.uppercaseString;
}

static NSDictionary *ZNJIAliases(id root) {
    if (![root isKindOfClass:NSDictionary.class]) return @{};
    id t = ZNJIValue(root,@[@"targets",@"images",@"modules",@"binaries"]);
    if (![t isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *out=[NSMutableDictionary dictionary];
    [(NSDictionary *)t enumerateKeysAndObjectsUsingBlock:^(id key,id obj,BOOL *stop){
        (void)stop; NSString *alias=ZNJIString(key), *image=@"";
        if ([obj isKindOfClass:NSString.class]) image=ZNJIString(obj);
        else if ([obj isKindOfClass:NSDictionary.class]) image=ZNJIString(ZNJIValue(obj,@[@"target",@"image",@"binary",@"module",@"modulename",@"executable"]));
        if (alias.length&&image.length) out[alias.lowercaseString]=image;
    }];
    return out;
}

static NSString *ZNJIResolveTarget(NSString *t, NSDictionary *aliases) {
    NSString *x=[t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *mapped=aliases[x.lowercaseString]; return mapped.length?mapped:x;
}

static void ZNJIWalk(id node, NSString *path, NSString *parentTarget, NSString *parentTitle, NSString *parentGroup, NSDictionary *aliases, NSMutableArray *out) {
    if ([node isKindOfClass:NSArray.class]) {
        [(NSArray *)node enumerateObjectsUsingBlock:^(id obj,NSUInteger i,BOOL *stop){ (void)stop; ZNJIWalk(obj,[path stringByAppendingFormat:@"[%lu]",(unsigned long)i],parentTarget,parentTitle,parentGroup,aliases,out); }]; return;
    }
    if (![node isKindOfClass:NSDictionary.class]) return;
    NSDictionary *d=node;
    NSString *ownTarget=ZNJIString(ZNJIValue(d,@[@"target",@"image",@"binary",@"module",@"modulename",@"executable"]));
    NSString *target=ownTarget.length?ZNJIResolveTarget(ownTarget,aliases):parentTarget;
    NSString *ownTitle=ZNJIString(ZNJIValue(d,@[@"title",@"name",@"label",@"featuretitle"]));
    NSString *title=ownTitle.length?ownTitle:parentTitle;
    NSString *ownGroup=ZNJIString(ZNJIValue(d,@[@"group",@"category",@"section",@"tab"]));
    NSString *group=ownGroup.length?ownGroup:parentGroup;

    id ov=ZNJIValue(d,@[@"offset",@"rva",@"address",@"addr",@"location"]);
    id ev=ZNJIValue(d,@[@"enabled",@"patch",@"patchdata",@"bytes",@"patchbytes",@"data",@"value",@"on",@"enable",@"replacement",@"replace"]);
    uint64_t rva=0; NSString *hex=ZNJIHex(ev);
    if (ov && hex.length && ZNJIParseRVA(ov,&rva)) {
        [out addObject:@{@"target":target?:@"",@"offset":[NSString stringWithFormat:@"0x%llX",rva],@"enabled":hex,@"title":title?:@"",@"group":group.length?group:@"Imported",@"path":path?:@"$",@"confidence":@1.0}];
    } else if (!ov && !ev) {
        NSMutableArray *offs=[NSMutableArray array], *hexes=[NSMutableArray array];
        [d enumerateKeysAndObjectsUsingBlock:^(id key,id obj,BOOL *stop){
            (void)key;(void)stop; if (![obj isKindOfClass:NSString.class]) return; NSString *s=ZNJIString(obj);
            if ([s hasPrefix:@"0x"]||[s hasPrefix:@"0X"]) { uint64_t n=0; if (ZNJIParseRVA(s,&n)) [offs addObject:[NSString stringWithFormat:@"0x%llX",n]]; }
            NSString *h=ZNJIHex(s); if (h.length>=8 && (h.length%8)==0 && !([s hasPrefix:@"0x"]||[s hasPrefix:@"0X"])) [hexes addObject:h];
        }];
        if (offs.count==1 && hexes.count==1) [out addObject:@{@"target":target?:@"",@"offset":offs.firstObject,@"enabled":hexes.firstObject,@"title":title?:@"",@"group":group.length?group:@"Imported",@"path":path?:@"$",@"confidence":@0.55}];
    }

    [d enumerateKeysAndObjectsUsingBlock:^(id key,id obj,BOOL *stop){
        (void)stop; if ([obj isKindOfClass:NSDictionary.class]||[obj isKindOfClass:NSArray.class]) ZNJIWalk(obj,[path stringByAppendingFormat:@".%@",[key description]],target,title,group,aliases,out);
    }];
}

static void ZNJICollectJSONNamesPOSIX(NSString *root, NSMutableOrderedSet<NSString *> *names, NSString **posixError) {
    const char *fs=[root fileSystemRepresentation];
    errno=0;
    DIR *dir=opendir(fs);
    if (!dir) {
        if (posixError) *posixError=[NSString stringWithFormat:@"opendir errno=%d (%s)",errno,strerror(errno)];
        return;
    }
    struct dirent *ent=NULL;
    while ((ent=readdir(dir))!=NULL) {
        if (!ent->d_name[0] || !strcmp(ent->d_name,".") || !strcmp(ent->d_name,"..")) continue;
        NSString *name=[[NSString alloc] initWithUTF8String:ent->d_name];
        if (!name.length) continue;
        if ([[name.pathExtension lowercaseString] isEqualToString:@"json"]) [names addObject:name];
    }
    closedir(dir);
}

@implementation ZNPatchJSONImporter
+ (NSArray<NSString *> *)discoverJSONFiles {
    // The file `1` is the only anchor. JSON can have any basename but must be
    // an immediate sibling of `1`. No recursive scan, no fixed Documents/
    // Application Support assumption, and no BundleID-derived filename.
    ZNDeveloperGate *gate=[ZNDeveloperGate sharedGate];
    [gate refresh];
    NSString *marker=gate.markerPath;
    if (!marker.length) {
        gZNJIDiscoveryStatus=@"自动扫描失败：未找到文件 1";
        return @[];
    }

    NSString *root=[marker stringByDeletingLastPathComponent];
    NSFileManager *fm=NSFileManager.defaultManager;
    BOOL isDir=NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) {
        gZNJIDiscoveryStatus=[NSString stringWithFormat:@"自动扫描失败：1 的父目录不存在 · %@",root];
        return @[];
    }

    NSError *foundationError=nil;
    NSArray<NSString *> *foundationNames=[fm contentsOfDirectoryAtPath:root error:&foundationError];
    NSMutableOrderedSet<NSString *> *names=[NSMutableOrderedSet orderedSet];
    for (NSString *name in foundationNames ?: @[]) {
        if ([[name.pathExtension lowercaseString] isEqualToString:@"json"]) [names addObject:name];
    }

    // Device fallback: if Foundation listing fails or unexpectedly sees zero
    // JSON siblings, ask libc for the same exact directory (still non-recursive).
    NSString *posixError=nil;
    if (!foundationNames || names.count==0) ZNJICollectJSONNamesPOSIX(root,names,&posixError);

    NSMutableArray<NSString *> *found=[NSMutableArray array];
    for (NSString *name in names) {
        NSString *candidate=[root stringByAppendingPathComponent:name];
        BOOL childDir=NO;
        if (![fm fileExistsAtPath:candidate isDirectory:&childDir] || childDir) continue;
        [found addObject:candidate];
    }
    [found sortUsingComparator:^NSComparisonResult(NSString *a,NSString *b){ return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent]; }];

    NSString *method=(foundationNames?@"Foundation":@"POSIX");
    if (found.count) {
        gZNJIDiscoveryStatus=[NSString stringWithFormat:@"与 1 同目录：发现 %lu 个 JSON · %@",(unsigned long)found.count,method];
    } else {
        NSMutableArray<NSString *> *parts=[NSMutableArray arrayWithObject:[NSString stringWithFormat:@"与 1 同目录未发现 JSON · %@",root]];
        if (foundationError) [parts addObject:[NSString stringWithFormat:@"Foundation: %@",foundationError.localizedDescription?:@"未知错误"]];
        if (posixError.length) [parts addObject:[NSString stringWithFormat:@"POSIX: %@",posixError]];
        gZNJIDiscoveryStatus=[parts componentsJoinedByString:@" · "];
    }
    return found;
}

+ (NSString *)discoveryStatus {
    return gZNJIDiscoveryStatus ?: @"尚未扫描 JSON";
}

+ (NSArray<NSDictionary *> *)importFile:(NSString *)path error:(NSString **)error {
    NSError *readError=nil;
    NSData *data=[NSData dataWithContentsOfFile:path options:0 error:&readError];
    if (!data.length) {
        if(error)*error=[NSString stringWithFormat:@"JSON 文件读取失败或为空：%@%@",path.lastPathComponent?:@"未知文件",readError?[NSString stringWithFormat:@" · %@",readError.localizedDescription?:@"未知错误"]:@""];
        return nil;
    }
    NSError *je=nil; id root=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:&je];
    if (!root) { if(error)*error=[NSString stringWithFormat:@"JSON 解析失败：%@",je.localizedDescription?:@"未知错误"]; return nil; }
    NSMutableArray *raw=[NSMutableArray array]; ZNJIWalk(root,@"$",@"",@"",@"Imported",ZNJIAliases(root),raw);
    if (!raw.count) { if(error)*error=@"未识别到 offset + enabled/patch/patchData/bytes 组合"; return nil; }

    NSMutableArray *out=[NSMutableArray array]; NSMutableSet *seen=[NSMutableSet set];
    for (NSDictionary *r in raw) {
        NSString *key=[NSString stringWithFormat:@"%@|%@|%@",[r[@"target"] lowercaseString],[r[@"offset"] lowercaseString],[r[@"enabled"] uppercaseString]];
        if ([seen containsObject:key]) continue; [seen addObject:key]; [out addObject:r];
    }
    return out;
}
@end
