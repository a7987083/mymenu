# v0.5.8 M2.2 Builder / Feature Control / Search UX

Work scope before any later runtime-hook milestone:

1. Add safe authoring deletion for an individual Patch and a whole Feature.
2. Introduce a generic Feature Control V2 model so features are not hardcoded by name. Existing features default to Toggle; Number and Action metadata are first-class authoring/runtime control descriptors. The example configurations are Damage Multiplier (Number), Defence Multiplier (Number), God Mode (Toggle), Debug Menu (Action).
3. Replace M2.1 post-render Search->Cancel rewriting with stable search state so progress updates do not cause the primary button to flicker.

Do not change the M1/V2 IL2CPP resolution contract or Named Offset exact semantics while implementing this scope.
