from pathlib import Path

ROOT = Path('iosruntimepatchmenu')
SRC = ROOT / 'src'


def replace_once(path: Path, old: str, new: str, label: str):
    text = path.read_text()
    if new in text:
        return
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one old block, got {count}')
    path.write_text(text.replace(old, new, 1))


def splice_once(path: Path, start_marker: str, end_marker: str, replacement: str, label: str):
    text = path.read_text()
    if replacement.strip() in text:
        return
    start = text.find(start_marker)
    if start < 0:
        raise SystemExit(f'{label}: start marker not found')
    end = text.find(end_marker, start)
    if end < 0:
        raise SystemExit(f'{label}: end marker not found')
    path.write_text(text[:start] + replacement + text[end:])


# 1) ABI-compatible header flag. Protection V2 changes executable layout only;
# Static Header/Entry sizes and RVA Protection V1 remain unchanged.
fmt = SRC / 'ZNStaticPatchFormat.h'
replace_once(
    fmt,
    '#define ZN44_STATIC_HEADER_FLAG_RVA_PROTECTION_V1   UINT32_C(0x00000002)\n',
    '#define ZN44_STATIC_HEADER_FLAG_RVA_PROTECTION_V1   UINT32_C(0x00000002)\n'
    '#define ZN44_STATIC_HEADER_FLAG_PAYLOAD_PROTECTION_V2 UINT32_C(0x00000004)\n',
    'payload-v2 header flag')

builder = SRC / 'ZNStaticBinaryBuilderV3.mm'
text = builder.read_text()
if '#import "ZNStaticPayloadProtectionV2.h"' not in text:
    text = text.replace('#import "ZNStaticPatchFormat.h"\n',
                        '#import "ZNStaticPatchFormat.h"\n#import "ZNStaticPayloadProtectionV2.h"\n', 1)
if '#import <stdlib.h>' not in text:
    text = text.replace('#import <string.h>\n', '#import <string.h>\n#import <stdlib.h>\n', 1)
builder.write_text(text)

