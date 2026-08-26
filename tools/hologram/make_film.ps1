<#
.SYNOPSIS
    분석 연출을 소리까지 입힌 mp4 로 뽑는다.

.DESCRIPTION
    위젯을 프레임 단위로 그려(hologram_scan_film_test.dart) 소리를 타임라인에
    맞춰 섞고(make_soundtrack.py) ffmpeg 으로 묶는다.

    안드로이드 기기가 없을 때 완성된 연출을 확인하는 가장 빠른 방법이다.
    실제로 돌려 보려면 `flutter run -d chrome -t lib/preview_main.dart` 를 쓴다.

.EXAMPLE
    .\tools\hologram\make_film.ps1
#>
[CmdletBinding()]
param(
    [int]$Fps = 24,
    [string]$Out = "build\scan_demo.mp4"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Resolve-Path (Join-Path $here "..\..")
Set-Location $repo

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    # 네이티브 exe 의 stderr 는 PowerShell 5.1 에서 ErrorRecord 로 감싸여
    # exit 0 이어도 ErrorActionPreference=Stop 에 걸린다. 종료 코드로만 본다.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $Exe @Arguments } finally { $ErrorActionPreference = $prev }
}

$ffmpeg = $env:FFMPEG_EXE
if (-not $ffmpeg -or -not (Test-Path $ffmpeg)) {
    $onPath = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($onPath) {
        $ffmpeg = $onPath.Source
    }
    else {
        $hit = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse `
            -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $hit) { throw "ffmpeg 을 못 찾았다. FFMPEG_EXE 를 지정해라." }
        $ffmpeg = $hit.FullName
    }
}

Write-Host "[film] 1/3 위젯을 프레임으로 그리는 중"
Invoke-Native "flutter" @("test", "test\hologram_scan_film_test.dart")
if ($LASTEXITCODE -ne 0) { throw "프레임 렌더 실패 (exit $LASTEXITCODE)" }

$frames = @(Get-ChildItem "build\scan_film" -Filter *.png -ErrorAction SilentlyContinue)
if ($frames.Count -eq 0) { throw "렌더된 프레임이 없다" }
Write-Host "[film]     $($frames.Count) 장"

# 소리 길이는 **뽑힌 장수에서 나온다.** 따로 적어 두면 연출 길이를 바꿀 때마다
# 어긋난다 — 실제로 연출을 줄인 뒤에도 소리만 11초로 남아서 완료음이 영상
# 밖으로 밀려나 있었다.
$Seconds = [math]::Round($frames.Count / $Fps, 3)

Write-Host "[film] 2/3 소리 섞는 중"
Invoke-Native "python" @((Join-Path $here "make_soundtrack.py"),
                         "--out", "build\scan_track.wav", "--seconds", $Seconds)
if ($LASTEXITCODE -ne 0) { throw "사운드트랙 생성 실패 (exit $LASTEXITCODE)" }

Write-Host "[film] 3/3 mp4 로 묶는 중"
# 393px 은 홀수라 H.264 가 못 받는다. 짝수로 맞춘다.
Invoke-Native $ffmpeg @(
    "-y", "-loglevel", "error",
    "-framerate", $Fps, "-i", "build\scan_film\f_%04d.png",
    "-i", "build\scan_track.wav",
    "-vf", "scale=392:-2:flags=lanczos",
    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-preset", "slow",
    "-c:a", "aac", "-b:a", "128k", "-shortest", $Out
)
if ($LASTEXITCODE -ne 0) { throw "ffmpeg 실패 (exit $LASTEXITCODE)" }

$kb = [math]::Round((Get-Item $Out).Length / 1KB, 0)
Write-Host ""
Write-Host "[film] 완료 -> $Out  (${kb} KB)"
