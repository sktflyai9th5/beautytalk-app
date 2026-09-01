<#
.SYNOPSIS
    영상 한 바퀴로 머리 덩어리를 실루엣 깎기(visual hull)로 만든다.

.DESCRIPTION
    COLMAP 으로 **카메라 자세만** 풀고(sparse), 프레임마다 머리 실루엣을 따서
    그 교집합으로 덩어리를 깎는다. 조밀 복원(dense)은 하지 않는다 — 매끈한
    피부와 검은 머리에는 맞출 점이 없어서 머리 자리에 조밀점이 0개로 나온다.

    실루엣만 쓰므로 질감이 없어도 형태가 나오지만, 오목한 곳(귀 뒤, 머리카락
    사이)은 메워진 채로 남는다. 결과는 늘 실제보다 조금 통통하다.

    **영상 하나만 쓴다.** 나눠 찍은 영상은 그 사이 고개 각도가 달라져서
    실루엣들이 서로 안 맞고, 안 맞는 만큼 덩어리가 깎여 나간다.

.EXAMPLE
    .\tools\hologram\carve.ps1 -Video "C:\Users\012\Downloads\수지님\KakaoTalk_20260829_135653696.mp4" -Name suzy
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Video,
    [Parameter(Mandatory = $true)][string]$Name,
    # 깎은 머리를 맞출 얼굴 격자. build.ps1 이 남긴 것을 그대로 쓴다.
    [string]$FaceMesh,
    [string]$Work = "$env:LOCALAPPDATA\holo_carve",
    [int]$Fps = 12,
    [int]$FeatureSize = 1600,
    [int]$Grid = 224,
    [int]$Miss = 2,
    [double]$BoxScale = 2.4,
    # 균일한 밀도의 점구름이라 trim 을 높이면 통째로 잘려 나간다 (9 는 빈 메시).
    [int]$PoissonTrim = 5,
    [string]$Colmap = "$env:LOCALAPPDATA\colmap\bin\colmap.exe",
    [string]$Venv = "C:\Users\012\.venvs\holoface",
    [switch]$SkipSparse
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Invoke-Native([string]$Exe, [string[]]$Arguments, [string]$Filter) {
    # PowerShell 5.1 은 네이티브 exe 의 stderr 를 ErrorRecord 로 감싸서 exit 0
    # 이어도 죽는다. 성패는 종료 코드로만 본다.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($Filter) { & $Exe @Arguments | Select-String -Pattern $Filter | ForEach-Object { $_.Line } }
        else { & $Exe @Arguments | Out-Null }
    }
    finally { $ErrorActionPreference = $prev }
}

if (-not (Test-Path $Colmap)) { throw "COLMAP 이 없다: $Colmap" }
$venvPython = Join-Path $Venv "Scripts\python.exe"
if (-not (Test-Path $venvPython)) { throw "mediapipe venv 가 없다: $venvPython" }
$segModel = Join-Path $Venv "models\selfie_multiclass_256x256.tflite"
if (-not (Test-Path $segModel)) { throw "분할 모델이 없다: $segModel" }

$work = Join-Path $Work $Name
$images = Join-Path $work "images"
$db = Join-Path $work "db.db"
$sparse = Join-Path $work "sparse"
$sparseTxt = Join-Path $work "sparse_txt"

