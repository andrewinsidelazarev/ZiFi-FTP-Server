; Настройка ESP8266 через AT, управляющий сокет FTP и разбор потока +IPD.
;
; Модуль связывает три уровня протокола:
;   1. байтовую очередь UART ZiFi (низкий уровень находится в zifi_uart.asm);
;   2. многоканальный TCP интерфейс ESP AT с номерами соединений 0..4;
;   3. управляющий и активный data-каналы FTP.
;
; ESP выдаёт TCP-данные асинхронно в виде +IPD,<id>,<длина>:<данные>, а события
; сокетов — отдельными строками <id>,CONNECT и <id>,CLOSED. Ответы на наши
; AT-команды приходят в тот же UART. Поэтому фоновый разборщик обязан сохранять
; точную границу +IPD и не принимать строки OK/ERROR за данные FTP.
;
; FTP работает только в активном режиме: ESP слушает порт управления, а перед
; LIST/RETR/STOR сам открывает исходящее TCP-соединение к адресу, полученному
; от клиента командой PORT или EPRT.

RX_IDLE       equ 0
RX_I          equ 1
RX_P          equ 2
RX_D          equ 3
RX_COMMA      equ 4
RX_LINK       equ 5
RX_LINK_COMMA equ 6
RX_LENGTH     equ 7
RX_PAYLOAD    equ 8

; Состояния конечного автомата соответствуют символам заголовка:
; Переходы: IDLE -> '+' -> 'I' -> 'P' -> 'D' -> ',' -> link -> ',' -> length -> payload.
; Длина хранится отдельно, поэтому двоичные данные payload могут содержать любые
; байты, включая CR/LF и последовательность "+IPD".

EVENT_BUFFER_SIZE equ 48
AT_BUFFER_SIZE    equ 192

; Полностью подготовить ZiFi и открыть TCP-сервер FTP.
; Последовательность: UART -> отключение echo -> station mode -> CWJAP -> DHCP ->
; CIPMUX -> CIPSERVER -> CIPSTO. Выход: CF=0 — сервер готов; CF=1 — ошибка,
; а NetError содержит код этапа для пользовательского интерфейса.
Net_Start:
        xor a
        ld (NetError),a
        call ZiFi_Init
        jr nc,.zifi_ok
        ld a,1
        ld (NetError),a
        scf
        ret
.zifi_ok:
        ld hl,UiStageWifiSync
        call Ui_SetStatus
        call Ui_Draw
        call ZiFi_ClearRx

        ; ATE0 намеренно повторяется: старая прошивка AT при синхронизации UART
        ; способна отразить первую команду, но не вернуть завершающий OK.
        ld b,3
.echo_retry:
        push bc
        ld hl,CmdAte0
        ld de,40
        call ZiFi_SendWait
        pop bc
        jr z,.echo_ok
        djnz .echo_retry
.echo_ok:
        ld hl,CmdCwmode
        ld de,80
        call ZiFi_SendWait
        jr z,.mode_ok
        ld hl,CmdCwmodeLegacy
        ld de,80
        call ZiFi_SendWait
        jp nz,.wifi_fail
.mode_ok:
        ld hl,CmdAutoconn
        ld de,80
        call ZiFi_SendWait                ; в старых прошивках команда необязательна

        ld hl,UiStageWifiJoin
        call Ui_SetStatus
        call Ui_Draw
        ld hl,CmdQuitAp
        ld de,80
        call ZiFi_SendWait                ; ERROR без текущего соединения безвреден
        ld hl,CmdCwjap
        ld de,1200
        call ZiFi_SendWait
        jr z,.joined
        ; Старая прошивка ESP понимает только вариант CWJAP без суффикса _CUR.
        call Config_BuildCwjapLegacy
        ld hl,CmdCwjap
        ld de,1200
        call ZiFi_SendWait
        jp nz,.wifi_fail
.joined:

        ld hl,UiStageDhcp
        call Ui_SetStatus
        call Ui_Draw
        xor a
        ld (IpRetryCount),a
.ip_retry:
        call Net_QueryIp
        jr nc,.ip_ready
        ld a,(IpRetryCount)
        inc a
        ld (IpRetryCount),a
        cp 8
        jr nc,.ip_fail
        call Net_DhcpPause
        jr .ip_retry
