# M6.13.3 Runtime Call — parameter marshalling contract (experimental)

**Baseline:** `feature/m6.13.1-single-result-card-v1` @ `b63329732043f650c6f0fdbacada09e0f7313629`

**Scope:** Shared custom value-type parameter marshalling for `/1` Runtime Calls in `ZNIL2CPPInvokeEngine.mm` and `/2–/8` calls in `ZNM47MultiArgInvoke.mm`. Native Hook, UI, startup hooks, trampoline, and static-prepatch paths are untouched.

## Design

1. Continue using `il2cpp_runtime_invoke` (not a handwritten arm64 direct-call ABI).
2. Keep scalar, enum and `System.String` parameter encoding in the existing stable paths for both `/1` and `/2–/8`.
3. Keep Vector2 / Vector3 / Quaternion / Color textual encoders unchanged.
4. Delegate other `ComplexValueType` parameters to `ZNRuntimeArgumentMarshaller`, keyed by the **fully-qualified managed type name**.
5. Derive the value-type byte length from the actual `MethodInfo` parameter's IL2CPP `Class` using `il2cpp_method_get_param`, `il2cpp_class_from_type`, `il2cpp_class_value_size`. Reject absent metadata, invalid length or unsafe alignment.
6. Registered encoders return an **unboxed, exact-size** NSData blob. Retain its NSMutableData storage through the entire `il2cpp_runtime_invoke` call.
7. For a non-registered custom value type and numeric input, inspect the actual IL2CPP class for a **static `op_Implicit` from int32/int64/float/double returning the same value type**, invoke the game's own conversion method with `il2cpp_runtime_invoke`, unbox, and copy the exact verified size. Prefer int32 for in-range integer input. This is an opt-in-by-API semantic path, not hard-coded field guessing.
8. Unknown types do **not** fall back to a guessed int/float layout. An explicit `hex:` exact-size blob is supported for diagnostic/research usage only; no promise of correct semantics follows from a byte-length match.

## Example: a version-specific custom encoder

```objective-c
[ZNRuntimeArgumentMarshaller registerValueType:@"Vendor.MyStruct"
    encoder:^NSData *(NSString *input, NSUInteger expectedSize, NSString **error) {
        // Decode input into an exact, version-validated *unboxed* IL2CPP struct.
        // If the target's actual layout is unknown, return nil.
        if (error) *error = @"FAILED_CODEC_LAYOUT_UNKNOWN";
        return nil;
    }];
```

## Intentionally unsupported without verified target semantics

- `ObscuredInt` / `SecureLong`: existing transform codecs are for mutation of *existing values* and **cannot** automatically construct correct encrypted input structs. The generic `op_Implicit` strategy may work if the **actual game version** exposes an appropriate conversion operator; otherwise supply a version-verified encoder. Don't synthesize fake hiddenValue/cryptoKey. This has not been tested on the user's target game.
- Managed object references, arrays/lists, `ref/out`, pointer types and complex generic combinations require a managed object creation / GC lifetime / by-ref output design. They cannot be made universal merely by expanding a C++ switch statement.
- Return-value decoding remains unchanged; this module only covers arguments.
- `/0` follows the existing M6.13.3 executor unchanged. `/1` now delegates custom value types to the same common marshaller; scalar and string conversion paths are unchanged.

## Gate before promotion

- Compile iOS arm64 sources with the correct SDK.
- Test existing primitive, string, Vector, quaternion, Color and enum Runtime Calls for no regression.
- Test exact-size custom value-type payload and reject wrong-size payload.
- Test `Player::AddGold(ObscuredInt, bool)` only after confirming ACTk struct layout and an actual constructor/conversion method in the target binary.
- Verify stable Native Hook on hardware, and only then consider promotion from this separate branch.

**Status:** experimental feature branch; NOT a new stable release, NOT verified on device.