# 2) Replace the contiguous-variant writer with per-instruction shuffled slots.
# Each logical ARM64 instruction occupies its own 16-byte slot. The first slot
# restores x16/x17, every non-terminal slot explicitly branches to the next
# shuffled slot, and the last slot branches back to the original resume RVA.
# Therefore no two source instructions are stored as one contiguous sequence.
text = builder.read_text()
if 'static BOOL ZNV3WriteVariantV2(' not in text:
    start = text.find('static BOOL ZNV3WriteVariant(')
    end = text.find('static void ZNV3CopyFixed', start)
    if start < 0 or end < 0:
        raise SystemExit('variant writer markers not found')
    writer = r'''static BOOL ZNV3WriteVariantV2(uint8_t *base,
                               uint64_t fileOffset,
                               uint64_t variantRVA,
                               uint64_t reserved,
                               NSData *source,
                               uint64_t sourceRVA,
                               uint64_t windowStart,
                               uint64_t windowEnd,
                               uint64_t resumeRVA,
                               uint64_t layoutState,
                               uint64_t *entryRVAOut,
                               uint32_t *fragmentCountOut,
                               NSString **error) {
    const uint32_t NOP = 0xD503201Fu;
    const uint32_t LDP_X16_X17_POST = 0xA8C147F0u;
    if (!source.length || (source.length & 3u)) {
        if (error) *error = @"Protection V2 Variant 长度必须为 4-byte 倍数";
        return NO;
    }

    uint64_t slotCount64 = source.length / 4u;
    uint64_t required = ZN60VariantReservedBytes((uint64_t)source.length);
    if (!required || reserved < required || slotCount64 > UINT32_MAX) {
        if (error) *error = @"Protection V2 Variant slot 预算无效";
        return NO;
    }
    for (uint64_t p = 0; p < reserved; p += 4) ZNV3Write32(base + fileOffset + p, NOP);

    std::vector<uint32_t> slots((size_t)slotCount64);
    for (uint32_t i = 0; i < (uint32_t)slotCount64; ++i) slots[i] = i;
    ZN60ShuffleU32(slots.data(), slots.size(), layoutState);
    if (!ZN60IsPermutationU32(slots.data(), slots.size())) {
        if (error) *error = @"Protection V2 slot permutation 损坏";
        return NO;
    }

    const uint8_t *sourceBytes = (const uint8_t *)source.bytes;
    BOOL terminalSeen = NO;
    uint32_t emitted = 0;
    if (entryRVAOut) *entryRVAOut = variantRVA + (uint64_t)slots[0] * ZN60_PAYLOAD_SLOT_SIZE;

    for (uint32_t logicalIndex = 0; logicalIndex < (uint32_t)slotCount64; ++logicalIndex) {
        if (terminalSeen) break;
        uint64_t slotOffset = (uint64_t)slots[logicalIndex] * ZN60_PAYLOAD_SLOT_SIZE;
        uint64_t instructionFileOffset = fileOffset + slotOffset;
        uint64_t instructionRVA = variantRVA + slotOffset;

        // Only the entry fragment restores registers saved by the dispatch thunk.
        if (logicalIndex == 0) {
            ZNV3Write32(base + instructionFileOffset, LDP_X16_X17_POST);
            instructionFileOffset += 4;
            instructionRVA += 4;
        }

        uint32_t relocated = 0;
        BOOL terminal = NO;
        uint64_t originalInstructionRVA = sourceRVA + (uint64_t)logicalIndex * 4u;
        if (!ZNV3Relocate(ZNV3Read32(sourceBytes + (size_t)logicalIndex * 4u),
                          originalInstructionRVA,
                          instructionRVA,
                          windowStart,
                          windowEnd,
                          &relocated,
                          &terminal,
                          error)) return NO;
        ZNV3Write32(base + instructionFileOffset, relocated);
        emitted++;

        if (terminal) {
            terminalSeen = YES;
            continue;
        }

        uint64_t branchInstructionRVA = instructionRVA + 4u;
        uint64_t nextRVA = resumeRVA;
        if (logicalIndex + 1u < (uint32_t)slotCount64) {
            nextRVA = variantRVA + (uint64_t)slots[logicalIndex + 1u] * ZN60_PAYLOAD_SLOT_SIZE;
        }
        uint32_t nextBranch = 0;
        if (!ZNV3EncodeB(branchInstructionRVA, nextRVA, NO, &nextBranch)) {
            if (error) *error = @"Protection V2 fragment 链超出 ARM64 B ±128MB";
            return NO;
        }
        ZNV3Write32(base + instructionFileOffset + 4u, nextBranch);
    }

    if (fragmentCountOut) *fragmentCountOut = emitted;
    return YES;
}

static BOOL ZNV3WriteThunkV2(uint8_t *base,
                             uint64_t fileOffset,
                             uint64_t thunkRVA,
                             uint64_t reserved,
                             uint64_t selectedTargetEntryRVA,
                             uint64_t offRVA,
                             uint64_t layoutState,
                             NSString **error) {
    const uint32_t STP_X16_X17_PRE = 0xA9BF47F0u;
    const uint32_t BR_X17 = 0xD61F0220u;
    const uint32_t NOP = 0xD503201Fu;
    if (reserved < 32u) {
        if (error) *error = @"Protection V2 thunk 预算不足";
        return NO;
    }
    for (uint64_t p = 0; p < reserved; p += 4) ZNV3Write32(base + fileOffset + p, NOP);

    uint32_t nopCount = (uint32_t)(ZN60NextLayoutWord(&layoutState) % 3u);
    uint64_t offBranchRVA = thunkRVA + 16u + (uint64_t)nopCount * 4u;
    uint64_t selectedBranchRVA = offBranchRVA + 4u;
    uint64_t cbnzRVA = thunkRVA + 12u;
    int64_t cbnzDelta = (int64_t)selectedBranchRVA - (int64_t)cbnzRVA;
    if ((cbnzDelta & 3) || cbnzDelta <= 0 || cbnzDelta >= (1LL << 20)) {
        if (error) *error = @"Protection V2 thunk CBNZ 布局无效";
        return NO;
    }
    uint32_t cbnz = 0xB5000011u | (((uint32_t)(cbnzDelta >> 2) & 0x7FFFFu) << 5);

    uint32_t adrp = 0;
    uint32_t offBranch = 0;
    if (!ZNV3EncodeADRPX17(thunkRVA + 4u, selectedTargetEntryRVA, &adrp)) {
        if (error) *error = @"Protection V2 thunk → selectedTarget ADRP 超出 ±4GB";
        return NO;
    }
    if (!ZNV3EncodeB(offBranchRVA, offRVA, NO, &offBranch)) {
        if (error) *error = @"Protection V2 thunk OFF fallback 超出 ARM64 B ±128MB";
        return NO;
    }

    ZNV3Write32(base + fileOffset + 0u, STP_X16_X17_PRE);
    ZNV3Write32(base + fileOffset + 4u, adrp);
    ZNV3Write32(base + fileOffset + 8u, ZNV3LdrX17FromX17(selectedTargetEntryRVA));
    ZNV3Write32(base + fileOffset + 12u, cbnz);
    for (uint32_t i = 0; i < nopCount; ++i) ZNV3Write32(base + fileOffset + 16u + (uint64_t)i * 4u, NOP);
    ZNV3Write32(base + fileOffset + 16u + (uint64_t)nopCount * 4u, offBranch);
    ZNV3Write32(base + fileOffset + 20u + (uint64_t)nopCount * 4u, BR_X17);
    return YES;
}

'''
    builder.write_text(text[:start] + writer + text[end:])