.ip_ready:

        ld hl,UiStageFtp
        call Ui_SetStatus
        call Ui_BuildAddress
        call Ui_Draw
        ld hl,CmdMux
        ld de,100
        call ZiFi_SendWait
        jr nz,.server_fail
        call BuildServerCommand
        ld hl,AtCommand
        ld de,100
        call ZiFi_SendWait
        jr nz,.server_fail
        call BuildTimeoutCommand
        ld hl,AtCommand
        ld de,100
        call ZiFi_SendWait                ; в некоторых старых сборках нет CIPSTO

        call Server_ResetState
        or a
        ret
.wifi_fail:
        ld a,2
        jr .fail
.ip_fail:
        ld a,3
        jr .fail
.server_fail:
        ld a,4
.fail:
        ld (NetError),a
        scf
        ret

; Остановить listener ESP при выходе из плагина. Сброс после CIPSERVER=0 нужен
; старым AT-прошивкам, в которых listener иначе остаётся занятым до перезагрузки.
Net_Stop:
        ld a,(ZifiPresent)
        or a
        ret z
        ld hl,UiStageStopping
        call Ui_SetStatus
        call Ui_Draw
        ld hl,CmdServerOff
        ld de,40
        call ZiFi_SendWait
        ; Ранним версиям ESP AT для настоящего удаления сервера нужна перезагрузка.
        ld hl,CmdReset
        call ZiFi_PutZ
        ret

; Пауза между опросами DHCP. Значение 50 соответствует примерно 1,5 секунды
; на штатной скорости и не зависит от кадровых прерываний Wild Commander.
Net_DhcpPause:
        ld de,50
        call ZiFi_SetTimeout
.wait:
        call ZiFi_CheckTimeout
        jr c,.wait
        ret

; Запросить универсальный AT+CIFSR. Старую команду AT+CIPSTA? не используем:
; на проверенной прошивке ESP AT 1.2.0.0 она способна вообще не ответить.
Net_QueryIp:
        ld hl,CmdCifsr
        jp Net_QueryIpCommand

; HL — команда запроса адреса. Поддерживаются ответы нового вида
; +CIFSR:STAIP,"192.168.1.2" и старого вида 192.168.1.2.
Net_QueryIpCommand:
        xor a
        ld (LocalIp),a
        call ZiFi_PutZ
        jr c,.failed
        ld de,300
        call ZiFi_SetTimeout
.line:
        call ZiFi_ReadLine
        ld a,(ZiFiLine)
        or a
        jr z,.failed
        ld hl,ZiFiLine
        ld de,TokOk
        call Str_Prefix
        jr z,.finish
        ld hl,ZiFiLine
        ld de,TokError
        call Str_Contains
        jr z,.failed
        ld hl,ZiFiLine
        ld de,TokFail
        call Str_Contains
        jr z,.failed
        ld hl,ZiFiLine
        call Net_ParseIpLine
        jr .line
.finish:
        ld hl,LocalIp
        call ValidateIpv4Text
        jr c,.failed
        ld hl,LocalIp
        ld de,TokZeroIp
        call String_Equals
        jr z,.failed
        or a
        ret
.failed:
        scf
        ret

; Разбирать помеченную строку STAIP и голую строку старой прошивки.
; Другие строки с адресами, например STAMAC, намеренно пропускаются.
Net_ParseIpLine:
        push hl
        ld de,TokStaIp
        call Str_Contains
        pop hl
        jr z,Net_ExtractIpv4
.skip:
        ld a,(hl)
        cp ' '
        jr z,.one
        cp 9
        jr z,.one
        cp 13
        jr z,.one
        cp '"'
        jr z,.one
        cp '0'
        jr c,.failed
        cp '9'+1
        jr c,Net_ExtractIpv4
.failed:
        scf
        ret
.one:
        inc hl
        jr .skip

; Найти в строке IPv4 и копировать его в LocalIp только после полной проверки.
; Это не позволяет строке IPv6 или MAC затереть уже найденный адрес станции.
Net_ExtractIpv4:
.scan:
        ld a,(hl)
        or a
        jr z,.failed
        cp '0'
        jr c,.next
        cp '9'+1
        jr c,.candidate
.next:
        inc hl
        jr .scan
.candidate:
        ld (IpScanPointer),hl
        ld de,IpCandidate
        ld b,15
