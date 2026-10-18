# Runs the portable Swift test suites, builds the C ABI DLL and runs the C#
# interop smoke test. Requires the Swift for Windows toolchain and the .NET SDK.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

foreach ($package in 'DrillTiming', 'DrillCore', 'DrillDocument', 'DrillBridge') {
    Write-Host "== swift test: $package"
    swift test --package-path "$root/packages/$package"
    if ($LASTEXITCODE -ne 0) { throw "swift test failed for $package" }
}

Write-Host '== swift build FieldworkCore.dll (release)'
swift build -c release --product FieldworkCore --package-path "$root/packages/DrillBridge"
if ($LASTEXITCODE -ne 0) { throw 'FieldworkCore build failed' }

Write-Host '== C# interop smoke test'
dotnet run -c Release --project "$root/apps/windows/BridgeSmoke/BridgeSmoke.csproj"
if ($LASTEXITCODE -ne 0) { throw 'Interop smoke test failed' }

Write-Host 'Portable core and C ABI verified.'