# 3) Per-output random nonce and counters. Nonce itself is intentionally not
# written to the report; only a one-way-ish mixed layout tag is exported.
text = builder.read_text()
needle = '    uint64_t codeSegmentSize = 0;\n    uint64_t dataSegmentSize = 0;\n'
if 'uint64_t protectionV2Nonce = 0;' not in text:
    if text.count(needle) != 1:
        raise SystemExit('builder local budget marker not found')
    repl = needle + '''    uint64_t protectionV2Nonce = 0;
    arc4random_buf(&protectionV2Nonce, sizeof(protectionV2Nonce));
    if (!protectionV2Nonce) protectionV2Nonce = ZN60Mix64((uint64_t)oldFileSize ^ (uint64_t)rows.count ^ UINT64_C(0x605056325A4E));
    uint64_t protectionV2LayoutTag = ZN60Mix64(protectionV2Nonce ^ UINT64_C(0x76302E352E365A4E));
    uint64_t protectionV2Fragments = 0;
    uint64_t protectionV2Variants = 0;
'''
    text = text.replace(needle, repl, 1)
    builder.write_text(text)

# 4) Budget fixed strides: each instruction gets a 16-byte slot, each variant
# gets 64 bytes of randomized head/tail placement budget, and each physical
# site gets a 48-byte thunk stride with a variable 24/28/32-byte live template.
text = builder.read_text()
if 'const uint64_t thunkStride=ZN60_PAYLOAD_THUNK_STRIDE;' not in text:
    start = text.find('        const uint64_t thunkSize=24;')
    end_marker = '        codeNeeded+=32;'
    end = text.find(end_marker, start)
    if start < 0 or end < 0:
        raise SystemExit('builder budget block not found')
    end += len(end_marker)
    budget = r'''        const uint64_t thunkStride=ZN60_PAYLOAD_THUNK_STRIDE;
        for(const ZNV3Physical &physical:physicals){
            uint64_t variantStride=ZN60VariantStrideBytes(physical.window);
            if(!variantStride){localError=@"Protection V2 Variant stride 计算失败";break;}
            NSMutableArray<NSData *> *unique=[NSMutableArray array];
            for(size_t logicalIndex:physical.members){
                NSData *source=ZNV3ComposedVariant(physical,logicals[logicalIndex]);
                if(!source){localError=@"Variant 合成失败";break;}
                BOOL exists=NO; for(NSData *x in unique)if([x isEqualToData:source]){exists=YES;break;}
                if(!exists)[unique addObject:source];
            }
            if(localError)break;
            codeNeeded=ZNV3Align(codeNeeded,16)+thunkStride+variantStride*(1+unique.count);
        }
        if(localError)break;
        codeNeeded+=64;'''
    builder.write_text(text[:start] + budget + text[end:])

