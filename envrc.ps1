$ZigVersion = "0.16.0"
$ZigPlatform = "x86_64-windows"
$ZigDist = "zig-$ZigPlatform-$ZigVersion"

$BaseDir = Resolve-Path "."
$ZigDir = Join-Path $BaseDir ".direnv\$ZigDist"
$ZigZipPath = Join-Path $BaseDir ".direnv\$ZigDist.zip"

if (-not (Test-Path $ZigDir))
{
  New-Item -ItemType Directory -Path "$BaseDir\.direnv" -Force | Out-Null
  $ZigUrl = "https://ziglang.org/download/$ZigVersion/$ZigDist.zip"
  if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
    & curl.exe -L --fail --progress-bar --ssl-no-revoke --output $ZigZipPath $ZigUrl
    if ($LASTEXITCODE -ne 0) {
        Invoke-WebRequest $ZigUrl -OutFile $ZigZipPath
    }
  } else {
      Invoke-WebRequest $ZigUrl -OutFile $ZigZipPath
  }

  if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
    & tar.exe -xf $ZigZipPath -C "$BaseDir\.direnv"
    if ($LASTEXITCODE -ne 0) {
        Expand-Archive $ZigZipPath -DestinationPath "$BaseDir\.direnv" -Force
    }
  } else {
    Expand-Archive $ZigZipPath -DestinationPath "$BaseDir\.direnv" -Force
  }

  Remove-Item $ZigZipPath
}

$env:PATH = "$ZigDir;$env:PATH"
