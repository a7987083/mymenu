# Legacy Build Route

M6.8.4 isolates the historical Static-first build route here for rollback and audit.

The active user build path is:

`ZNBuildManifest -> ZNBuildExecutor -> base emitter -> active provider emitters -> postprocess`

The legacy `ZNStaticBinaryBuilder + M585/M591 swizzle + pipeline` route is retained as source reference and must not be used as the UI build entry point.
