# Extension artifacts

Each `*.scm` file in this directory is a named, persistent live patch. The
harness never auto-loads artifacts. Use `/extension-load NAME` to apply one as a
new validated generation and `/extension-disable NAME` to remove that exact
patch.

Artifacts use the same restricted top-level contract as `live_eval`: `define`,
`define*`, `set!`, or `begin`, targeting only `agent-*` or `extension-*`
bindings. Existing artifact files are never overwritten.
