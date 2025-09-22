# Export-RollLogger.ps1
# Converts RollLogger SavedVariables csvLines -> a real Rolls.csv in the addon folder.

param(
  [string]$WowRoot = "C:\Games\TurtleWoW",  # <-- adjust if needed
  [string]$Account = "*"                    # use * to match your account folder
)

$svFile = Get-ChildItem -Path (Join-Path $WowRoot "WTF\Account\$Account\SavedVariables") -Filter "RollLogger.lua" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $svFile) {
  Write-Error "Could not find SavedVariables\RollLogger.lua. Check -WowRoot or log in once with the addon enabled."
  exit 1
}

# Read file and pull lines between 'csvLines = {' and the matching closing brace at the same indent
$content = Get-Content -Raw -Path $svFile.FullName

# Match the csvLines table block
$csvBlock = [regex]::Match($content, "csvLines%s*=%s*%{(?<body>.*?)%}", "Singleline").Groups["body"].Value
if (-not $csvBlock) {
  Write-Error "csvLines not found. In game, run /rolllog export, then /reload, and try again."
  exit 1
}

# Extract quoted strings -> CSV rows
$rows = [System.Collections.Generic.List[string]]::new()
$matches = [regex]::Matches($csvBlock, '"((?:[^"\\]|\\.)*)"')
foreach ($m in $matches) {
  $s = $m.Groups[1].Value
  # Unescape "" -> "
  $s = $s -replace '""','"'
  $rows.Add($s)
}

if ($rows.Count -eq 0) {
  Write-Error "Found csvLines but no rows."
  exit 1
}

$csvOut = Join-Path $WowRoot "Interface\AddOns\RollLogger\Rolls.csv"
$new = $true
if (Test-Path $csvOut) {
  # Overwrite each time for simplicity
  Remove-Item $csvOut -Force
}

$rows | Set-Content -Path $csvOut -Encoding UTF8
Write-Host "Wrote $($rows.Count) lines to $csvOut"
