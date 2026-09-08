@echo off
REM Release AAB export, in a batch file rather than inline in a shell.
REM
REM PowerShell's Start-Process joins -ArgumentList without quoting, so a preset
REM named "Android Release" arrives as two arguments and Godot exports the
REM "Android" preset to a file called "Release" - which then fails with
REM "Invalid filename! Android APK requires the *.apk extension", a message
REM that has nothing to do with the actual mistake. A batch file passes the
REM quotes through intact.
REM
REM Usage (from the project root):
REM   set GODOT=...\Godot_v4.7.2-stable_win64_console.exe
REM   set GODOT_ANDROID_KEYSTORE_RELEASE_PATH=C:/dev/keys/upload.keystore
REM   set GODOT_ANDROID_KEYSTORE_RELEASE_USER=upload
REM   set GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD=...
REM   scripts\export_release.bat

if "%GODOT%"=="" (
  echo GODOT is not set - point it at the Godot console executable.
  exit /b 2
)

"%GODOT%" --headless --path "%~dp0.." --export-release "Android Release" "build/godot-template.aab"
echo GODOT_EXIT=%ERRORLEVEL%
exit /b %ERRORLEVEL%
