@echo off
rem Example usage:
rem   build.bat "C:\Program Files\Unity\Hub\Editor\<ver>\Editor\Data\PluginAPI"
rem   set UNITY_PLUGIN_API=C:\path\to\PluginAPI && build.bat
setlocal

set "PLUGIN_API=%~1"
if "%PLUGIN_API%"=="" set "PLUGIN_API=%UNITY_PLUGIN_API%"

if "%PLUGIN_API%"=="" (
    echo ERROR: Unity PluginAPI header path not provided.
    echo        Pass it as an argument or via the UNITY_PLUGIN_API env var:
    echo          build.bat "C:\Program Files\Unity\Hub\Editor\^<ver^>\Editor\Data\PluginAPI"
    exit /b 1
)
if not exist "%PLUGIN_API%\IUnityGraphicsD3D12.h" (
    echo ERROR: IUnityGraphicsD3D12.h not found at: %PLUGIN_API%
    exit /b 1
)

set "OUT=build"
if not exist "%OUT%" mkdir "%OUT%"

cl /nologo /LD /O2 /EHsc /std:c++17 ^
   /I "%PLUGIN_API%" ^
   /Fo"%OUT%\\" ^
   NativeGfxPlugin_D3D12.cpp ^
   /Fe:"%OUT%\NativeGfxPlugin.dll" ^
   /link d3d12.lib dxgi.lib

if errorlevel 1 exit /b 1
echo Built: %OUT%\NativeGfxPlugin.dll
echo Copy it to ^<YourUnityProject^>\Assets\Plugins\x86_64\
