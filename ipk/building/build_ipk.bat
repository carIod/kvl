@echo off
call config.bat
rem set CYGWIN_BASH="C:\ ... \cygwin64\bin\bash.exe"
rem set BUILD_SCRIPT="/cygdrive/c/ ... /kvl/ipk/building/build_ipk.sh"

if not exist %CYGWIN_BASH% (
    echo Error: Cygwin not found at %CYGWIN_BASH%
    echo Please install Cygwin or update the path in script
    pause
    exit /b 1
)
echo ------------------------------------ 
echo Start building ipk packadge
echo ------------------------------------


%CYGWIN_BASH% --login -c "%BUILD_SCRIPT%"
pause