.copy:
        ld a,(hl)
        cp '.'
        jr z,.store
        cp '0'
        jr c,.terminate
        cp '9'+1
        jr nc,.terminate
.store:
        ld (de),a
        inc de
        inc hl
        djnz .copy
        ; После максимально длинного IPv4 цифра или точка означают переполнение.
        ld a,(hl)
        cp '.'
        jr z,.bad_candidate
        cp '0'
        jr c,.terminate
        cp '9'+1
        jr c,.bad_candidate
.terminate:
        xor a
        ld (de),a
        ld hl,IpCandidate
        call ValidateIpv4Text
        jr c,.bad_candidate
        ld hl,IpCandidate
        ld de,TokZeroIp
        call String_Equals
        jr z,.bad_candidate
        ld hl,IpCandidate
        ld de,LocalIp
        call CopyZ
        or a
        ret
.bad_candidate:
        ld hl,(IpScanPointer)
        inc hl
        jr .scan
.failed:
        scf
        ret

; Собрать "AT+CIPSERVER=1,<ftp_port>\r\n" в AtCommand.
BuildServerCommand:
        ld de,AtCommand
        ld hl,CmdServerPrefix
        call CopyZNoTerm
        ld hl,(FtpPort)
        call U16_ToDec
        jp At_EndLine

; Собрать "AT+CIPSTO=<ftp_timeout>\r\n". Тайм-аут относится к серверному
; управляющему сокету ESP и не заменяет программные тайм-ауты UART.
BuildTimeoutCommand:
        ld de,AtCommand
        ld hl,CmdTimeoutPrefix
        call CopyZNoTerm
        ld hl,(FtpTimeout)
        call U16_ToDec
        jp At_EndLine

; Завершить строящуюся AT-команду байтами CR, LF и нулём строки.
; Вход: DE — первый свободный байт AtCommand; выход: строка готова к ZiFi_PutZ.
At_EndLine:
        ld a,13
        ld (de),a
        inc de
        ld a,10
        ld (de),a
        inc de
        xor a
        ld (de),a
        ret

; Сбросить состояние FTP/TCP после успешного запуска listener. Значение #FF
; означает, что соответствующий номер соединения ESP ещё не назначен.
Server_ResetState:
        xor a
        ld (RxState),a
        ld (EventLength),a
        ld (CommandLength),a
        ld (LoggedIn),a
        ld (UserAccepted),a
        ld (DataReady),a
        ld (TransferActive),a
        ld (StoreActive),a
        ld (DataClosed),a
        ld (RenamePending),a
        ld (IpRetryCount),a
        ld a,#FF
        ld (ControlId),a
        ld (DataId),a
        ld hl,CwdPath
        ld (hl),'/'
        inc hl
        ld (hl),0
        xor a
        ld (CwdDepth),a
        ret

; В каждом кадре разобрать все уже накопленные байты UART.
Server_Poll:
.next:
        call Server_ReadOnce
        ret z
        jr .next

; Снять полную копию аппаратной очереди и затем разобрать её из ОЗУ. Копия в ОЗУ
; также не даёт синхронному ответу FTP поглотить байты, шедшие после команды
; в том же пакете +IPD.
Server_ReadOnce:
        ld hl,RxBurstBuffer
        call ZiFi_ReadBurst
        or a
        ret z
        ld l,a
        ld h,0
        ld (BurstRemaining),hl
        ld hl,RxBurstBuffer
        ld (BurstPointer),hl
        call Rx_ProcessBurst
        ld a,1
        or a
        ret

; Разобрать сохранённый блок UART. Обычные заголовки и команды проходят по одному
; байту через Rx_Feed. Payload активного STOR передаётся Store_CopyBurst, чтобы
; копировать большие непрерывные участки командой LDIR, а не циклом по байтам.
Rx_ProcessBurst:
.loop:
        ld hl,(BurstRemaining)
        ld a,h
        or l
        ret z
        ld a,(RxState)
        cp RX_PAYLOAD
        jr nz,.one
        ld a,(StoreActive)
        or a
        jr z,.one
        ld a,(IpdLink)
        ld b,a
        ld a,(DataId)
        cp b
        jr nz,.one
        call Store_CopyBurst
        jr .loop
.one:
        ld hl,(BurstPointer)
        ld a,(hl)
        inc hl
        ld (BurstPointer),hl
        ld hl,(BurstRemaining)
        dec hl
        ld (BurstRemaining),hl
        call Rx_Feed
        jr .loop

