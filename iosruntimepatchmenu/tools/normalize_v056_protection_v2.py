from pathlib import Path

p = Path('iosruntimepatchmenu/src/ZNStaticBinaryBuilderV3.mm')
s = p.read_text()

notes = [
    '@"Protection V2 stores each relocated source instruction in an independently shuffled 16-byte fragment slot",',
    '@"Protection V2 varies thunk live length and entry placement per generated output; it is a static-analysis cost layer, not cryptographic secrecy",',
    '@"Original patch sites remain one direct ARM64 B where the validated overwrite window is one instruction; V2 does not claim to hide this architectural requirement",',
]

lines = s.splitlines()
out = []
seen = {note: False for note in notes}
for line in lines:
    stripped = line.strip()
    matched = next((note for note in notes if stripped == note), None)
    if matched is not None:
        if seen[matched]:
            continue
        seen[matched] = True
    out.append(line)

missing = [note for note, present in seen.items() if not present]
if missing:
    raise SystemExit('missing Protection V2 report note(s): ' + ', '.join(missing))

p.write_text('\n'.join(out) + ('\n' if s.endswith('\n') else ''))
print('v0.5.6 Protection V2 normalization complete')
