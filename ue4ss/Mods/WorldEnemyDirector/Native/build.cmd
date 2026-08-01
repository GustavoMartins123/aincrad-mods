@echo off
setlocal

call "E:\Microsoft Visual Studio 2022\Common7\Tools\VsDevCmd.bat" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b %errorlevel%

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
