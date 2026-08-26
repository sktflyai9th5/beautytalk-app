<#
.SYNOPSIS
    한 바퀴 도는 영상 하나로 얼굴을 사진측량 복원해서 홀로그램용 메시를 만든다.

.DESCRIPTION
    COLMAP 으로 카메라 위치를 풀고(sparse) 조밀 복원(dense)한 뒤, 머리 주변만
    잘라 메시로 만든다. 결과는 render_hologram.py 에 --mesh 와 --bounds 로 넘긴다.

    **영상 하나만 쓴다.** 여러 번 나눠 찍은 영상은 그 사이 고개 각도와 표정이
    달라져서 하나로 합쳐지지 않는다. 한 번에 한 바퀴를 돈 영상이어야 한다.

.EXAMPLE
    .\tools\hologram\photogrammetry.ps1 -Video "C:\Users\012\Downloads\3d 영상\KakaoTalk_20260825_144004617.mp4"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Video,
    [string]$Work = "$env:LOCALAPPDATA\holo_photogrammetry",
    [int]$Fps = 8,
    [int]$FeatureSize = 1600,
    [int]$DenseSize = 1000,
    [double]$RadiusScale = 0.42,
    [int]$PoissonTrim = 10,
    [string]$Colmap = "$env:LOCALAPPDATA\colmap\bin\colmap.exe",
    [string]$Venv = "C:\Users\012\.venvs\holoface",
    [switch]$SkipExtract
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Invoke-Native([string]$Exe, [string[]]$Arguments, [string]$Filter) {
    # Windows PowerShell 5.1 은 네이티브 exe 의 stderr 를 ErrorRecord 로 감싸서
    # exit 0 이어도 ErrorActionPreference=Stop 에 걸린다. 종료 코드로만 본다.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($Filter) { & $Exe @Arguments | Select-String -Pattern $Filter | ForEach-Object { $_.Line } }
        else { & $Exe @Arguments | Out-Null }
    }
    finally { $ErrorActionPreference = $prev }
}

if (-not (Test-Path $Colmap)) {
    throw "COLMAP 이 없다: $Colmap`n" +
    "https://github.com/colmap/colmap/releases 에서 colmap-x64-windows-cuda.zip 을 받아 풀어라."
}
$venvPython = Join-Path $Venv "Scripts\python.exe"
if (-not (Test-Path $venvPython)) { throw "mediapipe venv 가 없다: $venvPython" }

$images = Join-Path $Work "images"

