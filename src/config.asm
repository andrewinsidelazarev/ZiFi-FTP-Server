; Чтение /zifi/zifi.ini через файловый поток FAT из Wild Commander.
; Обязательные ключи сохраняют формат существующих приложений ZiFi:
;   пример имени сети: SSID: ...
;   пример пароля: password: ...
; Необязательные ключи FTP: ftp_user, ftp_password, ftp_port и ftp_timeout.
;
; Wild Commander читает FAT через состояние выбранного STREAM. Поток 0 служит
; текущим каталогом FTP, поток 1 — независимой опорой выбранного тома. Поиск INI
; перебирает допустимые SD-устройства, а после успеха переводит оба потока в их
; корень. Это важно: прямого доступа к портам SD в плагине нет.

CONFIG_SECTOR_SIZE equ 512

; Найти, прочитать и разобрать конфигурацию. Читается один сектор: значение
; каждого параметра обязано начаться до байта 511. Выход: CF=0 — настройки и
; CmdCwjap готовы; CF=1 — ConfigError содержит этап ошибки 1..4.
Config_Load:
        call Config_Defaults

        ; STREAM #FE разрешено вызывать только для начального клонирования
        ; активной панели. Повторный вызов вернул бы нас из корня в каталог панели.
        ld d,STREAM_CLONE
        call WC_STREAM

        ; Сначала проверить SD активной панели, затем SD1 и SD2 Z-Controller.
        ; Корень FTP останется на томе с найденным INI.
        call Config_TryActiveSd
        jr nc,.file_open
        ld b,0                         ; SD1 Z-Controller в интерфейсе STREAM
        call Config_TryDevice
        jr nc,.file_open
        ld b,6                         ; SD2 Z-Controller в интерфейсе STREAM
        call Config_TryDevice
        jr nc,.file_open

        ld a,(ConfigHaveRoot)
        or a
        jp z,.stream_error
        ld a,(ConfigDirSeen)
        or a
        jp z,.directory_error
        jp .file_error

.file_open:
        ; Размер WC_FENTRY приходит как DE:HL. Для парсера достаточно не более
        ; 511 байтов: последний байт сектора резервируется под завершающий ноль.
        ld a,d
        or e
        jr nz,.limit_ini
        ld a,h
        cp 2
        jr nc,.limit_ini
        ld (IniLength),hl
        jr .length_ready
.limit_ini:
        ld hl,CONFIG_SECTOR_SIZE-1
        ld (IniLength),hl
.length_ready:
        call WC_GFILE
        ld hl,IniBuffer
        ld b,1
        call WC_LOAD512
        ld de,(IniLength)
        ld hl,IniBuffer
        add hl,de
        xor a
        ld (hl),a

        ld de,KeySsid
        call Ini_FindKey
        jr nc,.ssid_error
        ld de,WifiSsid
        ld b,32
        call Ini_CopyValue
        ld a,(WifiSsid)
        or a
        jr z,.ssid_error

        ld de,KeyWifiPassword
        call Ini_FindKey
        jr nc,.password_error
        ld de,WifiPassword
        ld b,63
        call Ini_CopyValue

        ld de,KeyFtpUser
        call Ini_FindKey
        jr nc,.skip_user
        ld de,FtpUser
        ld b,24
        call Ini_CopyValue
.skip_user:
        ld de,KeyFtpPassword
        call Ini_FindKey
        jr nc,.skip_password
        ld de,FtpPassword
        ld b,32
        call Ini_CopyValue
.skip_password:
        ld de,KeyFtpPort
        call Ini_FindKey
        jr nc,.skip_port
        call Ini_ParseWordValue
        jr c,.port_error
        ld a,h
        or l
        jr z,.port_error
        ld (FtpPort),hl
.skip_port:
        ld de,KeyFtpTimeout
        call Ini_FindKey
        jr nc,.skip_timeout
        call Ini_ParseWordValue
        jr c,.timeout_error
        ld a,h
        or l
        jr z,.timeout_error
        ld (FtpTimeout),hl
.skip_timeout:
        call Config_BuildCwjap
        xor a
        ld (ConfigError),a
        call Config_RestoreRoot
        or a
        ret

