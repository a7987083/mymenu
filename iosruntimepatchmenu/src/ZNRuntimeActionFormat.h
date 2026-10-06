#pragma once

#include <stdint.h>
#include <stddef.h>

#define ZN_RUNTIME_ACTION_MAGIC UINT64_C(0x00314E5443414E5A) /* "ZNACTN1" */
#define ZN_RUNTIME_ACTION_VERSION 1u
#define ZN_RUNTIME_ACTION_MAX_ENTRIES 128u
#define ZN_RUNTIME_ACTION_MAX_ARGUMENTS 8u

typedef uint32_t ZNRuntimeActionKind;
enum {
    ZNRuntimeActionKindInvalid = 0,
    ZNRuntimeActionKindIL2CPPMethodCall = 1,
    ZNRuntimeActionKindIL2CPPNativeHook = 2,
    ZNRuntimeActionKindDirectNativeCall = 3,
};

typedef uint32_t ZNRuntimeActionFlags;
enum {
    ZNRuntimeActionFlagNone = 0,
    ZNRuntimeActionFlagArgument0Text = 1u << 0,
    ZNRuntimeActionFlagParameterSignature = 1u << 1,
    ZNRuntimeActionFlagArgumentVectorText = 1u << 2,
    // M5.1 reserved[3] -> UTF-8 JSON per-argument runtime control config.
    ZNRuntimeActionFlagArgumentControls = 1u << 3,
    // M5.1 reserved[4] -> UTF-8 JSON Immediate Chain target descriptor.
    ZNRuntimeActionFlagImmediateChain = 1u << 4,
    // M6.3 reserved[5] -> UTF-8 feature description.
    ZNRuntimeActionFlagFeatureDescription = 1u << 5,
    // M6.4 Native Hook config JSON. For NativeHook entries reserved[0] points to it.
    ZNRuntimeActionFlagNativeHookConfig = 1u << 6,
};

typedef struct {
    uint64_t magic;
    uint32_t version;
    uint32_t count;
    uint32_t entrySize;
    uint32_t totalSize;
    uint32_t stringPoolOffset;
    uint32_t stringPoolSize;
    uint32_t flags;
    uint32_t reserved32;
    uint64_t reserved[3];
} ZNRuntimeActionHeader;

typedef struct {
    uint32_t actionID;
    uint32_t kind;
    uint32_t flags;
    uint32_t argumentCount;
    uint32_t titleOffset;
    uint32_t groupOffset;
    uint32_t assemblyOffset;
    uint32_t namespaceOffset;
    uint32_t classOffset;
    uint32_t methodOffset;
    // reserved[0] argument0 text (legacy /1)
    // reserved[1] full parameter signature
    // reserved[2] argument vector JSON
    // reserved[3] M5.1 argument control JSON
    // reserved[4] M5.1 Immediate Chain JSON
    // reserved[5] M6.3 feature description UTF-8
    uint32_t reserved[6];
} ZNRuntimeMethodCallEntry;

#if defined(__cplusplus)
static_assert(sizeof(ZNRuntimeActionHeader) == 64, "ZNRuntimeActionHeader ABI");
static_assert(sizeof(ZNRuntimeMethodCallEntry) == 64, "ZNRuntimeMethodCallEntry ABI");
static_assert(offsetof(ZNRuntimeMethodCallEntry, titleOffset) == 16, "ZNRuntimeMethodCallEntry string offsets ABI");
static_assert(offsetof(ZNRuntimeMethodCallEntry, reserved) == 40, "ZNRuntimeMethodCallEntry reserved ABI");
#endif
