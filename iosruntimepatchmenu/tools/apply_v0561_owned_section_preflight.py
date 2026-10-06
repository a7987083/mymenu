#!/usr/bin/env python3
from pathlib import Path

p = Path("iosruntimepatchmenu/src/ZNStaticDispatchRuntime.mm")
s = p.read_text()

if "owned-section-preflight-v1" not in s:
    vars_anchor = '''    NSUInteger fallbackImages = 0;\n    unsigned long long fallbackProbes = 0;\n    unsigned long long fallbackBytes = 0;\n\n'''
    if vars_anchor not in s:
        raise SystemExit("refresh counters anchor missing")

    preflight = r'''    // owned-section-preflight-v1: determine whether any current Builder V3
    // image in the app bundle carries the exact owned Static Dispatch section.
    // If one exists, unrelated images must never enter the legacy whole-segment
    // compatibility scan just because they do not own ZonoPatch metadata.
    BOOL anyOwnedSection = NO;
    for (uint32_t probeImageIndex = 0; probeImageIndex < imageCount && !anyOwnedSection; probeImageIndex++) {
        const char *probeRawPath = _dyld_get_image_name(probeImageIndex);
        if (!probeRawPath) continue;
        NSString *probePath = [[NSString stringWithUTF8String:probeRawPath] stringByStandardizingPath];
        if (!probePath.length || ![probePath hasPrefix:bundleRoot]) continue;

        const struct mach_header_64 *probeMH = (const struct mach_header_64 *)_dyld_get_image_header(probeImageIndex);
        if (!probeMH || probeMH->magic != MH_MAGIC_64) continue;
        const uint8_t *probeLCBase = (const uint8_t *)(probeMH + 1);
        const uint8_t *probeLCEnd = probeLCBase + probeMH->sizeofcmds;
        const struct load_command *probeLC = (const struct load_command *)probeLCBase;
        for (uint32_t i = 0; i < probeMH->ncmds; i++) {
            if ((const uint8_t *)probeLC + sizeof(*probeLC) > probeLCEnd ||
                probeLC->cmdsize < sizeof(*probeLC) ||
                (const uint8_t *)probeLC + probeLC->cmdsize > probeLCEnd) break;
            if (probeLC->cmd == LC_SEGMENT_64 && probeLC->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)probeLC;
                uint64_t sectionBytes = (uint64_t)seg->nsects * sizeof(struct section_64);
                if (strncmp(seg->segname, "__ZNDATA", 16) == 0 &&
                    probeLC->cmdsize >= sizeof(struct segment_command_64) + sectionBytes) {
                    const struct section_64 *sections = (const struct section_64 *)(seg + 1);
                    for (uint32_t j = 0; j < seg->nsects; j++) {
                        if (strncmp(sections[j].sectname, "__zndata", 16) == 0) {
                            anyOwnedSection = YES;
                            break;
                        }
                    }
                }
            }
            probeLC = (const struct load_command *)((const uint8_t *)probeLC + probeLC->cmdsize);
        }
    }
    ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] owned-section-preflight-v1 present=%@",
                          anyOwnedSection ? @"YES" : @"NO"]);

'''
    s = s.replace(vars_anchor, vars_anchor + preflight, 1)

    fallback_anchor = '''        // fallback-compat-scan: retained only for older generated binaries that\n        // predate the owned __ZNDATA/__zndata section.\n'''
    if fallback_anchor not in s:
        raise SystemExit("fallback anchor missing")

    skip = r'''        if (anyOwnedSection) {
            ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] compatibility scan skipped target=%@ reason=current-owned-section-present-elsewhere", targetName]);
            continue;
        }

'''
    s = s.replace(fallback_anchor, skip + fallback_anchor, 1)

p.write_text(s)
print("v0.5.6.1 owned-section preflight applied")
