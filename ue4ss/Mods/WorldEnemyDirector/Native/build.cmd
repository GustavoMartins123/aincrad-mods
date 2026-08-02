@echo off
setlocal enableextensions enabledelayedexpansion

if not defined VSINSTALLDIR (
    set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    if exist "!VSWHERE!" (
        for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
            set "VS_PATH=%%i"
        )
    )
    if defined VS_PATH (
        if exist "!VS_PATH!\Common7\Tools\VsDevCmd.bat" (
            call "!VS_PATH!\Common7\Tools\VsDevCmd.bat" -arch=x64 -host_arch=x64
        )
    )
)

where cl.exe >nul 2>&1
if errorlevel 1 (
    echo [ERRO] Compilador C++ ^(cl.exe^) nao encontrado.
    echo Certifique-se de ter o Visual Studio instalado com a carga de trabalho "Desenvolvimento para Desktop com C++".
    exit /b 1
)

set "WED_BUILD=%~dp0..\..\..\..\.build-wed-native"
set "WED_DLLS=%~dp0..\dlls"

if not exist "%WED_BUILD%" mkdir "%WED_BUILD%"
if errorlevel 1 exit /b %errorlevel%
if not exist "%WED_DLLS%" mkdir "%WED_DLLS%"
if errorlevel 1 exit /b %errorlevel%

cl.exe /nologo /std:c++20 /O2 /GL /MD /EHsc /W4 /permissive- /utf-8 /LD ^
    /Fo"%WED_BUILD%\main.obj" ^
    /Fd"%WED_BUILD%\main.pdb" ^
    /Fe"%WED_BUILD%\main.dll" ^
    "%~dp0src\main.cpp" ^
    /link /INCREMENTAL:NO /LTCG ^
    /IMPLIB:"%WED_BUILD%\main.lib" ^
    /PDB:"%WED_BUILD%\main.pdb"
if errorlevel 1 exit /b %errorlevel%

copy /Y "%WED_BUILD%\main.dll" "%WED_DLLS%\main.dll" >nul
exit /b %errorlevel%
