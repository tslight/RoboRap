@echo off

set pwd=%~dp0
set pwd=%pwd:~0,-1%

if exist F:\ (
net use F: /delete
)

:: replace with appropriate hostname.domain.name values
if "%pwd%" == "\\hostname.domain.name\windows\Scripts" (
net use F: \\hostname.domain.name\windows
) else if "%pwd%" == "\\backup\windows\Scripts" (
net use F: \\backup\windows
) else (
net use F: \\hostname\windows
)

set params=

set typeq="Would you like to [b]ackup or [r]estore? "
set userq="Automate user selection? Enter [y]es or [n]o? "
set excludeq="Automate excludes selection? Enter [y]es or [n]o? "
set verboseq="Run with increased verbosity? Enter [y]es or [n]o? "

call:get_type %typeq%
if %errorlevel% equ 2 (echo. & pause & exit)

echo.
call:get_opts %userq%, -AutomateUsers
if %errorlevel% equ 2 (echo. & pause & exit)

if "%type%" == "b" (
echo.
call:get_opts %excludeq%, -AutomateExcludes
if %errorlevel% equ 2 (echo. & pause & exit)
)

echo.
call:get_opts %verboseq%, -Verbose
if %errorlevel% equ 2 (echo. & pause & exit)

cls

powershell.exe -ExecutionPolicy Bypass -Command "Unblock-File -Path %pwd%\ps\RoboRapAD.ps1"
powershell.exe -ExecutionPolicy Bypass -Command "%pwd%\ps\RoboRapAD.ps1 %params%"

echo. & pause & exit

rem Functions

:get_type
set /p "type=%~1"
if "%type%" == "b" (
set "params=C:\Users F: "
exit /b 0
) else if "%type%" == "r" (
set "params=F: C:\Users "
exit /b 0
) else if "%type%" == "q" (
exit /b 2
) else (
echo.
echo [%type%] is invalid. Enter [b]ackup or [r]estore.
echo.
goto:get_type
)

:get_opts
call:ask "%~1"
if %errorlevel% equ 0 (
set "params=%params%%~2 "
exit /b 0
) else if %errorlevel% equ 1 (
exit /b 0
) else if %errorlevel% equ 2 (
exit /b 2
)

:ask
set /p "ans=%~1"
if "%ans%" == "y" (
exit /b 0
) else if "%ans%" == "n" (
exit /b 1
) else if "%ans%" == "q" (
exit /b 2
) else (
echo.
echo [%ans%] is invalid. Enter [y]es, [n]o or [q]uit.
echo.
goto:ask
)
