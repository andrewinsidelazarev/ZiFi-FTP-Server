; Обмен с UART ZiFi в TS-Config.
; Постоянный порт данных #BFEF выбран намеренно: здесь нельзя применять OUTI,
; потому что меняющийся старший байт адреса способен задеть другие устройства
; с неполной дешифрацией портов.
;
; ZiFi предоставляет не классический 16550 UART, а аппаратные очереди:
; ZIFI_RX_COUNT сообщает число принятых байтов, ZIFI_TX_FREE — свободное место
; очереди передачи, ZIFI_DR читает/пишет данные, ZIFI_CR управляет очередями и
; возвращает версию API. Сетевой модуль поверх этих примитивов обменивается
; текстовыми AT-командами и двоичными TCP payload без преобразования кодировки.

ZIFI_CR        equ #C7EF                 ; управление очередями и версия API
ZIFI_DR        equ #BFEF                 ; байт данных RX/TX
ZIFI_RX_COUNT  equ #C0EF                 ; число доступных байтов приёма
ZIFI_TX_FREE   equ #C1EF                 ; число свободных байтов передачи

ZIFI_LINE_SIZE equ 192

; Обнаружить ZiFi, включить режим API 1 и очистить очередь приёма.
; Выход: CF=0 — устройство найдено, CF=1 — устройство отсутствует.
ZiFi_Init:
        ld bc,ZIFI_CR
        ld a,#F1
        out (c),a
        ld a,#FF
        out (c),a
        ld de,0
.wait_version:
        in a,(c)
        cp #FF
        jr nz,.present
        dec de
        ld a,d
        or e
        jr nz,.wait_version
        xor a
        ld (ZifiPresent),a
        scf
        ret
.present:
        ld (ZifiVersion),a
        ld a,1
        ld (ZifiPresent),a
        call ZiFi_ClearRx
        or a
        ret

; Команда 1 управляющего регистра атомарно очищает очередь ESP -> Z80.
ZiFi_ClearRx:
        ld bc,ZIFI_CR
        ld a,1
        out (c),a
        ret

; Команда 2 очищает очередь Z80 -> ESP. В штатном запуске не требуется, но
; оставлена как безопасный примитив восстановления после оборванной команды.
ZiFi_ClearTx:
        ld bc,ZIFI_CR
        ld a,2
        out (c),a
        ret

; DE задаёт величину тайм-аута. Программный предел равен DE << 11 опросов.
; Счётчик трёхбайтовый и не зависит от прерываний/частоты кадров WC: вызывающая
; сторона уменьшает его только в циклах ожидания UART.
ZiFi_SetTimeout:
        ld (ZiFiTimeout),de
        xor a
        ld (ZiFiTimeout+2),a
        ld b,11
.shift:
        ld hl,(ZiFiTimeout)
        add hl,hl
        ld (ZiFiTimeout),hl
        ld a,(ZiFiTimeout+2)
        adc a,a
        ld (ZiFiTimeout+2),a
        djnz .shift
        ret

; Уменьшить программный счётчик на один опрос.
; Выход: CF=1 — время осталось, CF=0 — тайм-аут истёк. HL сохраняется, чтобы
; функцию можно было вставлять в циклы разбора без потери указателя буфера.
ZiFi_CheckTimeout:
        push hl
        ld hl,(ZiFiTimeout)
        ld a,h
        or l
        jr nz,.dec_low
        ld a,(ZiFiTimeout+2)
        or a
        jr z,.expired
        dec a
        ld (ZiFiTimeout+2),a
.dec_low:
        dec hl
        ld (ZiFiTimeout),hl
        pop hl
        scf
        ret
.expired:
        pop hl
        or a
        ret

; Неблокирующее чтение одного байта.
; Выход: CF=1 и A=байт либо CF=0, если очередь пуста. Такое соглашение позволяет
; отличить принятый нулевой байт TCP от отсутствия данных.
ZiFi_GetChar:
        ld bc,ZIFI_RX_COUNT
        in a,(c)
        or a
        ret z
        ld bc,ZIFI_DR
        in a,(c)
        scf
        ret

