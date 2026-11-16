#import "../src/ZNAdhocMachOSigner.h"
#import <mach-o/loader.h>
#import <mach/machine.h>
#import <mach/vm_prot.h>
#include <cassert>
int main(int argc,char **argv){@autoreleasepool{
 assert(argc==2);NSString *dir=[NSString stringWithUTF8String:argv[1]];
 [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
 NSString *path=[dir stringByAppendingPathComponent:@"fixture.dylib"];
 NSMutableData *data=[NSMutableData dataWithLength:0x5000];uint8_t *p=(uint8_t*)data.mutableBytes;
 mach_header_64 h={};h.magic=MH_MAGIC_64;h.cputype=CPU_TYPE_ARM64;h.filetype=MH_DYLIB;h.ncmds=3;h.sizeofcmds=2*sizeof(segment_command_64)+sizeof(linkedit_data_command);memcpy(p,&h,sizeof(h));
 segment_command_64 text={};text.cmd=LC_SEGMENT_64;text.cmdsize=sizeof(text);strcpy(text.segname,"__TEXT");text.vmaddr=0x100000000;text.vmsize=0x4000;text.filesize=0x4000;text.maxprot=text.initprot=VM_PROT_READ|VM_PROT_EXECUTE;memcpy(p+sizeof(h),&text,sizeof(text));
 segment_command_64 link={};link.cmd=LC_SEGMENT_64;link.cmdsize=sizeof(link);strcpy(link.segname,"__LINKEDIT");link.vmaddr=0x100004000;link.vmsize=0x4000;link.fileoff=0x4000;link.filesize=0x1000;link.maxprot=link.initprot=VM_PROT_READ;memcpy(p+sizeof(h)+sizeof(text),&link,sizeof(link));
 linkedit_data_command sig={LC_CODE_SIGNATURE,sizeof(sig),0x4000,0x1000};memcpy(p+sizeof(h)+2*sizeof(text),&sig,sizeof(sig));
 for(size_t i=0x1000;i<0x4000;i++)p[i]=uint8_t(i*31+7);
 assert([data writeToFile:path atomically:YES]);NSString *error=nil;NSDictionary *metadata=nil;
 assert(ZNAdhocResignMachOAtPath(path,&metadata,&error));assert(metadata.count>0);
 NSData *first=[NSData dataWithContentsOfFile:path];assert(ZNAdhocResignMachOAtPath(path,&metadata,&error));assert([first isEqualToData:[NSData dataWithContentsOfFile:path]]);
 NSLog(@"production signer fixture/re-sign idempotence PASS");
}}