.stream_error:
        ld a,1
        jr .fail
.directory_error:
        ld a,2
        jr .fail
.file_error:
        ld a,3
        jr .fail
.ssid_error:
        ld a,4
        jr .fail
.password_error:
        ld a,5
        jr .fail
.port_error:
        ld a,6
        jr .fail
.timeout_error:
        ld a,7
.fail:
        ld (ConfigError),a
        call Config_RestoreRoot
        scf
        ret

; После любой попытки поиска вернуть рабочие потоки в корень найденного тома.
Config_RestoreRoot:
        ld a,(ConfigHaveRoot)
        or a
        ret z
        jp Config_RootBothStreams

; Инициализировать необязательные параметры и очистить обязательные строки.
Config_Defaults:
        xor a
        ld (ConfigHaveRoot),a
        ld (ConfigDirSeen),a
        ld (ConfigError),a
        ld hl,DefaultFtpUser
        ld de,FtpUser
        call CopyZ
        ld hl,DefaultFtpPassword
        ld de,FtpPassword
        call CopyZ
        ld hl,21
        ld (FtpPort),hl
        ld hl,600
        ld (FtpTimeout),hl
        xor a
        ld (WifiSsid),a
        ld (WifiPassword),a
        ret

; Клонировать активную SD-панель Wild Commander. Номера 1, 2 и 6 обозначают
; соответственно SD1 Z-Controller, SD NeoGS и SD2 Z-Controller.
Config_TryActiveSd:
        ld a,(ConfigPanelDevice)
        cp 1
        jr z,.accepted
        cp 2
        jr z,.accepted
        cp 6
        jr nz,Config_TryFailed
.accepted:
        call Config_RootBothStreams
        jp Config_OpenOnRoot

; B — номер устройства интерфейса STREAM, раздел C в WC не используется.
Config_TryDevice:
        ld a,b
        ld (ConfigTryDevice),a
        ld c,0
        ld d,0
        call WC_STREAM
        jr nz,Config_TryFailed
        ld a,(ConfigTryDevice)
        ld b,a
        ld c,0
        ld d,1
        call WC_STREAM
        jr nz,Config_TryFailed
        call Config_RootBothStreams
        jp Config_OpenOnRoot

; Установить корень отдельно в обоих рабочих потоках. STREAM #FE здесь
; вызывать нельзя: он снова склонировал бы исходный каталог активной панели.
Config_RootBothStreams:
        ld d,0
        ld bc,#FFFF
        call WC_STREAM
        ld d,STREAM_ROOT
        call WC_STREAM
        ld d,1
        ld bc,#FFFF
        call WC_STREAM
        ld d,STREAM_ROOT
        call WC_STREAM
        ld d,0
        ld bc,#FFFF
        call WC_STREAM
        ret

