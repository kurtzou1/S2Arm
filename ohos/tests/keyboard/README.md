# OHOS foreground keyboard managed regression

This CPU test compiles the production `OhosKeyboard.cs`, `OhosHostUi.cs`, the
upstream keyboard argument/enum, and the actual `IHostUIHandler` interface. Only
unrelated UI parameter types and the native broker boundary are replaced. No
NuGet packages, native compiler, AOT build, game data, or device are required.

Run with the existing .NET 10 SDK and Python, choosing a new output directory:

```powershell
python ohos/tests/keyboard/run.py --dotnet "<dotnet>" --output "<output>"
```

The runner records exact commands, exit codes, stdout/stderr, input/output SHA-256,
and verifies the tested source bytes remain unchanged. It writes build outputs
only beneath the supplied output path. Its NuGet source list is empty.

Coverage includes Unicode/emoji with UTF-16 lengths, real cancel (`false` plus
`null`, including a positive minimum), modes 0/3, Numeric `[0-9.]*`, printable
ASCII, unsupported modes, request/reply limits, strict JSON types and duplicate
keys, invalid UTF-8/surrogates, one bounded RANGE retry including the final NUL,
bounded polling and the total deadline, transport errors, mandatory cleanup,
cleanup failure after a reply, and fatal reporting without input contents.

Passing validates managed codec and control flow against a fake broker. It does
not validate the OHOS C ABI, the native broker, ArkTS text entry, foreground and
background lifecycle, NativeAOT, or a game. Those need integrated OHOS tests.
