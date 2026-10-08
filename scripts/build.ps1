param(
    [string]$DevEcoHome = 'D:\HUAWEI\DevEco Studio',
    [ValidateSet('default', 'ohosTest')]
    [string]$Target = 'default'
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskNode = Join-Path $DevEcoHome 'tools\node\node.exe'
$taskHvigor = Join-Path $DevEcoHome 'tools\hvigor\bin\hvigorw.js'
if (!(Test-Path -LiteralPath $taskNode) -or !(Test-Path -LiteralPath $taskHvigor)) {
    throw 'DevEco Studio node or Hvigor was not found. Set -DevEcoHome to your installation path.'
}
$taskOldPath = $env:Path
$taskOldSdk = $env:DEVECO_SDK_HOME
$taskOldJava = $env:JAVA_HOME
try {
    $env:DEVECO_SDK_HOME = Join-Path $DevEcoHome 'sdk'
    $env:JAVA_HOME = Join-Path $DevEcoHome 'jbr'
    $env:Path = (Join-Path $DevEcoHome 'tools\node') + ';' + (Join-Path $DevEcoHome 'tools\ohpm\bin') + ';' + $taskOldPath
    Push-Location -LiteralPath $taskRoot
    try {
        & $taskNode $taskHvigor --mode module -p product=default -p "module=entry@$Target" -p buildMode=debug assembleHap --no-daemon
        if ($LASTEXITCODE -ne 0) { throw "Hvigor build failed (exit $LASTEXITCODE)." }
    } finally {
        Pop-Location
    }
} finally {
    $env:Path = $taskOldPath
    $env:DEVECO_SDK_HOME = $taskOldSdk
    $env:JAVA_HOME = $taskOldJava
}
