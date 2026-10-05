@echo off
rem Builds loopback.exe with the Visual Studio 2022 C++ toolset (x64).
setlocal
set "VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
  for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath`) do set "VCVARS=%%i\VC\Auxiliary\Build\vcvars64.bat"
)
call "%VCVARS%" >nul || exit /b 1
cd /d "%~dp0"
cl /nologo /O2 /EHsc /std:c++17 /DUNICODE /D_UNICODE loopback.cpp /Fe:..\recorder\bin\loopback.exe /link /SUBSYSTEM:CONSOLE || exit /b 1
del loopback.obj 2>nul
echo built ..\recorder\bin\loopback.exe
