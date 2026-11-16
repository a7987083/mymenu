#import "../src/ZNAdhocMachOSigner.h"
#import <mach-o/loader.h>
#import <mach/machine.h>
#import <mach/vm_prot.h>
#include <cassert>
// Inspect the actual signed SuperBlob rather than only checking resign idempotence.
static uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }
static bool validAdhocSignature(NSData *data) {
 const uint8_t *p=(const uint8_t *)data.bytes;
 if(data.length<sizeof(mach_header_64))return false;
 mach_header_64 header={};memcpy(&header,p,sizeof(header));
 size_t off=sizeof(header);uint32_t sigOff=0,sigSize=0;
 for(uint32_t i=0;i<header.ncmds;i++){
  if(off>data.length||data.length-off<sizeof(load_command))return false;
  load_command command={};memcpy(&command,p+off,sizeof(command));
  if(command.cmdsize<sizeof(load_command)||command.cmdsize>data.length-off)return false;
  if(command.cmd==LC_CODE_SIGNATURE) {
   if(command.cmdsize<sizeof(linkedit_data_command))return false;
   linkedit_data_command sig={};memcpy(&sig,p+off,sizeof(sig));
   sigOff=sig.dataoff;sigSize=sig.datasize;
  }
  off+=command.cmdsize;
 }
 if(!sigOff||sigOff>data.length||sigSize>data.length-sigOff||sigSize<36)return false;
 const uint8_t *blob=p+sigOff;
 uint32_t total=be32(blob+4),count=be32(blob+8);
 if(be32(blob)!=0xfade0cc0u||total>sigSize||count!=3||total<12+count*8)return false;
 unsigned dirs=0,reqs=0;
 for(uint32_t i=0;i<count;i++) {
  uint32_t slot=be32(blob+12+i*8),offset=be32(blob+16+i*8);
  if(offset>total||total-offset<12)return false;
  const uint8_t *entry=blob+offset;
  uint32_t length=be32(entry+4);
  if(length>total-offset)return false;
  if(slot==0||slot==0x1000) {
   if(be32(entry)!=0xfade0c02u||length<88||be32(entry+12)!=2u)return false;
   dirs++;
  }else if(slot==2) {
   if(be32(entry)!=0xfade0c01u||length!=12||be32(entry+8)!=0)return false;
   reqs++;
  }
 }
 return dirs==2&&reqs==1;
}
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
 NSData *first=[NSData dataWithContentsOfFile:path];assert(validAdhocSignature(first));assert(ZNAdhocResignMachOAtPath(path,&metadata,&error));assert([first isEqualToData:[NSData dataWithContentsOfFile:path]]);
 NSLog(@"production signer fixture/re-sign idempotence PASS");
}}