; В текущем корне найти каталог zifi (флаг #10), войти в него и найти обычный
; файл zifi.ini (флаг #00). Успех WC_FENTRY обозначается NZ.
Config_OpenOnRoot:
        ld a,1
        ld (ConfigHaveRoot),a

        ld hl,ConfigDirEntry
        call WC_FENTRY
        jr z,Config_TryFailed
        ld a,1
        ld (ConfigDirSeen),a
        call WC_GDIR
        ld hl,ConfigFileEntry
        call WC_FENTRY
        jr z,Config_TryFailed
        or a
        ret

Config_TryFailed:
        scf
        ret

; DE — ключ вместе с двоеточием. Поиск идёт только с начала непустого участка
; каждой строки, ASCII-регистр букв игнорируется. Разделителями строк считаются
; CR, LF и CRLF — старые ZiFi-файлы встречаются во всех трёх вариантах.
; Выход: CF=1 и HL указывает на значение после горизонтальных пробелов;
; CF=0 — ключ не найден.
Ini_FindKey:
        ld (IniKeyPtr),de
        ld hl,IniBuffer
        call Ini_SkipUtf8Bom
.line:
        call Ini_SkipLineBreaks
        call Ini_SkipHorizontal
        ld de,(IniKeyPtr)
        push hl
.compare:
        ld a,(de)
        or a
        jr z,.found
        call AsciiFold
        ld b,a
        ld a,(hl)
        call AsciiFold
        cp b
        jr nz,.not_here
        inc de
        inc hl
        jr .compare
.not_here:
        pop hl
.skip_line:
        ld a,(hl)
        or a
        jr z,.missing
        inc hl
        cp 13
        jr z,.line
        cp 10
        jr nz,.skip_line
        jr .line
.found:
        pop de                         ; снять со стека сохранённое начало строки
        call Ini_SkipHorizontal
        scf
        ret
.missing:
        or a
        ret

; Пропустить необязательную UTF-8 BOM EF BB BF только в начале файла.
; При неполной сигнатуре вернуть HL к исходному байту без изменений.
Ini_SkipUtf8Bom:
        ld a,(hl)
        cp #EF
        ret nz
        inc hl
        ld a,(hl)
        cp #BB
        jr nz,.rewind_one
        inc hl
        ld a,(hl)
        cp #BF
        jr nz,.rewind_two
        inc hl
        ret
.rewind_two:
        dec hl
.rewind_one:
        dec hl
        ret

; Пропустить любую последовательность CR/LF. Это одновременно обрабатывает
; классические CR, Unix LF, DOS/Windows CRLF и пустые строки между параметрами.
Ini_SkipLineBreaks:
        ld a,(hl)
        cp 13
        jr z,.one
        cp 10
        ret nz
.one:
        inc hl
        jr Ini_SkipLineBreaks

; Пропустить только пробелы и TAB. CR/LF оставляются границами значения.
Ini_SkipHorizontal:
        ld a,(hl)
        cp ' '
        jr z,.one
        cp 9
        ret nz
.one:
        inc hl
        jr Ini_SkipHorizontal

; Нормализовать одну ASCII-букву A..Z в нижний регистр; остальные байты не менять.
AsciiFold:
        cp 'A'
        ret c
        cp 'Z'+1
        ret nc
        add a,32
        ret

; HL — значение, DE — приёмник, B — предел длины. Кавычки необязательны;
; пробелы и табуляции справа удаляются. Нулевой байт записывается всегда.
Ini_CopyValue:
        xor a
        ld (IniQuoted),a
        ld a,(hl)
        cp '"'
        jr nz,.start
        inc hl
        ld a,1
        ld (IniQuoted),a
.start:
        ld (IniCopyStart),de
.loop:
        ld a,b
        or a
        jr z,.finish
        ld a,(hl)
        or a
        jr z,.finish
        cp 13
        jr z,.finish
        cp 10
        jr z,.finish
        cp '"'
        jr nz,.store
        ld a,(IniQuoted)
        or a
        jr nz,.finish
        ld a,'"'
.store:
        ld (de),a
        inc de
        inc hl
        dec b
        jr .loop
.finish:
        call Ini_TrimRight
        xor a
        ld (de),a
        ret

; Отступить DE через конечные пробелы/TAB, не переходя левее IniCopyStart.
Ini_TrimRight:
        ld hl,(IniCopyStart)
.loop:
        ld a,d
        cp h
        jr nz,.has_data
        ld a,e
        cp l
        ret z
.has_data:
        dec de
        ld a,(de)
        cp ' '
        jr z,.loop
        cp 9
        jr z,.loop
        inc de
        ret

; Числовые значения подчиняются тому же правилу, что строки: внешние двойные
; кавычки необязательны. Закрывающая кавычка остановит обычный разбор цифр.
Ini_ParseWordValue:
        ld a,(hl)
        cp '"'
        jr nz,Ini_ParseWord
        inc hl

; Разобрать беззнаковое десятичное слово по HL. Выход: HL — число,
; CF=1 — неверная запись или переполнение.
Ini_ParseWord:
        ld de,0
        ld b,0                          ; число цифр
.digit:
        ld a,(hl)
        cp '0'
        jr c,.done
        cp '9'+1
        jr nc,.done
        sub '0'
        ld c,a
        ; Проверить переполнение до умножения: 65535 / 10 = 6553, остаток 5.
        push hl
        ld hl,6553
        or a
        sbc hl,de
        pop hl
        jr c,.invalid
        jr nz,.mul
        ld a,c
        cp 6
        jr nc,.invalid
.mul:
        push hl
        ex de,hl
        add hl,hl                       ; умножение на 2
        ld de,hl
        add hl,hl                       ; умножение на 4
        add hl,hl                       ; умножение на 8
        add hl,de                       ; умножение на 10
        ld e,c
        ld d,0
        add hl,de
        jr c,.overflow_pop
        ex de,hl
        pop hl
        inc hl
        inc b
        jr .digit
.overflow_pop:
        pop hl
        scf
        ret
.done:
        ld a,b
        or a
        jr z,.invalid
        ex de,hl
        or a
        ret
.invalid:
        scf
        ret

; Собрать современную команду подключения без изменения flash-настроек ESP:
; Формат: AT+CWJAP_CUR="<SSID>","<password>"\r\n
Config_BuildCwjap:
        ld hl,CwjapPrefix
        jr Config_BuildCwjapFromPrefix

; Собрать совместимый вариант AT+CWJAP для старых прошивок без суффикса _CUR.
Config_BuildCwjapLegacy:
        ld hl,CwjapLegacyPrefix

; Общий конструктор CWJAP. HL указывает на префикс, DE последовательно проходит
; CmdCwjap. Кавычки и обратные косые черты внутри SSID/пароля экранируются.
Config_BuildCwjapFromPrefix:
        ld de,CmdCwjap
        call CopyZNoTerm
        ld hl,WifiSsid
        call CopyAtEscaped
        ld a,'"'
        ld (de),a
        inc de
        ld a,','
        ld (de),a
        inc de
        ld a,'"'
        ld (de),a
        inc de
        ld hl,WifiPassword
        call CopyAtEscaped
        ld a,'"'
        ld (de),a
        inc de
        ld a,13
        ld (de),a
        inc de
        ld a,10
        ld (de),a
        inc de
        xor a
        ld (de),a
        ret

; Копировать строку HL в DE для аргумента AT в двойных кавычках. Перед `"` и `\`
; вставляется обратная косая черта, чтобы ESP не завершил аргумент раньше времени.
CopyAtEscaped:
        ld a,(hl)
        or a
        ret z
        cp '"'
        jr z,.escape
        cp #5C
        jr nz,.store
.escape:
        push af
        ld a,#5C
        ld (de),a
        inc de
        pop af
.store:
        ld (de),a
        inc de
        inc hl
        jr CopyAtEscaped

; Копировать нуль-терминированную строку HL -> DE вместе с завершающим нулём.
CopyZ:
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        or a
        jr nz,CopyZ
        ret

; Копировать строку HL -> DE без нуля; DE остаётся на первом свободном байте.
CopyZNoTerm:
        ld a,(hl)
        or a
        ret z
        ld (de),a
        inc hl
        inc de
        jr CopyZNoTerm

; FAT-записи, имена INI-ключей и префиксы AT-команды подключения.
ConfigDirEntry:       db #10,"zifi",0
ConfigFileEntry:      db #00,"zifi.ini",0
KeySsid:              db "SSID:",0
KeyWifiPassword:      db "password:",0
KeyFtpUser:           db "ftp_user:",0
KeyFtpPassword:       db "ftp_password:",0
KeyFtpPort:           db "ftp_port:",0
KeyFtpTimeout:        db "ftp_timeout:",0
CwjapPrefix:          db "AT+CWJAP_CUR=",'"',0
CwjapLegacyPrefix:    db "AT+CWJAP=",'"',0
DefaultFtpUser:       db "zx",0
DefaultFtpPassword:   db "zx",0

; Состояние поиска тома и разобранные параметры конфигурации.
ConfigHaveRoot:       db 0
ConfigDirSeen:        db 0
ConfigPanelDevice:    db 0
ConfigTryDevice:      db 0
ConfigError:          db 0
IniQuoted:            db 0
IniKeyPtr:            dw 0
IniCopyStart:         dw 0
IniLength:            dw 0
FtpPort:              dw 21
FtpTimeout:           dw 600
WifiSsid:             ds 33
WifiPassword:         ds 64
FtpUser:              ds 25
FtpPassword:          ds 33
CmdCwjap:             ds 224             ; готовая экранированная команда CWJAP
IniBuffer:            ds CONFIG_SECTOR_SIZE
