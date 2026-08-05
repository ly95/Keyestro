# Keyestro extension examples

Both examples implement the same v1 JSON-RPC contract over LSP-style `Content-Length` frames.
They intentionally request no capabilities and use explicit search, so query text is sent only
after the user opens the example command in `@` mode.

Run the contract harness from the repository root:

```sh
swift run launcher-extension-test validate Examples/Extensions/PythonExample.extension
swift run launcher-extension-test run Examples/Extensions/PythonExample.extension --query repo
swift run launcher-extension-test fuzz-framing Examples/Extensions/PythonExample.extension

scripts/test-extension-examples.sh
```

Native extensions run with the current user's permissions. Process isolation is not an OS
sandbox; install only trusted local code. Protocol bytes belong on stdout and logs belong on
stderr.

The Swift example is compiled first and assembled into a temporary `.extension` directory by
the test script. This keeps generated Mach-O binaries out of source control while ensuring its
`initialize` response meets the host's strict two-second deadline.
