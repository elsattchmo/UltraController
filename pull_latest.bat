@echo off
rem Check GitHub for new commits on this branch and pull them in. Never overwrites local work:
rem it only fast-forwards, and stops (changing nothing) if you have uncommitted changes or
rem commits GitHub doesn't have.
rem
rem   pull_latest.bat        (double-click it, or run it from a terminal)
setlocal
cd /d "%~dp0"
set CODE=0

for /f %%i in ('git rev-parse --abbrev-ref HEAD') do set BRANCH=%%i
echo Checking GitHub (origin/%BRANCH%) ...
git fetch origin --quiet
if errorlevel 1 goto :unreachable
git rev-parse --verify -q origin/%BRANCH% >nul 2>&1
if errorlevel 1 goto :nobranch

for /f %%i in ('git rev-list --count HEAD..origin/%BRANCH%') do set BEHIND=%%i
for /f %%i in ('git rev-list --count origin/%BRANCH%..HEAD') do set AHEAD=%%i

if not "%BEHIND%"=="0" goto :behind
echo Up to date.
if not "%AHEAD%"=="0" echo (%AHEAD% local commit(s) not pushed yet: git push)
goto :done

:behind
echo %BEHIND% new commit(s) on GitHub:
git log --oneline HEAD..origin/%BRANCH%
echo.
if not "%AHEAD%"=="0" goto :diverged
set DIRTY=
for /f "delims=" %%i in ('git status --porcelain -uno') do set DIRTY=1
if defined DIRTY goto :dirty

rem The open Godot editor writes a .uid for every new script it sees; when GitHub has that same
rem file, git refuses to pull over the local copy. GitHub's copy wins: remove the local one.
for /f "delims=" %%f in ('git ls-files --others --exclude-standard -- "*.uid"') do (
	git cat-file -e origin/%BRANCH%:%%f 2>nul && call :rmuid "%%f"
)
git pull --ff-only --quiet origin %BRANCH%
if errorlevel 1 goto :pullfailed
for /f "delims=" %%i in ('git log --oneline -1') do echo Pulled. Now at %%i
goto :done

:diverged
echo Not pulled: you also have %AHEAD% local commit(s) GitHub doesn't, so the branches have diverged.
echo Merge by hand:  git merge origin/%BRANCH%
set CODE=2
goto :done

:dirty
echo Not pulled: you have uncommitted changes. Commit or stash them first:
git status --short -uno
set CODE=2
goto :done

:unreachable
echo Could not reach GitHub.
set CODE=1
goto :done

:nobranch
echo GitHub has no branch '%BRANCH%' yet.
set CODE=1
goto :done

:pullfailed
echo The pull failed (see the message above); nothing was changed.
set CODE=1
goto :done

:rmuid
rem (git lists paths with /, del wants \)
set "UIDF=%~1"
del /q "%UIDF:/=\%"
echo Removed local %~1 (GitHub has it)
exit /b 0

:done
rem Double-clicked (not run from a terminal): keep the window open to read the result.
echo %cmdcmdline% | "%SystemRoot%\System32\find.exe" /i "%~nx0" >nul && pause
exit /b %CODE%