; HL — приёмник. Прочитать через INIR все байты, находящиеся сейчас в очереди.
; В TS-Config все старшие байты порта ниже #C0 выбирают очередь данных ZiFi,
; поэтому B одновременно служит безопасным счётчиком INIR.
; Выход: A — число байтов от 0 до #BF.
; Ограничение #BF принципиально: при B=#C0 старший байт следующего INIR уже
; совпал бы с портом счётчика, а при B=0 Z80 прочитал бы 256 байтов.
ZiFi_ReadBurst:
        push bc
        ld bc,ZIFI_RX_COUNT
        in a,(c)
        or a
        jr z,.empty
        cp #C0
        jr c,.count_ok
        ld a,#BF
.count_ok:
        ld (ZiFiBurstCount),a
        ld b,a
        ld c,#EF
        inir
        ld a,(ZiFiBurstCount)
        pop bc
        or a
        ret
.empty:
        pop bc
        xor a
        ret

; Блокирующая запись одного байта в очередь ESP.
; Вход: A — байт. Выход: CF=0 — отправлен, CF=1 — аппаратная очередь так и не
; освободилась. BC/DE сохраняются; исходный A извлекается только после ожидания.
ZiFi_PutChar:
        push bc
        push de
        push af
        ld de,0
.wait:
        ld bc,ZIFI_TX_FREE
        in a,(c)
        or a
        jr nz,.space
        dec de
        ld a,d
        or e
        jr nz,.wait
        pop af
        pop de
        pop bc
        scf
        ret
.space:
        pop af
        ld bc,ZIFI_DR
        out (c),a
        pop de
        pop bc
        or a
        ret

; Передать нуль-терминированную AT-строку без самого нулевого байта.
; Вход: HL — строка; выход: CF=1 при тайм-ауте любого символа.
ZiFi_PutZ:
        ld a,(hl)
        or a
        ret z
        push hl
        call ZiFi_PutChar
        pop hl
        ret c
        inc hl
        jr ZiFi_PutZ

; Передать ровно BC байтов, включая возможные нули и CR/LF. Используется после
; приглашения CIPSEND для двоичного TCP payload. Выход: CF=1 при тайм-ауте.
ZiFi_PutBlock:
        ld a,b
        or c
        ret z
.loop:
        ld a,(hl)
        call ZiFi_PutChar
        ret c
        inc hl
        dec bc
        ld a,b
        or c
        jr nz,.loop
        or a
        ret

; Прочитать одну строку AT до CR/LF. LF отбрасывается, CR сохраняется.
; Вызывающая сторона должна заранее запустить ZiFiTimeout. При тайм-ауте
; возвращается неполная строка.
; Буфер всегда завершается нулём. Сохранённый CR не мешает проверке префиксов
; OK/ERROR и позволяет не объединять соседние ответы старых прошивок.
ZiFi_ReadLine:
        ld hl,ZiFiLine
.loop:
        call ZiFi_GetChar
        jr nc,.idle
        cp 10
        jr z,.done
        ld (hl),a
        inc hl
        ld a,h
        cp high (ZiFiLine+ZIFI_LINE_SIZE-1)
        jr c,.loop
        jr nz,.done
        ld a,l
        cp low (ZiFiLine+ZIFI_LINE_SIZE-1)
        jr c,.loop
.done:
        xor a
        ld (hl),a
        ret
.idle:
        call ZiFi_CheckTimeout
        jr c,.loop
        xor a
        ld (hl),a
        ret

; DE — искомая строка, HL — исходная строка. Z, если искомая строка — префикс.
Str_Prefix:
.loop:
        ld a,(de)
        or a
        ret z
        ld b,a
        ld a,(hl)
        cp b
        ret nz
        inc de
        inc hl
        jr .loop