; Передать один необработанный байт ESP из A разборщику +IPD и событий.
; На входе A — очередной байт общей UART-последовательности. Автомат распознаёт
; только форму +IPD,<одна цифра 0..4>,<длина>:payload, используемую CIPMUX=1.
; Всё, что не образует корректный заголовок, возвращается строковому Event_Feed.
Rx_Feed:
        ld (RxByte),a
        ld a,(RxState)
        or a
        jr z,.idle
        cp RX_I
        jr z,.want_i
        cp RX_P
        jr z,.want_p
        cp RX_D
        jr z,.want_d
        cp RX_COMMA
        jr z,.want_comma
        cp RX_LINK
        jr z,.read_link
        cp RX_LINK_COMMA
        jr z,.want_link_comma
        cp RX_LENGTH
        jr z,.read_length
        jp Rx_Payload
.idle:
        ld a,(RxByte)
        cp '+'
        jp nz,Event_Feed
        ld a,RX_I
        ld (RxState),a
        ret
.want_i:
        ld a,(RxByte)
        cp 'I'
        jp nz,.restart
        ld a,RX_P
        ld (RxState),a
        ret
.want_p:
        ld a,(RxByte)
        cp 'P'
        jr nz,.restart
        ld a,RX_D
        ld (RxState),a
        ret
.want_d:
        ld a,(RxByte)
        cp 'D'
        jr nz,.restart
        ld a,RX_COMMA
        ld (RxState),a
        ret
.want_comma:
        ld a,(RxByte)
        cp ','
        jr nz,.restart
        ld a,RX_LINK
        ld (RxState),a
        ret
.read_link:
        ld a,(RxByte)
        sub '0'
        cp 5
        jr nc,.restart
        ld (IpdLink),a
        ld a,RX_LINK_COMMA
        ld (RxState),a
        ret
.want_link_comma:
        ld a,(RxByte)
        cp ','
        jr nz,.restart
        ld hl,0
        ld (IpdRemaining),hl
        ld a,RX_LENGTH
        ld (RxState),a
        ret
.read_length:
        ld a,(RxByte)
        cp ':'
        jr z,.payload_start
        cp '0'
        jr c,.restart
        cp '9'+1
        jr nc,.restart
        sub '0'
        ld c,a
        ; Десятичное накопление длины: новое = старое * 10 + цифра.
        ld hl,(IpdRemaining)
        add hl,hl
        ld de,hl
        add hl,hl
        add hl,hl
        add hl,de
        ld e,c
        ld d,0
        add hl,de
        ld (IpdRemaining),hl
        ret
.payload_start:
        ld hl,(IpdRemaining)
        ld a,h
        or l
        jr z,.restart
        ld a,RX_PAYLOAD
        ld (RxState),a
        ret
.restart:
        ; Ложное начало +IPD не теряем: текущий байт может быть частью обычной
        ; строки ESP, поэтому передаём его накопителю CONNECT/CLOSED.
        xor a
        ld (RxState),a
        ld a,(RxByte)
        jp Event_Feed

Rx_Payload:
        ; Учесть байт до его передачи обработчику. Полная команда FTP может
        ; синхронно отправить команды AT, поэтому разборщик уже не должен считать,
        ; что байты ответа AT относятся к прежнему блоку +IPD.
        ld hl,(IpdRemaining)
        dec hl
        ld (IpdRemaining),hl
        ld a,h
        or l
        jr nz,.state_kept
        xor a
        ld (RxState),a
.state_kept:
        ld a,(IpdLink)
        ld b,a
        ld a,(ControlId)
        cp b
        jr z,.control
        ld a,(DataId)
        cp b
        ret nz
        ld a,(StoreActive)
        or a
        ret z
        ld a,(RxByte)
        jp Store_PutByte
.control:
        ld a,(RxByte)
        jp Command_Feed

; Строки ESP вне +IPD накапливаются для событий <id>,CONNECT и <id>,CLOSED.
; Ответы OK/ERROR здесь тоже могут проходить, но Event_Handle отбрасывает строки,
; не начинающиеся с допустимого номера соединения и запятой.
Event_Feed:
        ld c,a
        ld a,(EventLength)
        cp EVENT_BUFFER_SIZE-1
        jr nc,.reset
        ld e,a
        ld d,0
        ld hl,EventBuffer
        add hl,de
        ld (hl),c
        inc a
        ld (EventLength),a
        ld a,c
        cp 10
        ret nz
        xor a
        ld (hl),a
        call Event_Handle
