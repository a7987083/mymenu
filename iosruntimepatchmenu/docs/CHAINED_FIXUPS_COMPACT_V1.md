# Compact chained-starts growth V1

Baseline: `fcfbc4c2ea677cc497e07de005f92bdca3e0fd7d` on `feat/method-finder-p5-detail-copy`.

The Static V3 and Runtime-only builders now preflight their disposable output copy before the existing segment insertion path. If the starts offset array lacks zero slots, insert 16 bytes at the end of the old array, preserve every original suffix byte, update relative record/import/symbol offsets, the fixups datasize, supported absolute LINKEDIT references and the LINKEDIT file/VM sizes. Then let the existing guarded relocation consume one/two zero slots. A padded image keeps its original size. Original TEXT/data VM addresses, patch ABI and existing signing pipeline are unchanged.

The first version only grows a terminal, sectionless LINKEDIT with supported load commands and a zero original LINKEDIT starts entry. Unknown commands, overlapping ranges, malformed tables and unsupported section relocation layouts fail closed. Existing load-command header-slack and branch-range requirements remain in force. Final signing/device loading remain separate acceptance gates.

The existing CI test now includes 4- and 5-segment fixtures, 4- and 0-byte starts slack, 2-byte records/imports gap, one/two inserted segments, padded/no-growth path, payload/offset preservation, overlap rejection, insufficient capacity atomicity and the actual disposable-file adapter. CI and device results must be recorded from real runs; no device validation is claimed here.
