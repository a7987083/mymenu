# IL2CPP Named Offset Resolver v1

Status: device-validation candidate

Base: v0.5.6.2 sealed baseline

## Goal

Allow the Patch Builder Offset field to use an IL2CPP method expression instead of a fixed numeric RVA while preserving the existing validated-RVA -> Static Builder V3 -> Static Dispatch architecture.

Example authoring row:

```text
Offset: GetMoney
Patch:  700d80d2c0035fd6
```

A symbolic row is resolved only when the developer explicitly taps `读取验证`. It is automatically routed to `UnityFramework`, converted internally to a numeric RVA, then passed through the existing Runtime Validator. The authoring text remains visible after validation; the attached validator retains the resolved numeric RVA used by temporary apply and build.

## Accepted expressions

```text
GetMoney
GetMoney/0
PlayerData::GetMoney/0
Game.PlayerData::GetMoney/0
Assembly-CSharp.dll!Game.PlayerData::GetMoney/0+0x10
Assembly-CSharp!PlayerData::GetMoney/0-0x10
```

`/N` is the IL2CPP argument count. `+/-delta` is applied after resolving the native method entry and is useful when the patch site is inside the method instead of exactly at its entry.

## Resolution rules

1. Numeric Offset input remains unchanged and uses the legacy RVA path.
2. Symbolic Offset input uses the loaded IL2CPP runtime in `UnityFramework`.
3. Simple/unqualified names are accepted only when the runtime enumeration APIs are available.
4. The resolver never chooses the first same-named method silently. More than one matching method is reported as ambiguous and requires a more-qualified expression.
5. A method code pointer is accepted only if it resolves into an executable `UnityFramework` Mach-O segment.
6. Preferred pointer source is `il2cpp_method_get_pointer` when exported. A compatibility fallback checks the first MethodInfo pointer words but accepts them only after the executable-segment range check.
7. Resolved RVA must remain 4-byte ARM64 aligned.
8. Existing Runtime Validator still captures the live Original bytes from the original process and performs executable segment checks before a row becomes validated.
9. Generated Mach-O files contain the final numeric RVA. Named resolution is an authoring-time aid, not a new runtime dependency.

## Lifecycle invariant

The Named Offset integration has no constructor and no Objective-C `+load`. It is installed by the existing full-deferred bootstrap only after the first ZN launcher click. Before that click, no IL2CPP named lookup or method enumeration is performed.

## Failure / fallback behavior

- `AMBIGUOUS`: qualify with `Class::Method/N` or `Assembly!Namespace.Class::Method/N`.
- Enumeration API missing: use a fully-qualified expression if core class/method APIs remain available.
- Method pointer unavailable: MethodInfo compatibility fallback is attempted with executable-segment validation.
- Runtime IL2CPP API hidden/incomplete: numeric RVA remains fully supported. A future metadata-backed stage may use `global-metadata.dat + UnityFramework`, but that is intentionally outside v1.

## Device acceptance

At minimum verify on an original, unmodified IL2CPP app:

1. First ZN activation remains as fast as v0.5.6.2 and does not create the removed persistent activation log.
2. Add a row with `Offset=GetMoney` and a known-safe test Patch, then tap `读取验证`.
3. Confirm unique resolution reports the canonical method and a numeric UnityFramework RVA, or that ambiguity is rejected with candidates instead of picking one silently.
4. When a known numeric RVA for the same method exists, compare it against the resolved RVA (plus any declared delta).
5. Verify temporary apply/restore and generated-binary build still use the validated numeric RVA.