# 5) Mark the ABI-compatible Static Header as carrying Protection V2 layout.
replace_once(
    builder,
    '                    header->entrySize=sizeof(ZN44StaticEntry);\n',
    '                    header->entrySize=sizeof(ZN44StaticEntry);\n'
    '                    header->flags |= ZN44_STATIC_HEADER_FLAG_PAYLOAD_PROTECTION_V2;\n',
    'builder payload-v2 header flag')

# 6) Replace deterministic thunk + contiguous OFF/ON placement with randomized
# thunk positioning and shuffled fragment chains. Site remains one 4-byte ARM64
# B because some validated patch windows are only one instruction; V2 does not
# claim that this architectural branch can be hidden.
text = builder.read_text()
if 'ZNV3WriteVariantV2(base,offFileOffset' not in text:
    start = text.find('                    const uint32_t STP_X16_X17_PRE=0xA9BF47F0u;')
    end_marker = '\n\n                    for(size_t i=0;i<logicals.size();i++){'
    end = text.find(end_marker, start)
    if start < 0 or end < 0:
        raise SystemExit('builder write block not found')
    block = r'''                    const uint32_t NOP=0xD503201Fu;
                    const uint64_t thunkStride=ZN60_PAYLOAD_THUNK_STRIDE;
                    uint64_t codeCursor=codeFileOffset;

                    for(size_t p=0;p<physicals.size();p++){
                        ZNV3Physical &physical=physicals[p];
                        uint64_t thunkState=ZN60DeriveLayoutState(protectionV2Nonce,physical.rva,0x80000000u|(uint32_t)p);
                        uint64_t thunkBase=ZNV3Align(codeCursor,16);
                        uint64_t thunkPad=(ZN60NextLayoutWord(&thunkState)&1u)?16u:0u;
                        uint64_t thunkFileOffset=thunkBase+thunkPad;
                        uint64_t thunkRVA=codeRVA+(thunkFileOffset-codeFileOffset);
                        codeCursor=thunkBase+thunkStride;

                        uint64_t variantReserved=ZN60VariantReservedBytes(physical.window);
                        uint64_t variantStride=ZN60VariantStrideBytes(physical.window);
                        if(!variantReserved||!variantStride){localError=@"Protection V2 Variant region 计算失败";break;}

                        uint64_t offState=ZN60DeriveLayoutState(protectionV2Nonce,physical.rva,0u);
                        uint64_t offRegionBase=ZNV3Align(codeCursor,16);
                        uint64_t offPad=(ZN60NextLayoutWord(&offState)%5u)*16u;
                        uint64_t offFileOffset=offRegionBase+offPad;
                        uint64_t offRegionRVA=codeRVA+(offFileOffset-codeFileOffset);
                        codeCursor=offRegionBase+variantStride;
                        uint64_t offRVA=0;
                        uint32_t offFragments=0;
                        if(!ZNV3WriteVariantV2(base,offFileOffset,offRegionRVA,variantReserved,physical.original,physical.rva,
                                               physical.rva,physical.rva+physical.window,physical.rva+physical.window,
                                               offState,&offRVA,&offFragments,&localError))break;
                        protectionV2Variants++;
                        protectionV2Fragments+=offFragments;
                        physical.thunkRVA=thunkRVA;
                        physical.offRVA=offRVA;

                        NSMutableArray<NSData *> *writtenSources=[NSMutableArray array];
                        NSMutableArray<NSNumber *> *writtenRVAs=[NSMutableArray array];
                        for(size_t logicalIndex:physical.members){
                            NSData *source=ZNV3ComposedVariant(physical,logicals[logicalIndex]);
                            NSUInteger found=NSNotFound;
                            for(NSUInteger j=0;j<writtenSources.count;j++)if([writtenSources[j] isEqualToData:source]){found=j;break;}
                            if(found!=NSNotFound){onRVAs[logicalIndex]=writtenRVAs[found].unsignedLongLongValue;continue;}

                            uint32_t variantOrdinal=(uint32_t)writtenSources.count+1u;
                            uint64_t onState=ZN60DeriveLayoutState(protectionV2Nonce,physical.rva,variantOrdinal);
                            uint64_t onRegionBase=ZNV3Align(codeCursor,16);
                            uint64_t onPad=(ZN60NextLayoutWord(&onState)%5u)*16u;
                            uint64_t onFileOffset=onRegionBase+onPad;
                            uint64_t onRegionRVA=codeRVA+(onFileOffset-codeFileOffset);
                            codeCursor=onRegionBase+variantStride;
                            uint64_t onEntryRVA=0;
                            uint32_t onFragments=0;
                            if(!ZNV3WriteVariantV2(base,onFileOffset,onRegionRVA,variantReserved,source,physical.rva,
                                                   physical.rva,physical.rva+physical.window,physical.rva+physical.window,
                                                   onState,&onEntryRVA,&onFragments,&localError))break;
                            protectionV2Variants++;
                            protectionV2Fragments+=onFragments;
                            [writtenSources addObject:source]; [writtenRVAs addObject:@(onEntryRVA)]; onRVAs[logicalIndex]=onEntryRVA;
                        }
                        if(localError)break;

                        size_t canonicalLogical=physical.members.front();
                        uint64_t entryRVA=dataRVA+sizeof(ZN44StaticHeader)+canonicalLogical*sizeof(ZN44StaticEntry);
                        if(entryRVA&7u){localError=@"V3 canonical selectedTarget 未 8-byte 对齐";break;}
                        if(!ZNV3WriteThunkV2(base,thunkFileOffset,thunkRVA,32u,entryRVA,offRVA,thunkState,&localError))break;

                        uint32_t siteBranch=0;
                        if(!ZNV3EncodeB(physical.rva,thunkRVA,NO,&siteBranch)){localError=@"Site → Protection V2 thunk 超出 ±128MB";break;}
                        ZNV3Write32(base+physical.fileoff,siteBranch);
                        for(uint64_t q=4;q<physical.window;q+=4)ZNV3Write32(base+physical.fileoff+q,NOP);
                    }
                    if(localError)break;
                    if(codeCursor-codeFileOffset>codeNeeded){localError=@"Protection V2 __ZNTEXT 预算计算错误";break;}'''
    builder.write_text(text[:start] + block + text[end:])

