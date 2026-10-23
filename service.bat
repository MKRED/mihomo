@echo off
chcp 65001 >nul
cd /d "%~dp0"

:: Служебные файлы (mihomo.exe, служба, скрипты, config.yaml, логи, подписка) лежат в core\
set "CORE=%~dp0core"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"

:: Права администратора нужны для управления службой.
:: Перезапускаемся с повышением в Windows Terminal (крупный шрифт, вкладки),
:: а если wt.exe не найден, в обычном консольном окне.
net session >nul 2>&1
if %errorlevel% equ 0 goto admin_ok
set "DIR=%~dp0"
set "DIR=%DIR:~0,-1%"
where wt.exe >nul 2>&1
if %errorlevel% equ 0 (
    powershell -NoProfile -Command "Start-Process wt.exe -Verb RunAs -ArgumentList '-d \"%DIR%\" cmd /c \"%~f0\"'"
) else (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
)
exit /b
:admin_ok

:menu
cls
echo ===== Служба mihomo =====
echo.
%PS% "%CORE%\status.ps1"
echo.
echo  1 - Установить и запустить (автозапуск с Windows)
echo  2 - Запустить
echo  3 - Остановить
echo  4 - Перечитать конфиг (после правки config.template.yaml, без перезапуска)
echo  5 - Удалить службу
echo  6 - Показать последние строки лога
echo  7 - Обновить подписку сейчас
echo  8 - Серверы группы и задержки
echo  9 - Открыть веб-панель в браузере
echo  0 - Выход
echo.
set "SEL="
set /p "SEL=Выбери и нажми Enter: "
if "%SEL%"=="0" exit /b
if "%SEL%"=="1" goto install
if "%SEL%"=="2" goto start
if "%SEL%"=="3" goto stop
if "%SEL%"=="4" goto reload
if "%SEL%"=="5" goto remove
if "%SEL%"=="6" goto log
if "%SEL%"=="7" goto update
if "%SEL%"=="8" goto servers
if "%SEL%"=="9" goto panel
goto menu

:install
:: Два TUN-адаптера и два API на одном порту не уживутся: старая служба sing-box должна быть удалена
sc query sing-box 2>nul | find "RUNNING" >nul
if %errorlevel% equ 0 (
    echo Работает служба sing-box. Сначала остановите и удалите её ^(service.bat в папке sing-box, пункт 5^).
    pause & goto menu
)
:: На свежей машине бинарников нет (их нет в git): скачиваем mihomo.exe и WinSW с GitHub
if not exist "%CORE%\mihomo.exe" goto getbin
if not exist "%CORE%\mihomo-service.exe" goto getbin
goto install_cfg
:getbin
echo Бинарников нет, скачиваю...
%PS% "%CORE%\get-binaries.ps1" || (pause & goto menu)
:install_cfg
%PS% "%CORE%\build-config.ps1" || (pause & goto menu)
"%CORE%\mihomo-service.exe" install
"%CORE%\mihomo-service.exe" start
echo.
echo Панель: http://127.0.0.1:9090/ui ^(скачивается при первом запуске, подождите минуту^)
pause & goto menu

:start
"%CORE%\mihomo-service.exe" start
pause & goto menu

:stop
"%CORE%\mihomo-service.exe" stop
pause & goto menu

:reload
%PS% "%CORE%\build-config.ps1" || (pause & goto menu)
sc query mihomo 2>nul | find "RUNNING" >nul
if %errorlevel% equ 0 (
    %PS% "%CORE%\reload.ps1" -Action Config
) else (
    echo Служба не запущена, конфиг подхватится при запуске
)
pause & goto menu

:remove
"%CORE%\mihomo-service.exe" stop >nul 2>&1
"%CORE%\mihomo-service.exe" uninstall
pause & goto menu

:log
:: mihomo пишет лог в stdout, WinSW складывает его в mihomo-service.out.log
if exist "%CORE%\logs\mihomo-service.out.log" (
    powershell -NoProfile -Command "Get-Content '%CORE%\logs\mihomo-service.out.log' -Tail 30"
) else echo Лога пока нет
echo.
echo ----- обёртка службы -----
if exist "%CORE%\logs\mihomo-service.wrapper.log" (
    powershell -NoProfile -Command "Get-Content '%CORE%\logs\mihomo-service.wrapper.log' -Tail 10"
)
pause & goto menu

:update
%PS% "%CORE%\reload.ps1" -Action Subscription
pause & goto menu

:servers
%PS% "%CORE%\status.ps1" -All
pause & goto menu

:panel
start "" "http://127.0.0.1:9090/ui"
goto menu