# ---- 1. 프레임 추출
if (-not $SkipExtract) {
    $ffmpeg = (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue).Source
    if (-not $ffmpeg) {
        $ffmpeg = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse `
                -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    }
    if (-not $ffmpeg) { throw "ffmpeg 을 못 찾았다" }

    if (Test-Path $images) { Remove-Item $images -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $images | Out-Null
    Write-Host "[pg] 1/6 프레임 추출 (${Fps}fps)"
    Invoke-Native $ffmpeg @("-y", "-loglevel", "error", "-i", $Video,
        "-vf", "fps=$Fps", "-q:v", "2", (Join-Path $images "f_%03d.jpg"))
    Write-Host "[pg]     $((Get-ChildItem $images -Filter *.jpg).Count) 장"
}

# ---- 2. 특징점 + 매칭 + 카메라 위치
$db = Join-Path $Work "db.db"
$sparse = Join-Path $Work "sparse"
Write-Host "[pg] 2/6 특징점과 카메라 위치 (COLMAP sparse)"
Remove-Item $db -Force -ErrorAction SilentlyContinue
Remove-Item $sparse -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $sparse | Out-Null

Invoke-Native $Colmap @("feature_extractor", "--database_path", $db, "--image_path", $images,
    "--ImageReader.single_camera", "1", "--ImageReader.camera_model", "SIMPLE_RADIAL",
    "--FeatureExtraction.max_image_size", $FeatureSize)
if ($LASTEXITCODE -ne 0) { throw "feature_extractor 실패" }

Invoke-Native $Colmap @("exhaustive_matcher", "--database_path", $db)
if ($LASTEXITCODE -ne 0) { throw "exhaustive_matcher 실패" }

Invoke-Native $Colmap @("mapper", "--database_path", $db, "--image_path", $images,
    "--output_path", $sparse)
if ($LASTEXITCODE -ne 0) { throw "mapper 실패" }

# mapper 는 궤도가 끊기면 모델을 여러 개로 쪼갠다. 가장 큰 것을 쓴다.
$best = Get-ChildItem $sparse -Directory | Sort-Object {
    (Get-Item (Join-Path $_.FullName "images.bin")).Length
} -Descending | Select-Object -First 1
if (-not $best) { throw "복원된 모델이 없다" }
Write-Host "[pg]     모델 $($best.Name) 채택"

# ---- 3. 조밀 복원
$dense = Join-Path $Work "dense"
Write-Host "[pg] 3/6 조밀 복원 (오래 걸린다)"
Remove-Item $dense -Recurse -Force -ErrorAction SilentlyContinue
Invoke-Native $Colmap @("image_undistorter", "--image_path", $images,
    "--input_path", $best.FullName, "--output_path", $dense,
    "--output_type", "COLMAP", "--max_image_size", $DenseSize)
if ($LASTEXITCODE -ne 0) { throw "image_undistorter 실패" }

# cache_size 를 줄여야 VRAM 4GB 짜리에서 안 터진다.
Invoke-Native $Colmap @("patch_match_stereo", "--workspace_path", $dense,
    "--workspace_format", "COLMAP", "--PatchMatchStereo.geom_consistency", "true",
    "--PatchMatchStereo.max_image_size", $DenseSize, "--PatchMatchStereo.cache_size", "8")
if ($LASTEXITCODE -ne 0) { throw "patch_match_stereo 실패" }

$fused = Join-Path $dense "fused.ply"
Invoke-Native $Colmap @("stereo_fusion", "--workspace_path", $dense,
    "--workspace_format", "COLMAP", "--input_type", "geometric", "--output_path", $fused)
if ($LASTEXITCODE -ne 0) { throw "stereo_fusion 실패" }

# ---- 4. 머리 위치와 방향
Write-Host "[pg] 4/6 머리 위치와 방향"
$sparseTxt = Join-Path $Work "sparse_txt"
Remove-Item $sparseTxt -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $sparseTxt | Out-Null
Invoke-Native $Colmap @("model_converter", "--input_path", $best.FullName,
    "--output_path", $sparseTxt, "--output_type", "TXT")
if ($LASTEXITCODE -ne 0) { throw "model_converter 실패" }

# 정면 프레임은 정합된 것 중에서 골라야 한다 — dense\images 에 그것만 남아 있다.
$front = Join-Path $Work "front.json"
$pick = Invoke-Native $venvPython @((Join-Path $here "face_to_mesh.py"),
    "--frames", (Join-Path $dense "images"),
    "--model", (Join-Path $Venv "models\face_landmarker.task"),
    "--out", $front, "--top", "1") "^\[face\] 채택"
if ($LASTEXITCODE -ne 0) { throw "face_to_mesh 실패" }
$frontFrame = ($pick -split ':')[-1].Trim()
Write-Host "[pg]     정면 프레임 $frontFrame"

$bounds = Join-Path $Work "head_bounds.json"
Invoke-Native "python" @((Join-Path $here "head_bounds.py"), "--sparse", $sparseTxt,
    "--front-frame", $frontFrame, "--out", $bounds,
    "--radius-scale", $RadiusScale) "^\[bounds\]"
if ($LASTEXITCODE -ne 0) { throw "head_bounds 실패" }

# ---- 5. 머리만 잘라내기
Write-Host "[pg] 5/6 머리만 잘라내기"
$head = Join-Path $Work "head_points.ply"
Invoke-Native "python" @((Join-Path $here "crop_cloud.py"), "--cloud", $fused,
    "--bounds", $bounds, "--out", $head) "^\[crop\]"
if ($LASTEXITCODE -ne 0) { throw "crop_cloud 실패" }

# ---- 6. 메시로 만들기
Write-Host "[pg] 6/6 메시 만들기 (Poisson)"
$mesh = Join-Path $Work "head_mesh.ply"
Invoke-Native $Colmap @("poisson_mesher", "--input_path", $head, "--output_path", $mesh,
    "--PoissonMeshing.trim", $PoissonTrim)
if ($LASTEXITCODE -ne 0) { throw "poisson_mesher 실패" }

Write-Host ""
Write-Host "[pg] 완료"
Write-Host "[pg]   메시   $mesh"
Write-Host "[pg]   방향   $bounds"
Write-Host "[pg] 다음:"
Write-Host "  .\tools\hologram\build.ps1 -Mesh `"$mesh`" -Bounds `"$bounds`" -Sweep 34 -Name face_hologram"