# 7) Build-report evidence. The random nonce is not exported. layoutTag exists
# only to confirm two generated outputs do not share the same layout plan.
text = builder.read_text()
old_meta = '                        @"bootSafeOffFallback":@YES,\n                        @"needsResign":@YES\n'
new_meta = '                        @"bootSafeOffFallback":@YES,\n                        @"payloadProtectionV2":@YES,\n                        @"payloadLayout":@"fragmented-16-byte-slot-chain-v1",\n                        @"maxContiguousSourceInstructions":@1,\n                        @"variantEntryPermutation":@YES,\n                        @"thunkTemplateDiversification":@YES,\n                        @"runtimeExecutableWrites":@NO,\n                        @"payloadVariantCount":@(protectionV2Variants),\n                        @"payloadFragmentCount":@(protectionV2Fragments),\n                        @"layoutTag":[NSString stringWithFormat:@"%016llX",protectionV2LayoutTag],\n                        @"needsResign":@YES\n'
if new_meta not in text:
    if text.count(old_meta) != 1:
        raise SystemExit('builder metadata marker not found')
    text = text.replace(old_meta, new_meta, 1)

text = text.replace('@"format":@"com.zonoe.static-dispatch/v3-owned-segments",',
                    '@"format":@"com.zonoe.static-dispatch/v3-owned-segments-protection-v2",', 1)
