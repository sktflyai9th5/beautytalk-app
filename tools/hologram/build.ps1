<#
.SYNOPSIS
    스캔한 얼굴 메시를 앱에 넣을 홀로그램 루프(애니메이션 WebP)로 굽는다.

.DESCRIPTION
    Blender 로 검은 배경에 와이어프레임을 한 바퀴 렌더하고(render_hologram.py),
    빛 번짐과 알파를 입힌 뒤(glow.py), ffmpeg 으로 애니메이션 WebP 로 묶는다.

    WebP 로 뽑는 이유는 Flutter 의 Image 위젯이 알파가 있는 애니메이션 WebP 를
    플러그인 없이 그대로 재생하기 때문이다. 투명 배경 영상은 Android 쪽
    video_player 가 알파를 살려주지 않아서 쓸 수 없다.

.EXAMPLE
    # 촬영한 영상 폴더에서 통째로 굽기 (프레임 추출 -> 얼굴 격자 -> 렌더 -> WebP)
    .\build.ps1 -Videos "C:\Users\012\Downloads\3d 영상" -Name jimin

.EXAMPLE
    # 이미 뽑아둔 메시로 굽기
    .\build.ps1 -Mesh C:\scans\jimin.obj -Name jimin

.EXAMPLE
    # 메시 없이 자리 표시용(Suzanne)으로 굽기
    .\build.ps1
