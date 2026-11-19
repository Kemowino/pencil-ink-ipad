@echo off
cd /d "%~dp0"
if "%~1"=="" (
    echo Drag and drop the PencilInkNative ZIP file directly onto this update.bat file!
    pause
    exit /b
)
echo Extracting %~nx1...
if exist "Sources" rmdir /s /q "Sources"
if exist ".github" rmdir /s /q ".github"
powershell -NoProfile -Command "Expand-Archive -Path '%~1' -DestinationPath '.' -Force"
echo Pushing update to GitHub...
git branch -M main
git add -A
git commit -m "Update: %~n1"
git push -u origin main
echo.
echo Done! Opening GitHub Actions to watch your IPA build...
start "" "https://github.com/Kemowino/pencil-ink-ipad/actions"
pause