; DE — искомая строка, HL — исходная строка. Z, если найдено вхождение.
Str_Contains:
        ld (NeedlePtr),de
.next:
        ld a,(hl)
        or a
        jr z,.no
        push hl
        ld de,(NeedlePtr)
        call Str_Prefix
        pop hl
        ret z
        inc hl
        jr .next
.no:
        or 1
        ret

; Дождаться завершающего OK. Строки WIFI CONNECTED/WIFI GOT IP являются лишь
; промежуточными уведомлениями CWJAP и не завершают команду.
; Каждая строка также передаётся Net_ObserveWaitLine: ESP может прислать CLOSED
; одновременно с ответом на AT-команду. Выход: Z — успех, NZ — ошибка/тайм-аут.
ZiFi_WaitOk:
        call ZiFi_ReadLine
        ld a,(ZiFiLine)
        or a
        jr z,.timeout
        call Net_ObserveWaitLine
        ld hl,ZiFiLine
        ld de,TokError
        call Str_Contains
        jr z,.failed
        ld hl,ZiFiLine
        ld de,TokFail
        call Str_Contains
        jr z,.failed
        ld hl,ZiFiLine
        ld de,TokOk
        call Str_Prefix
        ret z
        jr ZiFi_WaitOk
.timeout:
        ld a,1
        or a
        ret
.failed:
        ld a,2
        or a
        ret

; Синхронно выполнить простую AT-команду: отправить строку из HL, запустить
; тайм-аут DE и читать строки до OK/ERROR/FAIL. Выход: Z — успех.
ZiFi_SendWait:
        push de
        call ZiFi_PutZ
        pop de
        jr c,.txfail
        call ZiFi_SetTimeout
        jp ZiFi_WaitOk
.txfail:
        ld a,3
        or a
        ret

; Дождаться необрамлённого приглашения '>' от CIPSEND.
; В отличие от OK, этот символ не окружён CR/LF, поэтому ZiFi_ReadLine здесь
; неприменим: он дождался бы тайм-аута и мог поглотить начало TCP-ответа.
; Выход: Z — приглашение получено, NZ — ошибка или тайм-аут.
ZiFi_WaitPrompt:
.loop:
        call ZiFi_GetChar
        jr nc,.idle
        cp '>'
        ret z
        jr .loop
.idle:
        call ZiFi_CheckTimeout
        jr c,.loop
        ld a,1
        or a
        ret

; После блока данных дождаться SEND OK или ERROR. Промежуточные уведомления
; сокетов пропускаются, но CLOSED фиксируется через Net_ObserveWaitLine.
ZiFi_WaitSendOk:
        call ZiFi_ReadLine
        ld a,(ZiFiLine)
        or a
        jr z,.timeout
        call Net_ObserveWaitLine
        ld hl,ZiFiLine
        ld de,TokSendOk
        call Str_Prefix
        ret z
        ld hl,ZiFiLine
        ld de,TokError
        call Str_Contains
        jr z,.timeout
        jr ZiFi_WaitSendOk
.timeout:
        ld a,1
        or a
        ret

; Лексемы завершения AT-команд. Сравнение выполняется по ASCII-префиксу либо
; поиском в строке, поэтому сохранённый завершающий CR не требуется удалять.
TokOk:          db "OK",0
TokError:       db "ERROR",0
TokFail:        db "FAIL",0
TokConnect:     db "CONNECT",0
TokSendOk:      db "SEND OK",0

; Состояние аппаратного транспортного уровня.
ZifiPresent:    db 0                    ; 1 после успешного чтения версии API
ZifiVersion:    db 0                    ; значение, возвращённое ZIFI_CR
ZiFiBurstCount: db 0
ZiFiTimeout:    ds 3                    ; 24-битный программный счётчик ожидания
NeedlePtr:      dw 0
ZiFiLine:       ds ZIFI_LINE_SIZE       ; текущая строка ESP, всегда с нулём
