# TYPopup iOS Module

Minimal Objective-C popup bridge for injected iOS environments.

API:

```c
TY_ShowPopup("title", "message");
```

Design goals:

- Objective-C only
- no third party dependencies
- C callable interface
- Unity / dylib friendly
- main thread UIKit dispatch