.reset:
        xor a
        ld (EventLength),a
        ret

; Применить асинхронное событие сокета ESP.
; Первый CONNECT становится управляющим FTP-каналом и получает приветствие 220.
; CONNECT с номером ожидаемого DataId подтверждает активный data-канал. Любой
; лишний клиент получает 421 и закрывается, не нарушая текущую передачу.
Event_Handle:
        ld a,(EventBuffer)
        sub '0'
        cp 5
        ret nc
        ld (EventLink),a
        ld a,(EventBuffer+1)
        cp ','
        ret nz
        ld hl,EventBuffer+2
        ld de,TokClosed
        call Str_Contains
        jr z,.closed
        ld hl,EventBuffer+2
        ld de,TokConnect
        call Str_Contains
        ret nz
        ld a,(ControlId)
        cp #FF
        jr z,.accept_event
        ld b,a
        ld a,(EventLink)
        cp b
        ; После потерянного CLOSED ESP может выдать новому сокету тот же номер.
        jr z,.accept_event
        ld b,a
        ld a,(DataId)
        cp b
        jr z,.data_connect

        ; Сервер однопользовательский. Лишний control-канал не должен
        ; вытеснять текущую сессию во время пакетного скачивания.
        ld a,(EventLink)
        push af
        ld hl,Reply421Busy
        ld bc,Reply421BusyLen
        call Net_Send
        pop af
        jp Link_Close
.accept_event:
        ld a,(EventLink)
        ld (ControlId),a
        xor a
        ld (LoggedIn),a
        ld (UserAccepted),a
        ld (RenamePending),a
        ld (CommandLength),a
        ld (DataReady),a
        call Fs_ResetRoot
        ld hl,UiClientConnected
        call Ui_SetClient
        call Ui_Draw
        ld hl,Reply220
        ld bc,Reply220Len
        call Control_Send
        ret
.data_connect:
        ld a,1
        ld (DataConnected),a
        ret
.closed:
        ld a,(EventLink)
        ld b,a
        ld a,(ControlId)
        cp b
        jr nz,.data_closed
        call Data_Close
        jp Control_Forget
.data_closed:
        ld a,(DataId)
        cp b
        ret nz
        ld a,1
        ld (DataClosed),a
        xor a
        ld (DataConnected),a
        ret

; Учесть CLOSED, прочитанный синхронным ожиданием ответа AT. Без этого строка
; исчезает до фонового разборщика, и следующий FTP-клиент остаётся без 220.
; Эта функция вызывается ZiFi_WaitOk/ZiFi_WaitSendOk для каждой принятой строки,
; потому что синхронное ожидание и Server_Poll читают одну физическую очередь.
Net_ObserveWaitLine:
        ld a,(ZiFiLine)
        sub '0'
        cp 5
        ret nc
        ld (EventLink),a
        ld a,(ZiFiLine+1)
        cp ','
        ret nz
        ld hl,ZiFiLine+2
        ld de,TokClosed
        call Str_Contains
        ret nz
        ld a,(EventLink)
        ld b,a
        ld a,(ControlId)
        cp b
        jr nz,.data_closed
        jp Control_Forget
.data_closed:
        ld a,(DataId)
        cp b
        ret nz
        ld a,1
        ld (DataClosed),a
        xor a
        ld (DataConnected),a
        ret

; Закрыть произвольный канал ESP командой AT+CIPCLOSE=<id>.
; Вход: A — номер соединения 0..4 либо #FF; #FF означает «канала нет».
Link_Close:
        cp #FF
        ret z
        ld (CloseLinkId),a
        ld de,AtCommand
        ld hl,CmdClosePrefix
        call CopyZNoTerm
        ld a,(CloseLinkId)
        add a,'0'
        ld (de),a
        inc de
        call At_EndLine
        ld hl,AtCommand
        ld de,80
        call ZiFi_SendWait
        ret

; Закрыть управляющий TCP-канал и немедленно освободить сервер для нового входа.
Control_Close:
        ld a,(ControlId)
        call Link_Close
        jp Control_Forget