if (-not $SkipSparse) {
    $ffmpeg = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse `
            -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    if (-not $ffmpeg) { $ffmpeg = (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue).Source }
    if (-not $ffmpeg) { throw "ffmpeg 을 못 찾았다" }

    Write-Host "[carve] 1/6 프레임 추출 (${Fps}fps)"
    if (Test-Path $images) { Remove-Item $images -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $images | Out-Null
    Invoke-Native $ffmpeg @("-y", "-loglevel", "error", "-i", $Video,
        "-vf", "fps=$Fps", "-q:v", "2", (Join-Path $images "f_%03d.jpg"))
    Write-Host "[carve]     $((Get-ChildItem $images -Filter *.jpg).Count) 장"

    Write-Host "[carve] 2/6 카메라 자세 (COLMAP sparse)"
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
}

# mapper 는 궤도가 끊기면 모델을 여러 개로 쪼갠다. 가장 큰 것을 쓴다.
$best = Get-ChildItem $sparse -Directory | Sort-Object {
    (Get-Item (Join-Path $_.FullName "images.bin")).Length
} -Descending | Select-Object -First 1
if (-not $best) { throw "복원된 모델이 없다" }

Remove-Item $sparseTxt -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $sparseTxt | Out-Null
Invoke-Native $Colmap @("model_converter", "--input_path", $best.FullName,
    "--output_path", $sparseTxt, "--output_type", "TXT")
if ($LASTEXITCODE -ne 0) { throw "model_converter 실패" }

# 정합된 프레임만 따로 모은다. 정면 컷은 **정합된 것 중에서** 골라야
# head_bounds.py 가 그 자세를 찾을 수 있다.
$registered = Join-Path $work "registered"
Remove-Item $registered -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $registered | Out-Null
$names = Get-Content (Join-Path $sparseTxt "images.txt") |
Where-Object { $_ -notmatch '^#' -and $_.Trim() } |
ForEach-Object { ($_ -split '\s+')[9] } |
Where-Object { $_ -match '\.jpg$' }
foreach ($n in $names) { Copy-Item (Join-Path $images $n) $registered -Force }
Write-Host "[carve]     정합 $($names.Count) / $((Get-ChildItem $images -Filter *.jpg).Count) 장"

# 맞출 얼굴 격자가 없으면 여기서 하나 뽑는다. 굽는 쪽과 같은 격자를 쓰는 게
# 원칙이다 — 다른 컷에서 뽑은 격자에 맞추면 붙일 때 얼굴이 미세하게 어긋난다.
if (-not $FaceMesh) {
    $FaceMesh = Join-Path $work "front_mesh.json"
    Invoke-Native $venvPython @((Join-Path $here "face_to_mesh.py"),
        "--frames", $registered, "--model", (Join-Path $Venv "models\face_landmarker.task"),
        "--out", $FaceMesh, "--top", "1") "^\[face\] 채택"
    if ($LASTEXITCODE -ne 0) { throw "face_to_mesh 실패" }
}
if (-not (Test-Path $FaceMesh)) { throw "얼굴 격자가 없다: $FaceMesh" }

Write-Host "[carve] 3/6 얼굴 점 삼각측량 (머리 상자와 좌표 맞추기)"
$points = Join-Path $work "face_points.json"
Invoke-Native $venvPython @((Join-Path $here "face_points.py"), "--sparse", $sparseTxt,
    "--frames", $registered, "--model", (Join-Path $Venv "models\face_landmarker.task"),
    "--face-mesh", $FaceMesh, "--out", $points) "^\[points\]"
if ($LASTEXITCODE -ne 0) { throw "face_points 실패" }

Write-Host "[carve] 4/6 머리 실루엣"
$masks = Join-Path $work "masks"
Invoke-Native $venvPython @((Join-Path $here "head_masks.py"),
    "--frames", $registered, "--model", $segModel, "--out", $masks,
    "--preview", (Join-Path $work "mask_preview")) "^\[mask\]"
if ($LASTEXITCODE -ne 0) { throw "head_masks 실패" }

Write-Host "[carve] 5/6 실루엣으로 깎기 (복셀 $Grid^3)"
$cloud = Join-Path $work "head_points.ply"
Invoke-Native "python" @((Join-Path $here "carve_head.py"), "--sparse", $sparseTxt,
    "--masks", $masks, "--points", $points, "--out", $cloud,
    "--grid", $Grid, "--miss", $Miss, "--box-scale", $BoxScale) "^\[carve\]"
if ($LASTEXITCODE -ne 0) { throw "carve_head 실패" }

Write-Host "[carve] 6/6 메시 만들기 (Poisson) + 얼굴 좌표로 옮기기"
$mesh = Join-Path $work "head_mesh.ply"
Invoke-Native $Colmap @("poisson_mesher", "--input_path", $cloud, "--output_path", $mesh,
    "--PoissonMeshing.trim", $PoissonTrim)
if ($LASTEXITCODE -ne 0) { throw "poisson_mesher 실패" }

# 촬영본에서 색을 읽어 머리에 입힌다. 단색으로 두면 하얀 수영모처럼 보인다.
$colored = Join-Path $work "head_colored.ply"
Invoke-Native "python" @((Join-Path $here "color_head.py"), "--sparse", $sparseTxt,
    "--frames", $registered, "--masks", $masks, "--hull", $mesh,
    "--out", $colored) "^\[color\]"
if ($LASTEXITCODE -ne 0) { throw "color_head 실패" }

$fitted = Join-Path $work "head_fitted.ply"
Invoke-Native "python" @((Join-Path $here "fit_head.py"), "--points", $points,
    "--hull", $colored, "--face-mesh", $FaceMesh, "--out", $fitted) "^\[fit\]"
if ($LASTEXITCODE -ne 0) { throw "fit_head 실패" }

Write-Host ""
Write-Host "[carve] 완료"
Write-Host "[carve]   머리    $fitted"
Write-Host "[carve]   얼굴    $FaceMesh"
Write-Host "[carve] 다음:"
Write-Host "  build.ps1 ... -HeadMesh `"$fitted`""
