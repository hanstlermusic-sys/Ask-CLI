@ECHO OFF
SETLOCAL
set "_script=%~dp0ask-cli.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%_script%" %*
EXIT /B %ERRORLEVEL%