#>
[CmdletBinding()]
param(
    [string]$Videos,
    [string]$Mesh,
    [string]$Bounds,
    [string]$Name = "face_hologram",
    [int]$Frames = 96,
    [int]$Res = 512,
    [int]$Fps = 24,
    [int]$Faces = 1600,
    [string]$Color = "00E5FF",
    [double]$Thickness = 0.006,
    [double]$Dist = 4.2,
    [double]$Sweep = 0.0,
    [switch]$Dots,
    [double]$DotScale = 3.4,
    [string]$DotColor = "0B5E74",
    [switch]$NoShell,
    [int]$Quality = 78,
    [string]$Glow = "2,7,20",
    [double]$Gain = 1.35,
    [double]$AlphaFloor = 0.016,
    [int]$AlphaSteps = 16,
    # 밝은 배경에 얹을 홀로그램. 흰 바탕에 렌더해서 이 색 잉크로 뽑는다.
    [string]$Ink,
    # 사진을 입힌 아바타. 투명 배경으로 렌더하고 색을 그대로 남긴다.
    [string]$Texture,
    [double]$TextureWash = 0.0,
    [double]$LineSwell = 0.0,
    [switch]$LinesFront,
    [double]$LineAlpha = 1.0,
    [double]$LineHalo = 0.0,
    # 후광 색. 어두운 선에는 흰 후광, 흰 선에는 어두운 후광이다.
    [string]$HaloColor = "FFFFFF",
    [double]$ScanHalo = 0.0,
    [string]$ScanHaloColor = "FFFFFF",
    [string]$Zones = "",
    [switch]$FilmAlpha,
    # 실루엣 안쪽의 자잘한 구멍을 메운다 (머리카락 가닥 사이가 벌어진 자리).
    [int]$CloseHoles = 0,
    [switch]$Scan,
    [string]$ScanColor = "21C7EE",
    [double]$ScanThickness = 0.02,
    [double]$ScanSize = 2.4,
    [double]$ScanAlpha = 0.42,
    [string]$Background = "000000",
    [double]$Emit = 1.35,
    [string]$ShellTint = "E4F4FA",
    # 얼굴 껍데기의 열린 뒤쪽을 닫아 머리(아바타)로 만든다.
    [switch]$Head,
    [double]$HeadDepth = 1.05,
    [int]$HeadRings = 6,
    # 머리 전체를 두르는 옅은 격자 색. 비워 두면 렌더러 기본값을 쓴다.
    [string]$HeadWire = "",
    # 머리 격자를 이 면 수로 줄인 뒤에 두른다 (0 = 안 줄임).
    [int]$HeadWireFaces = 0,
    # 머리 격자를 표면에서 띄우는 높이 (얼굴 반지름 1 기준).
    [double]$HeadWireLift = 0.0,
    # 머리 격자를 복셀로 각지게 짓는다 (옥트리 깊이. 4=16칸, 5=32칸).
    [int]$HeadWireBlocks = 0,
    # 사진 색이 입혀진 실제 머리에는 격자를 두르지 않는다 (가발 망처럼 보인다).
    [switch]$NoHeadWire,
    # 실루엣으로 깎은 실제 머리 (carve.ps1 이 낸 head_fitted.ply).
    # 주면 뒤통수를 지어내지 않고 이걸 붙인다.
    [string]$HeadMesh = "",
    # 머리에 입힐 텍스처 (bake_head_texture.py). 주면 정점 색 대신 이걸 쓴다.
    [string]$HeadTexture = "",
    [int]$HeadFaces = 1400,
    [int]$HeadSmooth = 12,
    [double]$HighlightSpacing = 0.11,
    [int]$ContourStep = 2,
    [double]$DepthScale = 1.0,
    [double]$MeshSpacing = 0.058,
    [int]$SampleFps = 3,
    [string]$Venv = "C:\Users\012\.venvs\holoface",
    [string]$LandmarkModel = "C:\Users\012\.venvs\holoface\models\face_landmarker.task"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Resolve-Path (Join-Path $here "..\..")

function Find-Exe([string]$envVar, [string]$leaf, [string[]]$roots) {
    $fromEnv = [Environment]::GetEnvironmentVariable($envVar)
    if ($fromEnv -and (Test-Path $fromEnv)) { return $fromEnv }

    $onPath = Get-Command $leaf -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem $root -Recurse -Filter $leaf -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    throw "$leaf 를 못 찾았다. 환경변수 $envVar 에 경로를 넣거나 PATH 에 추가해라."
}

function Invoke-Native([string]$Exe, [string[]]$Arguments, [string]$Filter) {
    # Windows PowerShell 5.1 은 네이티브 exe 가 stderr 로 한 줄만 흘려도
    # ErrorRecord 로 감싸버려서, exit 0 으로 끝나도 ErrorActionPreference=Stop
    # 에 걸려 스크립트가 죽는다. 성패는 종료 코드로만 판단한다.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($Filter) {
            & $Exe @Arguments | Select-String -Pattern $Filter | ForEach-Object { $_.Line }
        }
        else {
            & $Exe @Arguments
        }
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

$blender = Find-Exe "BLENDER_EXE" "blender.exe" @("C:\Program Files\Blender Foundation")
$ffmpeg = Find-Exe "FFMPEG_EXE" "ffmpeg.exe" @("$env:LOCALAPPDATA\Microsoft\WinGet\Packages")
Write-Host "[build] blender : $blender"
Write-Host "[build] ffmpeg  : $ffmpeg"

$work = Join-Path $env:TEMP "holo_build_$Name"
$rawDir = Join-Path $work "raw"
$glowDir = Join-Path $work "glow"
$frameDir = Join-Path $work "frames"
foreach ($d in @($rawDir, $glowDir, $frameDir)) {
    if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# ---- 0. 영상에서 얼굴 격자 뽑기 (-Videos 를 준 경우)
if ($Videos) {
    if (-not (Test-Path -LiteralPath $Videos)) { throw "영상 폴더가 없다: $Videos" }
    $venvPython = Join-Path $Venv "Scripts\python.exe"
    if (-not (Test-Path $venvPython)) {
        throw "mediapipe venv 가 없다: $venvPython`n" +
              "python -m venv $Venv; & '$venvPython' -m pip install mediapipe pillow"
    }
    if (-not (Test-Path $LandmarkModel)) { throw "랜드마크 모델이 없다: $LandmarkModel" }

    Write-Host "[build] 0/3 영상에서 프레임 추출 (${SampleFps}fps)"
    $n = 1
    foreach ($clip in (Get-ChildItem -LiteralPath $Videos -Include *.mp4, *.mov, *.m4v -Recurse |
                       Sort-Object Name)) {
        Invoke-Native $ffmpeg @("-y", "-loglevel", "error", "-i", $clip.FullName,
                                "-vf", "fps=$SampleFps", "-q:v", "2",
                                (Join-Path $frameDir ("cam{0}_%03d.jpg" -f $n)))
        if ($LASTEXITCODE -ne 0) { throw "프레임 추출 실패: $($clip.Name)" }
        $n++
    }
    $shot = @(Get-ChildItem $frameDir -Filter *.jpg).Count
    if ($shot -eq 0) { throw "추출된 프레임이 없다: $Videos" }
    Write-Host "[build]     $shot 장 추출"

    Write-Host "[build] 0/3 얼굴 격자 추출"
    $Mesh = Join-Path $work "face_mesh.json"
    Invoke-Native $venvPython @((Join-Path $here "face_to_mesh.py"),
                                "--frames", $frameDir, "--model", $LandmarkModel,
                                "--out", $Mesh, "--depth-scale", $DepthScale,
                                "--mesh-spacing", $MeshSpacing,
                                "--highlight-spacing", $HighlightSpacing,
                                "--contour-step", $ContourStep) "^\[face\]"
    if ($LASTEXITCODE -ne 0) { throw "face_to_mesh.py 실패 (exit $LASTEXITCODE)" }

    # face_to_mesh.py 가 UV 와 같은 좌표계의 원본 프레임을 같이 남긴다.
    $auto = $Mesh -replace '\.json$', '_texture.jpg'
    if (-not $Texture -and (Test-Path $auto)) { $Texture = $auto }
}

# ---- 1. Blender 렌더 (검은 배경, 알파 없음)
$renderArgs = @(
    "--background", "--factory-startup",
    "--python", (Join-Path $here "render_hologram.py"), "--",
    "--out", $rawDir,
    "--frames", $Frames,
    "--res", $Res,
    "--faces", $Faces,
    "--color", $Color,
    "--thickness", $Thickness,
    "--dist", $Dist,
    "--sweep", $Sweep,
    "--bg", $Background,
    "--emit", $Emit,
    "--shell-tint", $ShellTint
)
if ($Mesh) {
    if (-not (Test-Path $Mesh)) { throw "메시가 없다: $Mesh" }
    $renderArgs += @("--mesh", (Resolve-Path $Mesh).Path)
}
if ($Bounds) {
    if (-not (Test-Path $Bounds)) { throw "bounds 파일이 없다: $Bounds" }
    $renderArgs += @("--bounds", (Resolve-Path $Bounds).Path)
}
if ($Dots) {
    $renderArgs += @("--dots", "--dot-scale", $DotScale, "--dot-color", $DotColor)
}
if ($NoShell) { $renderArgs += "--no-shell" }
if ($Texture) {
    if (-not (Test-Path $Texture)) { throw "텍스처가 없다: $Texture" }
    $renderArgs += @("--texture", (Resolve-Path $Texture).Path)
    if ($TextureWash -gt 0) { $renderArgs += @("--texture-wash", $TextureWash) }
}
# 선이 살에 묻히면 --line-swell 로 바깥으로 부풀린다 (카메라 쪽으로만 미는
# --line-lift 는 볼·턱처럼 표면이 옆을 향하는 데서 안 듣는다).
if ($LineSwell -gt 0) { $renderArgs += @("--line-swell", $LineSwell) }
if ($LinesFront) { $renderArgs += "--lines-front" }
if ($Zones) { $renderArgs += @("--zones", $Zones) }
if ($FilmAlpha) { $renderArgs += "--film-alpha" }
if ($Scan) {
    $renderArgs += @("--scan", "--scan-color", $ScanColor,
                     "--scan-thickness", $ScanThickness,
                     "--scan-size", $ScanSize, "--scan-alpha", $ScanAlpha)
    if ($ScanHalo -gt 0) {
        $renderArgs += @("--scan-halo", $ScanHalo,
                         "--scan-halo-color", $ScanHaloColor)
    }
}
if ($Head) {
    $renderArgs += @("--head", "--head-depth", $HeadDepth, "--head-rings", $HeadRings)
}
if ($HeadWire) { $renderArgs += @("--head-wire", $HeadWire) }
if ($NoHeadWire) { $renderArgs += "--no-head-wire" }
if ($HeadWireFaces -gt 0) {
    $renderArgs += @("--head-wire-faces", $HeadWireFaces)
}
if ($HeadWireLift -gt 0) {
    $renderArgs += @("--head-wire-lift", $HeadWireLift)
}
if ($HeadWireBlocks -gt 0) {
    $renderArgs += @("--head-wire-blocks", $HeadWireBlocks)
}
if ($HeadMesh) {
    if (-not (Test-Path $HeadMesh)) { throw "머리 메시가 없다: $HeadMesh" }
    $renderArgs += @("--head-mesh", (Resolve-Path $HeadMesh).Path,
                     "--head-faces", $HeadFaces, "--head-smooth", $HeadSmooth)
    if ($HeadTexture) {
        if (-not (Test-Path $HeadTexture)) { throw "머리 텍스처가 없다: $HeadTexture" }
        $renderArgs += @("--head-texture", (Resolve-Path $HeadTexture).Path)
    }
}

Write-Host "[build] 1/3 Blender 렌더 ($Frames 장, ${Res}px)"
Invoke-Native $blender $renderArgs "^\[holo\]"
if ($LASTEXITCODE -ne 0) { throw "Blender 렌더 실패 (exit $LASTEXITCODE)" }

if ($LinesFront) {
    # 선 레이어를 얼굴 위에 얹고 lines_*.png 를 지운다. 장수 검사보다 먼저
    # 해야 한다 — 안 그러면 두 배로 세어져서 걸린다.
    $composeArgs = @((Join-Path $PSScriptRoot "compose.py"), $rawDir)
    if ($LineAlpha -lt 1.0) { $composeArgs += @("--line-alpha", $LineAlpha) }
    if ($LineHalo -gt 0) {
        $composeArgs += @("--line-halo", $LineHalo, "--halo-color", $HaloColor)
    }
    Invoke-Native "python" $composeArgs "^\[compose\]"
    if ($LASTEXITCODE -ne 0) { throw "선 겹치기 실패 (exit $LASTEXITCODE)" }
}

$rendered = @(Get-ChildItem $rawDir -Filter *.png)
if ($rendered.Count -ne $Frames) { throw "렌더된 장수가 안 맞는다: $($rendered.Count) / $Frames" }

# ---- 2. 빛 번짐 + 알파
Write-Host "[build] 2/3 글로우 + 알파"
$glowArgs = @((Join-Path $here "glow.py"), "--src", $rawDir, "--out", $glowDir,
              "--radii", $Glow, "--gain", $Gain, "--alpha-floor", $AlphaFloor,
              "--alpha-steps", $AlphaSteps)
if ($Ink) { $glowArgs += @("--ink", $Ink) }
if ($FilmAlpha) { $glowArgs += "--keep-color" }
if ($CloseHoles -gt 0) { $glowArgs += @("--close-holes", $CloseHoles) }
Invoke-Native "python" $glowArgs
if ($LASTEXITCODE -ne 0) { throw "glow.py 실패 (exit $LASTEXITCODE)" }

# ---- 3. 애니메이션 WebP 로 묶기
$assetDir = Join-Path $repo "assets\hologram"
New-Item -ItemType Directory -Force -Path $assetDir | Out-Null
$target = Join-Path $assetDir "$Name.webp"

Write-Host "[build] 3/3 WebP 인코딩 ($Fps fps)"
Invoke-Native $ffmpeg @(
    "-y", "-loglevel", "error",
    "-framerate", $Fps, "-i", (Join-Path $glowDir "frame_%04d.png"),
    "-c:v", "libwebp_anim", "-pix_fmt", "yuva420p", "-lossless", "0",
    "-quality", $Quality, "-loop", "0", "-an", $target
)
if ($LASTEXITCODE -ne 0) { throw "ffmpeg 인코딩 실패 (exit $LASTEXITCODE)" }

# ---- 4. 첫 프레임이 화면에서 차지하는 영역 재기
# 사진 위 격자가 그대로 떠오르는 것처럼 보이려면 앱이 이 값으로 자리를 맞춰야 한다.
Write-Host "[build] 4/4 정면 프레임 위치 재기"
Invoke-Native "python" @((Join-Path $here "measure_hologram.py"),
                         "--frames", $glowDir,
                         "--align", (Join-Path $work "align.png"),
                         "--out", (Join-Path $assetDir "$Name.json")) "^\[measure\]"
if ($LASTEXITCODE -ne 0) { throw "measure_hologram.py 실패 (exit $LASTEXITCODE)" }

# 부위별 프레임 위치. 얼굴이 돌면 짚는 점도 같이 돌아야 한다.
$zoneSrc = Join-Path $work "zones.json"
if (Test-Path $zoneSrc) {
    Copy-Item $zoneSrc (Join-Path $assetDir "${Name}_zones.json") -Force
    Write-Host "[build]     부위 위치 -> ${Name}_zones.json"
}

$kb = [math]::Round((Get-Item $target).Length / 1KB, 1)
$seconds = [math]::Round($Frames / $Fps, 2)
Write-Host ""
Write-Host "[build] 완료 -> $target"
Write-Host "[build] $Frames 장 / $Fps fps = ${seconds}초 루프 / ${kb} KB"
Write-Host "[build] pubspec.yaml 의 assets 에 'assets/hologram/' 이 있는지 확인해라."
