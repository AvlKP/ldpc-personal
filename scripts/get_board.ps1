param (
    [string]$TempDir,
    [string]$XilinxDir
)

$BoardUrl = "https://github.com/cathalmccabe/pynq-z1_board_files/raw/master/pynq-z1.zip"

if ([string]::IsNullOrWhiteSpace($TempDir) -or [string]::IsNullOrWhiteSpace($XilinxDir)) {
    Write-Error "Usage: .\get_board.ps1 -TempDir <temp_dir> -XilinxDir <vivado_data_dir>"
    exit 1
}

New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

$ZipFile = Split-Path -Leaf $BoardUrl
$TempZipPath = Join-Path $TempDir $ZipFile

Write-Host "Downloading $BoardUrl..."
Invoke-WebRequest -Uri $BoardUrl -OutFile $TempZipPath

$BoardStem = [System.IO.Path]::GetFileNameWithoutExtension($BoardUrl)
Write-Host "Extracting $ZipFile..."

try {
    Expand-Archive -Path $TempZipPath -DestinationPath $TempDir -Force
} catch {
    Write-Error "Failed to unzip the file. Ensure the path is correct."
    exit 1
}

$FinalBoardDir = Join-Path $XilinxDir "data/xhub/boards/XilinxBoardStore/boards/Xilinx"
New-Item -ItemType Directory -Path $FinalBoardDir -Force | Out-Null

$SourceFolder = Join-Path $TempDir $BoardStem
Move-Item -Path $SourceFolder -Destination $FinalBoardDir -Force

Remove-Item -Path $TempDir -Recurse -Force

Write-Host "Board files have been moved to $FinalBoardDir"