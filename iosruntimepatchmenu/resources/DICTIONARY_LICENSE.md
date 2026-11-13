# P4 Method Finder offline dictionary — provenance and licensing

- Curated English→Chinese vocabulary: `resources/MethodTranslation.zh-CN.json` (exactly 3,000 unique keys).
- The general-vocabulary entries were filtered from `imfiiish/wordlists`, specifically `data/en/definitions.json`, an ECDICT-derived MIT-licensed dataset; game/Unity/IL2CPP meanings and whole-method aliases were manually overridden for this integration.
- Sources:
  - https://github.com/imfiiish/wordlists
  - https://github.com/skywind3000/ECDICT
- Both upstream sources declare MIT licensing. The source definition list is not included in the client dylib.
- Generated developer-only C++ dictionary: `src/ZNMethodDictionary.generated.h`; regenerate with `python3 scripts/generate_dictionary.py`.
- Method names are only interpreted as naming hints. This dictionary does not verify runtime method behavior and may be inaccurate for unknown games.
- Customer build (`customer/Makefile`) intentionally does not compile translator/word data.

## MIT License — imfiiish/wordlists

Copyright (c) 2026 imfiiish

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## MIT License — skywind3000/ECDICT

Copyright (c) 2025 Linwei

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
