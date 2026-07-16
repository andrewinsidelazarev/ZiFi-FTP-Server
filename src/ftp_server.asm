; Точка входа приложения. PLUGIN обязан быть первым байтом по логическому адресу #8000.
;
; IX при входе указывает на служебную структуру Wild Commander. Поле IX+29
; содержит устройство активной панели и сохраняется до того, как IX начнёт
; использоваться оконными функциями. Жизненный цикл строго последовательный:
; конфигурация -> ZiFi/Wi-Fi -> FTP listener -> цикл опроса -> остановка.

PLUGIN:
        push ix
        ld a,(ix+29)                     ; устройство активной панели Wild Commander
        ld (ConfigPanelDevice),a
        ld a,1
        call WC_INT_PL                   ; запретить WC перерисовывать часы под нашим окном
        call WC_GEDPL                   ; получить палитру/параметры текущего экрана
        call Ui_Open

        ld hl,UiStageConfig
        call Ui_SetStatus
        call Ui_Draw
        call Config_Load
        jr c,.config_error

        call Ui_BuildPort
        ld hl,UiStageZifi
        call Ui_SetStatus
        call Ui_Draw
        call Net_Start
        jr c,.network_error

        ld hl,UiStageListening
        call Ui_SetStatus
        call Ui_BuildAddress
        call Ui_Draw

.server_loop:
        ; Server_Poll выгребает всю уже накопленную очередь ZiFi без блокировки.
        ; HALT отдаёт время WC между опросами и не создаёт busy-loop на Z80.
        ei
        call Server_Poll
        call WC_ESC
        jr nz,.exit
        halt
        jr .server_loop

.config_error:
        ; ConfigError переводится в понятную строку, но окно остаётся открытым,
        ; чтобы пользователь успел прочитать причину до нажатия Esc.
        ld a,(ConfigError)
        cp 1
        ld hl,UiErrorSd
        jr z,.fatal
        cp 2
        ld hl,UiErrorDir
        jr z,.fatal
        cp 3
        ld hl,UiErrorIni
        jr z,.fatal
        ld hl,UiErrorConfig
        jr .fatal

.network_error:
        ; NetError различает отсутствие платы, ошибку CWJAP, отсутствие DHCP и
        ; невозможность открыть CIPSERVER.
        ld a,(NetError)
        cp 1
        ld hl,UiErrorNoZifi
        jr z,.fatal
        cp 2
        ld hl,UiErrorWifi
        jr z,.fatal
        cp 3
        ld hl,UiErrorIp
        jr z,.fatal
        ld hl,UiErrorServer

.fatal:
        call Ui_SetStatus
        call Ui_Draw
.fatal_wait:
        ei
        halt
        call WC_ESC
        jr z,.fatal_wait

.exit:
        ; Сначала закрыть listener/сбросить ESP, затем восстановить область экрана,
        ; сохранённую WC_PRWOW при Ui_Open.
        call Net_Stop
        ld ix,FtpWindow
        call WC_RRESB
        ; При возврате Wild Commander сам восстанавливает настройки прерываний.
        xor a                            ; код возврата: обычный выход из плагина
        pop ix
        ret

        INCLUDE "ui.asm"
        INCLUDE "network.asm"
        INCLUDE "ftp_commands.asm"
