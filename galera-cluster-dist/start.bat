@echo off
setlocal
set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"
set "GALERA_CLUSTER_DIR=%ROOT%"
set "BIN=%ROOT%\bin\windows-x86_64\galera-tui.exe"
if not exist "%BIN%" (
    echo [ERROR] Binary tidak ada: %BIN%
    echo Build di Windows: cd tui ^&^& cargo build --release
    exit /b 1
)
"%BIN%"