; Забыть закрытый либо неисправный управляющий канал и подготовить новый вход.
Control_Forget:
        ld a,#FF
        ld (ControlId),a
        ld (DataId),a
        xor a
        ld (LoggedIn),a
        ld (UserAccepted),a
        ld (RenamePending),a
        ld (CommandLength),a
        ld (DataReady),a
        ld (DataConnected),a
        ld (TransferActive),a
        ld (StoreActive),a
        inc a
        ld (DataClosed),a
        ld hl,UiClientNone
        call Ui_SetClient
        jp Ui_Draw

; Отправить один блок TCP управляющего канала или данных через AT+CIPSEND.
; Вход: A — номер соединения, HL — данные, BC — длина.
; Выход: CF=0 — ESP подтвердил SEND OK; CF=1 — ошибка/тайм-аут.
;
; Обмен состоит из двух фаз:
;   1. AT+CIPSEND=<id>,<len> и ожидание одиночного приглашения '>';
;   2. ровно <len> двоичных байтов и ожидание строки SEND OK.
; Между фазами нельзя добавлять CR/LF: они стали бы частью TCP payload.
Net_Send:
        ld (SendLink),a
        ld (SendPointer),hl
        ld (SendLength),bc
        call BuildSendCommand
        ld hl,AtCommand
        call ZiFi_PutZ
        jr c,.failed
        ld de,200
        call ZiFi_SetTimeout
        call ZiFi_WaitPrompt
        jr nz,.failed
        ld hl,(SendPointer)
        ld bc,(SendLength)
        call ZiFi_PutBlock
        jr c,.failed
        ld de,300
        call ZiFi_SetTimeout
        call ZiFi_WaitSendOk
        jr nz,.failed
        or a
        ret
.failed:
        scf
        ret

; Собрать "AT+CIPSEND=<SendLink>,<SendLength>\r\n" в AtCommand.
BuildSendCommand:
        ld de,AtCommand
        ld hl,CmdSendPrefix
        call CopyZNoTerm
        ld a,(SendLink)
        add a,'0'
        ld (de),a
        inc de
        ld a,','
        ld (de),a
        inc de
        ld hl,(SendLength)
        call U16_ToDec
        jp At_EndLine

; Отправить FTP-ответ по текущему управляющему каналу. При ошибке канал считается
; потерянным: состояние сессии очищается, чтобы следующий CONNECT получил 220.
Control_Send:
        ld a,(ControlId)
        cp #FF
        jr z,.failed
        call Net_Send
        ret nc
        ; Ошибка отправки обычно означает уже закрытый TCP-канал.
        call Control_Forget
.failed:
        scf
        ret

; Отправить блок LIST/RETR по открытому data-каналу активного режима.
Data_Send:
        ld a,(DataId)
        cp #FF
        jr z,.failed
        jp Net_Send
.failed:
        scf
        ret

; Открыть сохранённую командой PORT/EPRT конечную точку активного режима.
; ESP работает в CIPMUX=1, поэтому каждому сокету нужен id 0..4. Для data-канала
; обычно берётся 4; если control уже занял 4, используется 3. BuildOpenCommand
; создаёт исходящее TCP-подключение к компьютеру-клиенту.
; Выход: CF=0 — ESP вернул OK; CF=1 — конечная точка отсутствует или недоступна.
Data_Open:
        ld a,(DataReady)
        or a
        jr z,.failed
        ld a,4
        ld b,a
        ld a,(ControlId)
        cp b
        jr nz,.id_ok
        ld b,3
.id_ok:
        ld a,b
        ld (DataId),a
        xor a
        ld (DataConnected),a
        ld (DataClosed),a
        call BuildOpenCommand
        ld hl,AtCommand
        ld de,1000
        call ZiFi_SendWait
        jr nz,.failed
        ld a,1
        ld (DataConnected),a
        or a
        ret
.failed:
        scf
        ret

; Собрать команду вида:
; Формат: AT+CIPSTART=<DataId>,"TCP","<DataIp>",<DataPort>\r\n
; Адрес и порт ранее строго проверены обработчиками PORT/EPRT.
BuildOpenCommand:
        ld de,AtCommand
        ld hl,CmdOpenPrefix
        call CopyZNoTerm
        ld a,(DataId)
        add a,'0'
        ld (de),a
        inc de
        ld hl,CmdOpenMiddle
        call CopyZNoTerm
        ld hl,DataIp
        call CopyZNoTerm
        ld hl,CmdOpenPort
        call CopyZNoTerm
        ld hl,(DataPort)
        call U16_ToDec
        jp At_EndLine