text = text.replace('@"Dispatch code and all variants live in the newly owned __ZNTEXT/__zncode segment",',
                    '@"Dispatch code and all variants live in the newly owned __ZNTEXT/__zncode segment",\n            @"Protection V2 stores each relocated source instruction in an independently shuffled 16-byte fragment slot",\n            @"Protection V2 varies thunk live length and entry placement per generated output; it is a static-analysis cost layer, not cryptographic secrecy",', 1)
text = text.replace('@"Runtime changes RW selectedTarget only; executable pages are not modified after launch",',
                    '@"Runtime changes RW selectedTarget only; executable pages are not modified after launch",\n            @"Original patch sites remain one direct ARM64 B where the validated overwrite window is one instruction; V2 does not claim to hide this architectural requirement",', 1)
builder.write_text(text)

# Add a small separate validation manifest for device handoff.
text = builder.read_text()
validation_anchor = '    [json writeToFile:reportPath atomically:YES];[paths addObject:reportPath];\n'
if 'protection_v2_validation.json' not in text:
    if text.count(validation_anchor) != 1:
        raise SystemExit('builder report write marker not found')
    validation = validation_anchor + r'''    NSDictionary *protectionV2Validation=@{
        @"format":@"com.zonoe.protection-v2-validation/v1",
        @"version":@"0.5.6",
        @"payloadLayout":@"fragmented-16-byte-slot-chain-v1",
        @"headerFlag":[NSString stringWithFormat:@"0x%08X",ZN44_STATIC_HEADER_FLAG_PAYLOAD_PROTECTION_V2],
        @"maxContiguousSourceInstructions":@1,
        @"runtimeExecutableWrites":@NO,
        @"targets":metadata,
        @"deviceChecks":@[
            @"Cold launch without tapping ZN: no Patch Runtime or saved feature restoration",
            @"First tap completes deferred bootstrap before menu appears",
            @"OFF path matches original behavior",
            @"ON path matches enabled behavior",
            @"Shared-site owner fallback remains correct",
            @"Kill/relaunch stays OFF until first ZN tap, then restores saved state",
            @"Generated Mach-O installs and launches after normal package re-sign"
        ]
    };
    NSData *validationJSON=[NSJSONSerialization dataWithJSONObject:protectionV2Validation options:NSJSONWritingPrettyPrinted error:nil];
    NSString *validationPath=[folder stringByAppendingPathComponent:@"protection_v2_validation.json"];
    if(validationJSON){[validationJSON writeToFile:validationPath atomically:YES];[paths addObject:validationPath];}
'''
    text = text.replace(validation_anchor, validation, 1)
builder.write_text(text)

# 8) Runtime diagnostics know whether the current generated Mach-O carries V2.
runtime = SRC / 'ZNStaticDispatchRuntime.mm'
text = runtime.read_text()
if '@property(nonatomic,assign) BOOL payloadProtectionV2;' not in text:
    text = text.replace('@property(nonatomic,assign) uint32_t headerVersion;\n',
                        '@property(nonatomic,assign) uint32_t headerVersion;\n@property(nonatomic,assign) BOOL payloadProtectionV2;\n', 1)
if 'record.payloadProtectionV2 = ' not in text:
    text = text.replace('                            record.headerVersion = header->version;\n',
                        '                            record.headerVersion = header->version;\n                            record.payloadProtectionV2 = (header->flags & ZN44_STATIC_HEADER_FLAG_PAYLOAD_PROTECTION_V2) != 0;\n', 1)
old_log = '        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[static-dispatch] detected %lu logical entries · %lu physical sites · %lu shared · RVA-protection-aware", (unsigned long)found.count, (unsigned long)counts.count, (unsigned long)shared]];\n'
new_log = '        NSUInteger payloadV2 = 0; for (ZNStaticPatchRecord *r in found) if (r.payloadProtectionV2) payloadV2++;\n        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[static-dispatch] detected %lu logical entries · %lu physical sites · %lu shared · payload-v2=%lu/%lu · RVA-protection-aware", (unsigned long)found.count, (unsigned long)counts.count, (unsigned long)shared, (unsigned long)payloadV2, (unsigned long)found.count]];\n'
if new_log not in text:
    if text.count(old_log) != 1:
        raise SystemExit('runtime summary log marker not found')
    text = text.replace(old_log, new_log, 1)
