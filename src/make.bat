@CLS

@REM *** Settings ***

@REM BASE        = root directory of metalua sources
@REM DISTRIB_BIN = metalua executables target directory
@REM DISTRIB_LIB = metalua libraries target directory, can be an existing path referenced in LUA_PATH
@REM LUA, LUAC   = Lua executables, provided by metalua by default.

@REM --- BEGINNING OF USER-EDITABLE PART ---

@set BASE=%CD%
@set DISTRIB=%BASE%\..\..
@set DISTRIB_BIN=%DISTRIB%\bin
@set DISTRIB_LIB=%DISTRIB%\resources
@set LUA=%DISTRIB_BIN%\lua
@set LUAC=%DISTRIB_BIN%\luac
@set BC_EXT=lbc

@REM --- END OF USER-EDITABLE PART ---


@REM *** Create the distribution directories, populate them with lib sources ***

mkdir %DISTRIB%
mkdir %DISTRIB_BIN%
mkdir %DISTRIB_LIB%
xcopy /y /s lib %DISTRIB_LIB%
xcopy /y /s ..\bin %DISTRIB_BIN%

@REM *** Generate a callable batch metalua.bat script ***

echo @set LUA_PATH=?.%BC_EXT%;?.lua;%DISTRIB_LIB%\?.%BC_EXT%;%DISTRIB_LIB%\?.lua > %DISTRIB_BIN%\metalua.bat
echo @set LUA_MPATH=?.mlua;%DISTRIB_LIB%\?.mlua >> %DISTRIB_BIN%\metalua.bat
echo @%LUA% %DISTRIB_LIB%\metalua.%BC_EXT% %%* >> %DISTRIB_BIN%\metalua.bat


@REM *** Compiling the parts of the compiler written in plain Lua ***

cd compiler
%LUAC% -o %DISTRIB_LIB%\metalua\bytecode.%BC_EXT% lopcodes.lua lcode.lua ldump.lua compile.lua
%LUAC% -o %DISTRIB_LIB%\metalua\mlp.%BC_EXT% lexer.lua gg.lua mlp_lexer.lua mlp_misc.lua mlp_table.lua mlp_meta.lua mlp_expr.lua mlp_stat.lua mlp_ext.lua
cd ..

@REM *** Bootstrap the parts of the compiler written in metalua ***

%LUA% %BASE%\build-utils\bootstrap.lua %BASE%\compiler\mlc.mlua output=%DISTRIB_LIB%\metalua\mlc.%BC_EXT%
%LUA% %BASE%\build-utils\bootstrap.lua %BASE%\compiler\metalua.mlua output=%DISTRIB_LIB%\metalua.%BC_EXT%

@REM *** Finish the bootstrap: recompile the metalua parts of the compiler with itself ***

call %DISTRIB_BIN%\metalua -vb -f compiler\mlc.mlua     -o %DISTRIB_LIB%\metalua\mlc.%BC_EXT%
call %DISTRIB_BIN%\metalua -vb -f compiler\metalua.mlua -o %DISTRIB_LIB%\metalua.%BC_EXT%

@REM *** Precompile metalua libraries ***
%LUA% %BASE%\build-utils\precompile.lua directory=%DISTRIB_LIB% metalua_compiler=%DISTRIB_BIN%\metalua lua_compiler=%DISTRIB_BIN%\luac bytecode_ext=%BC_EXT%
