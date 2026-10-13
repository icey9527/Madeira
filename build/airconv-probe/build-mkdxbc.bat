@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
cd /d %~dp0
cl /nologo /O2 /MT /EHsc /Fe:mkdxbc.exe mkdxbc.cpp /link d3dcompiler.lib