old_diag = '    [lines addObject:[NSString stringWithFormat:@"Static Dispatch：%lu 逻辑项 / %lu 物理 Site", (unsigned long)self.records.count, (unsigned long)sites.count]];\n'
new_diag = '    NSUInteger payloadV2 = 0; for (ZNStaticPatchRecord *r in self.records) if (r.payloadProtectionV2) payloadV2++;\n    [lines addObject:[NSString stringWithFormat:@"Static Dispatch：%lu 逻辑项 / %lu 物理 Site · Payload V2 %lu/%lu", (unsigned long)self.records.count, (unsigned long)sites.count, (unsigned long)payloadV2, (unsigned long)self.records.count]];\n'
if new_diag not in text:
    if text.count(old_diag) != 1:
        raise SystemExit('runtime diagnostic marker not found')
    text = text.replace(old_diag, new_diag, 1)
runtime.write_text(text)

# 9) Postprocess report: payload transformation is already complete before
# ZNF1/RVA protection/signing; keep those later stages exactly as v0.5.4.
post = SRC / 'ZNGeneratedBinaryPostprocess.mm'
p = post.read_text()
p = p.replace('@"mode": @"explicit-v0.5.4",', '@"mode": @"explicit-v0.5.6",')
p = p.replace('@"postprocessOrder": @[@"ZNF1", @"Static RVA Protection V1", @"Adhoc CodeDirectory"],',
              '@"postprocessOrder": @[@"Payload Layout V2 (Builder)", @"ZNF1", @"Static RVA Protection V1", @"Adhoc CodeDirectory"],')
p = p.replace('@"mode": @"static-rva-protection-v1",', '@"mode": @"payload-v2+static-rva-protection-v1",')
needle = '            @"scope": @"static-analysis-cost-layer",\n'
addition = ('            @"scope": @"static-analysis-cost-layer",\n'
            '            @"payloadProtectionV2": @YES,\n'
            '            @"payloadLayout": @"fragmented-16-byte-slot-chain-v1",\n'
            '            @"maxContiguousSourceInstructions": @1,\n'
            '            @"runtimeExecutableWrites": @NO,\n'
            '            @"directSiteBranchStillArchitectural": @YES,\n')
if addition not in p:
    if p.count(needle) != 1:
        raise SystemExit('postprocess protection report marker not found')
    p = p.replace(needle, addition, 1)
p = p.replace('v0.5.4 使用显式构建流水线：V3 → ZNF1 → Static RVA Protection V1 → ad-hoc CodeDirectory。',
              'v0.5.6 使用显式保护流水线：V3 Payload V2 → ZNF1 → Static RVA Protection V1 → ad-hoc CodeDirectory。')
post.write_text(p)

# 10) Current version surfaces only. Historical compatibility strings are not
# globally rewritten.
menu = SRC / 'ZonoeRuntimeMenu.mm'
m = menu.read_text()
m = m.replace('0.5.5-ui-core', '0.5.6-ui-core')
m = m.replace('0.5.5-ui-consolidated', '0.5.6-ui-consolidated')
m = m.replace('v0.5.5 current UI installed after first launcher tap', 'v0.5.6 current UI installed after first launcher tap')
m = m.replace('PatchCore 0.5.5', 'PatchCore 0.5.6')
menu.write_text(m)

compact = SRC / 'ZNPublicCompactUI.mm'
c = compact.read_text().replace('0.5.5', '0.5.6')
compact.write_text(c)

feature = SRC / 'ZNFeatureGroupUI.mm'
f = feature.read_text().replace('v0.5.5 feature UI installed after first activation', 'v0.5.6 feature UI installed after first activation')
feature.write_text(f)

deferred = SRC / 'ZNDeferredBootstrap.mm'
d = deferred.read_text().replace('v0.5.5 deferred activation failed', 'v0.5.6 deferred activation failed')
d = d.replace('The only v0.5.5 load-time constructor', 'The only v0.5.6 load-time constructor')
deferred.write_text(d)

print('v0.5.6 Protection V2 transform complete')