; Закрыть data-канал после одной операции и погасить DataReady. По FTP клиент
; обязан прислать новый PORT/EPRT перед следующей передачей, поэтому повторное
; использование старой конечной точки намеренно запрещено.
Data_Close:
        ld a,(DataId)
        cp #FF
        ret z
        ld de,AtCommand
        ld hl,CmdClosePrefix
        call CopyZNoTerm
        ld a,(DataId)
        add a,'0'
        ld (de),a
        inc de
        call At_EndLine
        ld hl,AtCommand
        ld de,80
        call ZiFi_SendWait
        ld a,1
        ld (DataClosed),a
        ld a,#FF
        ld (DataId),a
        xor a
        ld (DataReady),a
        ld (DataConnected),a
        ret

; Постоянные AT-команд. Все готовые команды заканчиваются CR/LF и нулём;
; префиксы дополняются параметрами в AtCommand и завершаются At_EndLine.
CmdAte0:          db "ATE0",13,10,0              ; не отражать команды обратно в UART
CmdCwmode:        db "AT+CWMODE_DEF=1",13,10,0   ; station mode с записью в flash
CmdCwmodeLegacy:  db "AT+CWMODE=1",13,10,0       ; совместимость со старой AT
CmdAutoconn:      db "AT+CWAUTOCONN=0",13,10,0   ; не подключаться к старой сети
CmdQuitAp:        db "AT+CWQAP",13,10,0           ; разорвать текущее Wi-Fi-соединение
CmdCifsr:         db "AT+CIFSR",13,10,0           ; прочитать адрес станции после DHCP
CmdMux:           db "AT+CIPMUX=1",13,10,0        ; несколько TCP-сокетов с id 0..4
CmdServerPrefix:  db "AT+CIPSERVER=1,",0          ; открыть listener на FTP-порту
CmdTimeoutPrefix: db "AT+CIPSTO=",0               ; тайм-аут неактивного TCP-сервера
CmdServerOff:     db "AT+CIPSERVER=0",13,10,0     ; закрыть listener
CmdReset:         db "AT+RST",13,10,0             ; окончательно очистить старый listener
CmdSendPrefix:    db "AT+CIPSEND=",0              ; объявить длину исходящего TCP-блока
CmdOpenPrefix:    db "AT+CIPSTART=",0             ; открыть исходящий data-сокет
CmdOpenMiddle:    db ",",'"',"TCP",'"',",",'"',0
CmdOpenPort:      db '"',",",0
CmdClosePrefix:   db "AT+CIPCLOSE=",0             ; закрыть сокет по номеру
TokStaIp:         db "STAIP",0
TokClosed:        db "CLOSED",0
TokZeroIp:        db "0.0.0.0",0

; Состояние сетевого уровня. Буферы строк содержат ASCII и завершающий ноль.
NetError:         db 0                    ; 0=нет, 1=ZiFi, 2=Wi-Fi, 3=DHCP, 4=server
IpRetryCount:     db 0
ControlId:        db #FF                  ; id входящего управляющего TCP-сокета
DataId:           db #FF                  ; id исходящего активного data-сокета
DataConnected:    db 0
DataClosed:       db 0
DataReady:        db 0                    ; PORT/EPRT уже задал DataIp и DataPort
CloseLinkId:      db #FF
DataIp:           ds 16
DataPort:         dw 0
LocalIp:          ds 16
IpCandidate:      ds 16
IpScanPointer:    dw 0

; Состояние потокового автомата +IPD и сохранённого burst из UART.
RxState:          db 0
RxByte:           db 0
IpdLink:          db 0
IpdRemaining:     dw 0                    ; точное число ещё не разобранных payload-байтов
EventLink:        db 0
EventLength:      db 0
EventBuffer:      ds EVENT_BUFFER_SIZE
BurstPointer:     dw 0
BurstRemaining:   dw 0
RxBurstBuffer:    ds #BF                  ; максимум, безопасный для счётчика INIR

; Параметры текущей синхронной операции AT+CIPSEND.
SendLink:         db 0
SendPointer:      dw 0
SendLength:       dw 0
AtCommand:        ds AT_BUFFER_SIZE
