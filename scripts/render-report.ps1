param(
  [Parameter(Mandatory = $true)][string]$InputPath,
  [string]$OutputDirectory,
  [string]$RuntimeRoot = (Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies'),
  [string]$DocumentSkillRoot = (Join-Path $env:USERPROFILE '.codex/plugins/cache/openai-primary-runtime/documents/26.1007.11041/skills/documents'),
  [ValidateRange(72, 300)][int]$Dpi = 150
)
$ErrorActionPreference = 'Stop'
$sourcePath = (Resolve-Path -LiteralPath $InputPath).Path
if ([IO.Path]::GetExtension($sourcePath) -ne '.docx') { throw 'InputPath must point to a DOCX file.' }
$projectDirectory = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) {
  $runTag = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  $OutputDirectory = Join-Path $projectDirectory ".qa/report-render-$runTag"
}
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputPath) {
  if (@(Get-ChildItem -LiteralPath $outputPath -Force).Count -gt 0) {
    throw 'Use an empty output directory so stale pages cannot be mistaken for this render.'
  }
} else {
  New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
}
$pythonPath = Join-Path $RuntimeRoot 'python/python.exe'
$popplerPath = Join-Path $RuntimeRoot 'native/poppler/Library/bin'
$rendererPath = Join-Path $DocumentSkillRoot 'render_docx.py'
foreach ($requiredPath in @($pythonPath, $rendererPath, (Join-Path $popplerPath 'pdftoppm.exe'))) {
  if (-not (Test-Path -LiteralPath $requiredPath)) { throw "Missing bundled dependency: $requiredPath" }
}
$sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
$canonicalLog = Join-Path $outputPath 'canonical-render.log'
$previousPath = $env:PATH
try {
  # Never discover or launch an installed user LibreOffice through the inherited PATH.
  $env:PATH = ($popplerPath, (Join-Path $RuntimeRoot 'bin/override'), "$env:WINDIR/System32", $env:WINDIR) -join ';'
  & $pythonPath $rendererPath $sourcePath --output_dir $outputPath --emit_pdf --verbose *> $canonicalLog
  $canonicalCode = $LASTEXITCODE
} finally {
  $env:PATH = $previousPath
}
$pdfPath = Join-Path $outputPath ([IO.Path]::GetFileNameWithoutExtension($sourcePath) + '.pdf')
$engine = 'packaged-render_docx'
if ($canonicalCode -ne 0) {
  $diagnostic = Get-Content -LiteralPath $canonicalLog -Raw
  if ($diagnostic -notmatch 'LibreOffice soffice.exe was not found on PATH') {
    throw "Packaged renderer failed for a reason other than absent LibreOffice. See $canonicalLog"
  }
  $engine = 'isolated-Microsoft-Word-COM'
  if (-not ('CodexMusic.RenderNativeMethods' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace CodexMusic {
  public static class RenderNativeMethods {
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  }
}
"@
  }
  $existingWordIds = @(Get-Process -Name WINWORD -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
  $wordApplication = $null
  $documents = $null
  $document = $null
  $documentWindow = $null
  $documentFields = $null
  $wordOptions = $null
  $ownedStartTicks = 0
  $ownsInstance = $false
  $wordProcessId = [uint32]0
  try {
    # CoCreateInstance creates a new automation instance; do not attach via GetActiveObject.
    $wordApplication = New-Object -ComObject Word.Application
    $documents = $wordApplication.Documents
    $newWordProcesses = @(Get-Process -Name WINWORD -ErrorAction SilentlyContinue | Where-Object { $existingWordIds -notcontains $_.Id })
    if ($newWordProcesses.Count -ne 1 -or $documents.Count -ne 0) {
      throw 'Word did not create an empty, separate process. Aborted without changing or closing that instance.'
    }
    $wordProcessId = [uint32]$newWordProcesses[0].Id
    $ownedStartTicks = $newWordProcesses[0].StartTime.ToUniversalTime().Ticks
    $ownsInstance = $true
    $wordApplication.Visible = $false
    $wordApplication.DisplayAlerts = 0
    $wordApplication.AutomationSecurity = 3
    $wordOptions = $wordApplication.Options
    $wordOptions.SaveNormalPrompt = $false
    # FileName, ConfirmConversions, ReadOnly, AddToRecentFiles.
    $document = $documents.Open($sourcePath, $false, $true, $false)
    $windowProcessId = [uint32]0
    $documentWindow = $document.ActiveWindow
    [void][CodexMusic.RenderNativeMethods]::GetWindowThreadProcessId([IntPtr]$documentWindow.Hwnd, [ref]$windowProcessId)
    if ($windowProcessId -ne $wordProcessId) { throw 'The opened Word window is not in the newly created process.' }
    $document.Repaginate()
    $documentFields = $document.Fields
    [void]$documentFields.Update()
    $document.ExportAsFixedFormat($pdfPath, 17, $false, 0, 0)
    [ordered]@{
      engine = $engine
      source = $sourcePath
      private_word_pid = $wordProcessId
      existing_word_pids = $existingWordIds
      opened_read_only = $true
      altered_user_documents = $false
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outputPath 'word-export.json') -Encoding utf8
  } finally {
    if ($documentFields) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($documentFields) }
    if ($documentWindow) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($documentWindow) }
    if ($document) {
      try { $document.Close(0) } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($document) }
    }
    $remainingDocuments = if ($documents) { $documents.Count } else { -1 }
    if ($documents) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($documents) }
    if ($wordOptions) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($wordOptions) }
    if ($wordApplication) {
      if ($ownsInstance -and $remainingDocuments -eq 0) { $wordApplication.Quit(0) }
      [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($wordApplication)
    }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    # Some Office builds retain an empty automation process after Quit. Clean up
    # only the recorded, newly created process, after the only opened document closed.
    if ($ownsInstance -and $remainingDocuments -eq 0) {
      $ownedProcess = Get-Process -Id $wordProcessId -ErrorAction SilentlyContinue
      if ($ownedProcess -and -not $ownedProcess.WaitForExit(5000)) {
        $ownedProcess.Refresh()
        if ($ownedProcess.StartTime.ToUniversalTime().Ticks -eq $ownedStartTicks -and
            $ownedProcess.MainWindowHandle -eq 0 -and [string]::IsNullOrEmpty($ownedProcess.MainWindowTitle)) {
          Stop-Process -Id $wordProcessId
        }
      }
    }
  }
}
if (-not (Test-Path -LiteralPath $pdfPath) -or (Get-Item -LiteralPath $pdfPath).Length -eq 0) {
  throw 'Export produced no PDF.'
}
if ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne $sourceHash) {
  throw 'Source DOCX changed during rendering; it must be reviewed before delivery.'
}
& $pythonPath (Join-Path $PSScriptRoot 'render-report.py') $pdfPath --output-dir $outputPath --poppler-bin $popplerPath --dpi $Dpi --engine $engine --source-docx $sourcePath --source-sha256 $sourceHash
if ($LASTEXITCODE -ne 0) { throw 'Bundled Poppler rasterization failed.' }
Write-Output "Render manifest: $(Join-Path $outputPath 'render-manifest.json')"
Write-Output 'Rendering success does not replace opening and visually inspecting every page PNG.'


