; Разбор команд FTP и операции FAT через встроенный драйвер Wild Commander.
; Доступный клиенту корень хранится в потоке 1, поток 0 содержит текущий каталог.
;
; Управляющий TCP payload поступает сюда из автомата +IPD по одному байту.
; Команда собирается до LF, делится на имя и аргумент, затем диспетчер формирует
; числовой FTP-ответ. Объёмные данные LIST/RETR/STOR никогда не смешиваются с
; управляющим каналом: для каждой операции открывается отдельный активный сокет.
;
; FAT API Wild Commander использует записи вида <флаг><имя,0>. Флаг #00 означает
; обычный файл, #10 — каталог. Два потока WC позволяют держать корень песочницы
; и текущий каталог независимо от панели, из которой был запущен плагин.

FTP_COMMAND_SIZE equ 256
FTP_NAME_SIZE    equ 256
FTP_LIST_SIZE    equ 352

; Страница 0 занята кодом плагина. Следующие 16 страниц по 16 КиБ образуют склад
; входящего STOR: 16 * 16384 = 262144 байта.
UPLOAD_FIRST_PAGE equ 1
UPLOAD_PAGE_COUNT equ 16

; ---------------------------------------------------------------------------
; Приём и разбор команд управляющего канала
; ---------------------------------------------------------------------------

; Принять байт управляющего FTP-канала в A. CR игнорируется, LF завершает строку.
; Переполненная команда безопасно обрезается до 255 байтов и остаётся завершённой
; нулём перед разбором.
Command_Feed:
        cp 13
        ret z
        cp 10
        jr z,.complete
        ld c,a
        ld a,(CommandLength)
        cp FTP_COMMAND_SIZE-1
        ret nc
        ld e,a
        ld d,0
        ld hl,CommandBuffer
        add hl,de
        ld (hl),c
        inc a
        ld (CommandLength),a
        ret
.complete:
        ld a,(CommandLength)
        or a
        ret z
        ld e,a
        ld d,0
        ld hl,CommandBuffer
        add hl,de
        xor a
        ld (hl),a
        ld (CommandLength),a
        jp Ftp_HandleCommand

; Разобрать завершённую команду и вызвать обработчик. USER/PASS и служебные
; команды доступны до входа; файловые операции проходят только при LoggedIn=1.
; Сравнение имени команды регистронезависимое благодаря нормализации в верхний
; регистр внутри Ftp_ParseCommand.
Ftp_HandleCommand:
        ld hl,CommandBuffer
        call Ui_SetLast
        call Ui_Draw
        call Ftp_ParseCommand

        ld de,FtpUSER
        call Ftp_CommandEquals
        jp z,Cmd_USER
        ld de,FtpPASS
        call Ftp_CommandEquals
        jp z,Cmd_PASS
        ld de,FtpQUIT
        call Ftp_CommandEquals
        jp z,Cmd_QUIT
        ld de,FtpSYST
        call Ftp_CommandEquals
        jp z,Cmd_SYST
        ld de,FtpFEAT
        call Ftp_CommandEquals
        jp z,Cmd_FEAT
        ld de,FtpNOOP
        call Ftp_CommandEquals
        jp z,Cmd_NOOP

        ld a,(LoggedIn)
        or a
        jp z,Reply_NotLoggedIn

        ld de,FtpPWD
        call Ftp_CommandEquals
        jp z,Cmd_PWD
        ld de,FtpXPWD
        call Ftp_CommandEquals
        jp z,Cmd_PWD
        ld de,FtpCWD
        call Ftp_CommandEquals
        jp z,Cmd_CWD
        ld de,FtpXCWD
        call Ftp_CommandEquals
        jp z,Cmd_CWD
        ld de,FtpCDUP
        call Ftp_CommandEquals
        jp z,Cmd_CDUP
        ld de,FtpTYPE
        call Ftp_CommandEquals
        jp z,Cmd_TYPE
        ld de,FtpPORT
        call Ftp_CommandEquals
        jp z,Cmd_PORT
        ld de,FtpEPRT
        call Ftp_CommandEquals
        jp z,Cmd_EPRT
        ld de,FtpPASV
        call Ftp_CommandEquals
        jp z,Cmd_PASV
        ld de,FtpEPSV
        call Ftp_CommandEquals
        jp z,Cmd_PASV
        ld de,FtpLIST
        call Ftp_CommandEquals
        jp z,Cmd_LIST
        ld de,FtpNLST
        call Ftp_CommandEquals
        jp z,Cmd_NLST
        ld de,FtpRETR
        call Ftp_CommandEquals
        jp z,Cmd_RETR
        ld de,FtpSTOR
        call Ftp_CommandEquals
        jp z,Cmd_STOR
        ld de,FtpSIZE
        call Ftp_CommandEquals
        jp z,Cmd_SIZE
        ld de,FtpMDTM
        call Ftp_CommandEquals
        jp z,Cmd_MDTM
        ld de,FtpDELE
        call Ftp_CommandEquals
        jp z,Cmd_DELE
        ld de,FtpMKD
        call Ftp_CommandEquals
        jp z,Cmd_MKD
        ld de,FtpXMKD
        call Ftp_CommandEquals
        jp z,Cmd_MKD
        ld de,FtpRMD
        call Ftp_CommandEquals
        jp z,Cmd_RMD
        ld de,FtpXRMD
        call Ftp_CommandEquals
        jp z,Cmd_RMD
        ld de,FtpRNFR
        call Ftp_CommandEquals
        jp z,Cmd_RNFR
        ld de,FtpRNTO
        call Ftp_CommandEquals
        jp z,Cmd_RNTO
        ld de,FtpOPTS
        call Ftp_CommandEquals
        jp z,Cmd_OK
        ld de,FtpCLNT
        call Ftp_CommandEquals
        jp z,Cmd_OK
        ld de,FtpMODE
        call Ftp_CommandEquals
        jp z,Cmd_OK
        ld de,FtpSTRU
        call Ftp_CommandEquals
        jp z,Cmd_OK
        ld de,FtpSTAT
        call Ftp_CommandEquals
        jp z,Cmd_STAT
        ld de,FtpABOR
        call Ftp_CommandEquals
        jp z,Cmd_ABOR
        ld de,FtpREST
        call Ftp_CommandEquals
        jp z,Cmd_REST
        ld de,FtpMLSD
        call Ftp_CommandEquals
        jp z,Cmd_MLSD
        ld de,FtpMLST
        call Ftp_CommandEquals
        jp z,Cmd_MLSD
        jp Reply_NotImplemented

; Разделить CommandBuffer на CommandName (до 8 символов) и CommandArgument
; (до 255 символов). Начальные и разделяющие пробелы/табуляции пропускаются,
; аргумент копируется без изменения регистра — имена файлов должны сохраниться.
Ftp_ParseCommand:
        ld hl,CommandBuffer
.skip_leading:
        ld a,(hl)
        cp ' '
        jr z,.lead_one
        cp 9
        jr nz,.command
.lead_one:
        inc hl
        jr .skip_leading
.command:
        ld de,CommandName
        ld b,8
.command_loop:
        ld a,(hl)
        or a
        jr z,.command_done
        cp ' '
        jr z,.command_done
        cp 9
        jr z,.command_done
        cp 'a'
        jr c,.command_store
        cp 'z'+1
        jr nc,.command_store
        sub 32
.command_store:
        ld (de),a
        inc de
        inc hl
        djnz .command_loop
.skip_command_tail:
        ld a,(hl)
        or a
        jr z,.command_done
        cp ' '
        jr z,.command_done
        cp 9
        jr z,.command_done
        inc hl
        jr .skip_command_tail
.command_done:
        xor a
        ld (de),a
.skip_gap:
        ld a,(hl)
        cp ' '
        jr z,.gap_one
        cp 9
        jr nz,.copy_arg
.gap_one:
        inc hl
        jr .skip_gap
.copy_arg:
        ld de,CommandArgument
        ld bc,FTP_NAME_SIZE-1
.arg_loop:
        ld a,(hl)
        or a
        jr z,.arg_done
        ld (de),a
        inc hl
        inc de
        dec bc
        ld a,b
        or c
        jr nz,.arg_loop
.arg_done:
        xor a
        ld (de),a
        ret

Ftp_CommandEquals:
        ld hl,CommandName
String_Equals:
.loop:
        ld a,(de)
        cp (hl)
        ret nz
        or a
        ret z
        inc de
        inc hl
        jr .loop

; Все ответы FTP уходят только по control-каналу. Вход: HL — байты, BC — длина.
Reply_Send:
        jp Control_Send

Reply_NotLoggedIn:
        ld hl,Reply530
        ld bc,Reply530Len
        jp Reply_Send

Reply_NotImplemented:
        ld hl,Reply502
        ld bc,Reply502Len
        jp Reply_Send

; USER начинает новую попытку входа и одновременно сбрасывает текущий путь в `/`.
; Пароль проверяется только после точного совпадения имени пользователя.
Cmd_USER:
        ld hl,CommandArgument
        ld de,FtpUser
        call String_Equals
        jr nz,.bad
        ld a,1
        ld (UserAccepted),a
        xor a
        ld (LoggedIn),a
        ld (RenamePending),a
        call Fs_ResetRoot
        ld hl,Reply331
        ld bc,Reply331Len
        jp Reply_Send
.bad:
        xor a
        ld (UserAccepted),a
        ld (LoggedIn),a
        ld hl,Reply530User
        ld bc,Reply530UserLen
        jp Reply_Send

; PASS завершает простую аутентификацию открытым текстом. FTP/TCP не шифруются,
; поэтому эти учётные данные допустимы только в доверенной локальной сети.
Cmd_PASS:
        ld a,(UserAccepted)
        or a
        jr z,Reply_NotLoggedIn
        ld hl,CommandArgument
        ld de,FtpPassword
        call String_Equals
        jr nz,.bad
        ld a,1
        ld (LoggedIn),a
        ld hl,UiClientLogged
        call Ui_SetClient
        call Ui_Draw
        ld hl,Reply230
        ld bc,Reply230Len
        jp Reply_Send
.bad:
        xor a
        ld (LoggedIn),a
        ld hl,Reply530Pass
        ld bc,Reply530PassLen
        jp Reply_Send

; Сначала передать 221, затем закрыть сокет ESP и освободить однопользовательский
; listener для следующего клиента.
Cmd_QUIT:
        ld hl,Reply221
        ld bc,Reply221Len
        call Reply_Send
        jp Control_Close

Cmd_SYST:
        ld hl,Reply215
        ld bc,Reply215Len
        jp Reply_Send

Cmd_FEAT:
        ld hl,Reply211Features
        ld bc,Reply211FeaturesLen
        jp Reply_Send

Cmd_NOOP:
Cmd_OK:
        ld hl,Reply200
        ld bc,Reply200Len
        jp Reply_Send

Cmd_TYPE:
        ld hl,Reply200Type
        ld bc,Reply200TypeLen
        jp Reply_Send

Cmd_STAT:
        ld hl,Reply211Status
        ld bc,Reply211StatusLen
        jp Reply_Send

Cmd_ABOR:
        ld hl,Reply226Abort
        ld bc,Reply226AbortLen
        jp Reply_Send

Cmd_REST:
        ld hl,Reply502Rest
        ld bc,Reply502RestLen
        jp Reply_Send

Cmd_MLSD:
        ld hl,Reply502Mlsd
        ld bc,Reply502MlsdLen
        jp Reply_Send

Cmd_PASV:
        ld hl,Reply502Passive
        ld bc,Reply502PassiveLen
        jp Reply_Send

; ---------------------------------------------------------------------------
; Команды текущего каталога и метаданных
; ---------------------------------------------------------------------------

Cmd_PWD:
        ld de,ReplyBuffer
        ld hl,Reply257Prefix
        call CopyZNoTerm
        ld hl,CwdPath
        call CopyZNoTerm
        ld hl,Reply257Suffix
        call CopyZNoTerm
        xor a
        ld (de),a
        ld hl,ReplyBuffer
        call BufferLengthBC
        jp Reply_Send

Cmd_CWD:
        ld hl,CwdPath
        ld de,SavedCwdPath
        call CopyZ
        ld hl,CommandArgument
        call Fs_ChangePath
        jr nc,.changed
        ; При ошибке вернуть исходный каталог, даже если часть пути уже пройдена.
        ld hl,SavedCwdPath
        call Fs_ChangePath
        jr .bad
.changed:
        ld hl,Reply250
        ld bc,Reply250Len
        jp Reply_Send
.bad:
        ld hl,Reply550Dir
        ld bc,Reply550DirLen
        jp Reply_Send

Cmd_CDUP:
        call Fs_ChangeToParent
        jr c,Cmd_CWD.bad
        ld hl,Reply250
        ld bc,Reply250Len
        jp Reply_Send

Cmd_SIZE:
        xor a
        call Fs_MakeEntryFromArgument
        jr c,.bad
        call Fs_SelectWork
        ld hl,FsEntry
        call WC_FENTRY
        jr z,.bad
        ld (FileSize),hl
        ld (FileSize+2),de
        ld de,ReplyBuffer
        ld hl,Reply213Prefix
        call CopyZNoTerm
        ld hl,FileSize
        call U32_ToDec
        ld a,13
        ld (de),a
        inc de
        ld a,10
        ld (de),a
        inc de
        xor a
        ld (de),a
        ld hl,ReplyBuffer
        call BufferLengthBC
        jp Reply_Send
.bad:
        ld hl,Reply550File
        ld bc,Reply550FileLen
        jp Reply_Send

Cmd_MDTM:
        xor a
        call Fs_MakeEntryFromArgument
        jr c,Cmd_SIZE.bad
        call Fs_SelectWork
        ld hl,FsEntry
        call WC_FENTRY
        jr z,Cmd_SIZE.bad
        ld hl,Reply213Date
        ld bc,Reply213DateLen
        jp Reply_Send

; ---------------------------------------------------------------------------
; Команды конечной точки активного режима
;
; PORT кодирует IPv4 и 16-битный порт шестью числами h1,h2,h3,h4,p1,p2,
; где port=p1*256+p2. EPRT использует форму |1|IPv4|port|; вместо `|` клиент
; вправе выбрать любой односимвольный разделитель. Поддерживается только AF=1
; (IPv4), поскольку AT+CIPSTART этой конфигурации работает с IPv4.
;
; Обработчики лишь сохраняют endpoint и отвечают 200. Реальное TCP-соединение
; открывается позднее в Data_Open после предварительного ответа 150.
; ---------------------------------------------------------------------------

; Разобрать PORT h1,h2,h3,h4,p1,p2, проверить каждое число 0..255 и запретить
; нулевой порт. DataIp сохраняется как обычная строка для AT+CIPSTART.
Cmd_PORT:
        ld hl,CommandArgument
        ld ix,DataOctets
        ld c,6
.octet:
        push bc
        call ParseByte
        pop bc
        jr c,.bad
        ld (ix+0),a
        inc ix
        dec c
        jr z,.parsed
        ld a,(hl)
        cp ','
        jr nz,.bad
        inc hl
        jr .octet
.parsed:
        ld a,(hl)
        or a
        jr nz,.bad
        ld a,(DataOctets+4)
        ld h,a
        ld a,(DataOctets+5)
        ld l,a
        ld a,h
        or l
        jr z,.bad
        ld (DataPort),hl
        call BuildDataIpFromOctets
        ld a,1
        ld (DataReady),a
        ld hl,Reply200Port
        ld bc,Reply200PortLen
        jp Reply_Send
.bad:
        xor a
        ld (DataReady),a
        ld hl,Reply501Port
        ld bc,Reply501PortLen
        jp Reply_Send

; Разобрать EPRT <delim>1<delim>IPv4<delim>port<delim>. Адрес ограничен 15
; символами, порт — пятью цифрами и диапазоном 1..65535.
Cmd_EPRT:
        ld hl,CommandArgument
        ld a,(hl)
        or a
        jp z,Cmd_PORT.bad
        ld (EprtDelimiter),a
        inc hl
        ld a,(hl)
        cp '1'
        jp nz,.unsupported
        inc hl
        ld a,(EprtDelimiter)
        cp (hl)
        jp nz,Cmd_PORT.bad
        inc hl
        ld de,DataIp
        ld b,15
.copy_ip:
        ld a,(hl)
        or a
        jp z,Cmd_PORT.bad
        ld c,a
        ld a,(EprtDelimiter)
        cp c
        jr z,.ip_done
        ld a,c
        cp '.'
        jr z,.store_ip
        cp '0'
        jp c,Cmd_PORT.bad
        cp '9'+1
        jp nc,Cmd_PORT.bad
.store_ip:
        ld (de),a
        inc de
        inc hl
        djnz .copy_ip
        ld a,(EprtDelimiter)
        cp (hl)
        jp nz,Cmd_PORT.bad
.ip_done:
        xor a
        ld (de),a
        inc hl
        push hl
        ld hl,DataIp
        call ValidateIpv4Text
        pop hl
        jp c,Cmd_PORT.bad
        ld de,EprtPortText
        ld b,5
.copy_port:
        ld a,(hl)
        or a
        jp z,Cmd_PORT.bad
        ld c,a
        ld a,(EprtDelimiter)
        cp c
        jr z,.port_done
        ld a,c
        cp '0'
        jp c,Cmd_PORT.bad
        cp '9'+1
        jp nc,Cmd_PORT.bad
        ld (de),a
        inc de
        inc hl
        djnz .copy_port
        ld a,(EprtDelimiter)
        cp (hl)
        jr z,.port_done
        jp Cmd_PORT.bad
.port_done:
        xor a
        ld (de),a
        inc hl
        ld a,(hl)
        or a
        jp nz,Cmd_PORT.bad
        ld hl,EprtPortText
        call Ini_ParseWord
        jp c,Cmd_PORT.bad
        ld a,h
        or l
        jp z,Cmd_PORT.bad
        ld (DataPort),hl
        ld a,1
        ld (DataReady),a
        ld hl,Reply200Port
        ld bc,Reply200PortLen
        jp Reply_Send
.unsupported:
        ld hl,Reply522
        ld bc,Reply522Len
        jp Reply_Send

; Прочитать из строки HL беззнаковое десятичное число 0..255.
; Выход: A — число, HL — первый недесятичный символ, CF=1 — ошибка.
ParseByte:
        ld b,0                           ; значение
        ld c,0                           ; число цифр
.digit:
        ld a,(hl)
        cp '0'
        jr c,.done
        cp '9'+1
        jr nc,.done
        sub '0'
        ld d,a
        ld a,b
        cp 25
        jr c,.safe
        jr nz,.overflow
        ld a,d
        cp 6
        jr nc,.overflow
.safe:
        ld a,b
        add a,a
        ld e,a
        add a,a
        add a,a
        add a,e
        add a,d
        ld b,a
        inc hl
        inc c
        jr .digit
.done:
        ld a,c
        or a
        jr z,.overflow
        ld a,b
        or a
        ret
.overflow:
        scf
        ret

; Проверить нуль-терминированную строку IPv4: ровно четыре октета 0..255,
; разделённых точками, без постороннего хвоста. Выход: CF=0 — корректно.
ValidateIpv4Text:
        ld c,4
.octet:
        push bc
        call ParseByte
        pop bc
        ret c
        dec c
        jr z,.end
        ld a,(hl)
        cp '.'
        jr nz,.bad
        inc hl
        jr .octet
.end:
        ld a,(hl)
        or a
        ret z
.bad:
        scf
        ret

; Преобразовать первые четыре байта DataOctets в строку `a.b.c.d`,0.
BuildDataIpFromOctets:
        ld de,DataIp
        ld ix,DataOctets
        ld c,4
.one:
        ld l,(ix+0)
        ld h,0
        push bc
        ; Десятичное преобразование использует IX как рабочий регистр.
        push ix
        call U16_ToDec
        pop ix
        pop bc
        inc ix
        dec c
        jr z,.done
        ld a,'.'
        ld (de),a
        inc de
        jr .one
.done:
        xor a
        ld (de),a
        ret

; ---------------------------------------------------------------------------
; Выдача содержимого каталогов
; ---------------------------------------------------------------------------

; LIST выдаёт UNIX-подобные строки, NLST — только имена. Оба обработчика используют
; единый цикл FAT FindNext и по одной строке отправляют через активный data-канал.
Cmd_LIST:
        xor a
        ld (ListNamesOnly),a
        jr Ftp_DoList
Cmd_NLST:
        ld a,1
        ld (ListNamesOnly),a
; FTP-последовательность: проверить PORT/EPRT -> ответить 150 -> CIPSTART к клиенту
; -> перечислить каталог -> CIPCLOSE -> ответить 226. Ошибки data-канала дают
; 425/426, не разрушая управляющую сессию.
Ftp_DoList:
        ld a,(DataReady)
        or a
        jr z,.no_data
        ld hl,Reply150List
        ld bc,Reply150ListLen
        call Reply_Send
        call Data_Open
        jr c,.open_failed
        call Fs_SelectWork
        ld a,1
        call WC_ADIR
.next:
        ld de,DirEntryBuffer
        ld a,#1C                       ; размер, дата и время; любая запись
        call WC_FINDNEXT
        jr z,.done
        ld a,(ListNamesOnly)
        or a
        jr nz,.name_only
        call BuildListLine
        jr .send
.name_only:
        call BuildNameLine
.send:
        ld hl,ListLine
        call BufferLengthBC
        call Data_Send
        jr c,.transfer_failed
        jr .next
.done:
        call Data_Close
        ld hl,Reply226
        ld bc,Reply226Len
        jp Reply_Send
.transfer_failed:
        call Data_Close
        ld hl,Reply426
        ld bc,Reply426Len
        jp Reply_Send
.open_failed:
        call Data_Close
        ld hl,Reply425
        ld bc,Reply425Len
        jp Reply_Send
.no_data:
        ld hl,Reply425Port
        ld bc,Reply425PortLen
        jp Reply_Send

BuildNameLine:
        ld hl,DirEntryBuffer+9
        ld de,ListLine
        call CopyZNoTerm
        jp AppendCrLfZ

BuildListLine:
        ld de,ListLine
        ld a,(DirEntryBuffer+8)
        bit 4,a
        ld hl,ListFilePrefix
        jr z,.prefix
        ld hl,ListDirPrefix
.prefix:
        call CopyZNoTerm
        ld hl,DirEntryBuffer
        call U32_ToDec
        ld hl,ListDateText
        call CopyZNoTerm
        ld hl,DirEntryBuffer+9
        call CopyZNoTerm
        jp AppendCrLfZ

AppendCrLfZ:
        ld a,13
        ld (de),a
        inc de
        ld a,10
        ld (de),a
        inc de
        xor a
        ld (de),a
        ret

; ---------------------------------------------------------------------------
; Команды RETR и STOR
; ---------------------------------------------------------------------------

; Скачать обычный файл. WC_LOAD512 читает сектора по 512 байт, а ESP получает
; две посылки максимум по 256 байт: это уменьшает риск переполнить очередь ZiFi.
; FileRemaining — 32-битный счётчик, поэтому размер RETR не ограничен 256 КиБ.
Cmd_RETR:
        xor a
        call Fs_MakeEntryFromArgument
        jp c,.missing
        call Fs_SelectWork
        ld hl,FsEntry
        call WC_FENTRY
        jp z,.missing
        ld (FileSize),hl
        ld (FileSize+2),de
        call WC_GFILE
        ld a,(DataReady)
        or a
        jr z,Ftp_DoList.no_data
        ld hl,Reply150Retr
        ld bc,Reply150RetrLen
        call Reply_Send
        call Data_Open
        jp c,Ftp_DoList.open_failed
        ld hl,FileSize
        ld de,FileRemaining
        ld bc,4
        ldir
.block:
        ld hl,FileRemaining
        call U32_IsZero
        jr z,.done
        ld hl,FileIoBuffer
        ld b,1
        call WC_LOAD512

        ld hl,FileIoBuffer
        call File_Min256
        ; Data_Send использует BC внутри AT-обмена, поэтому длину надо сохранить.
        push bc
        call Data_Send
        pop bc
        jr c,.failed
        call File_SubBC
        ld hl,FileRemaining
        call U32_IsZero
        jr z,.done

        ld hl,FileIoBuffer+256
        call File_Min256
        push bc
        call Data_Send
        pop bc
        jr c,.failed
        call File_SubBC
        jr .block
.done:
        call Data_Close
        ld hl,Reply226
        ld bc,Reply226Len
        jp Reply_Send
.failed:
        call Data_Close
        ld hl,Reply426
        ld bc,Reply426Len
        jp Reply_Send
.missing:
        ld hl,Reply550File
        ld bc,Reply550FileLen
        jp Reply_Send

; Выход: BC=min(оставшиеся байты файла, 256), HL сохранён.
; RETR держит в HL адрес отправляемой половины сектора.
File_Min256:
        push hl
        ld a,(FileRemaining+2)
        ld b,a
        ld a,(FileRemaining+3)
        or b
        jr nz,.full
        ld hl,(FileRemaining)
        ld a,h
        or a
        jr nz,.full
        ld a,l
        or a
        jr z,.zero
        ld c,l
        ld b,0
        jr .done
.full:
        ld bc,256
        jr .done
.zero:
        ld bc,0
.done:
        pop hl
        ret

File_SubBC:
        ld hl,(FileRemaining)
        or a
        sbc hl,bc
        ld (FileRemaining),hl
        ld hl,(FileRemaining+2)
        ld bc,0
        sbc hl,bc
        ld (FileRemaining+2),hl
        ret

; Загрузить файл. Сначала весь TCP payload принимается в страницы плагина, и
; только после корректного CLOSED начинается запись FAT. Благодаря этому ошибка
; сети не оставляет частично записанный новый файл; существующий файл удаляется
; непосредственно перед созданием замены. Предел буфера — ровно 256 КиБ.
Cmd_STOR:
        xor a
        call Fs_MakeEntryFromArgument
        jr c,Cmd_RETR.missing
        ld a,(DataReady)
        or a
        jp z,Ftp_DoList.no_data
        ld hl,Reply150Stor
        ld bc,Reply150StorLen
        call Reply_Send
        call Data_Open
        jp c,Ftp_DoList.open_failed
        call Store_Begin
        call Store_Receive
        push af
        call Data_Close
        pop af
        jr c,.receive_failed
        ld a,(UploadOverflow)
        or a
        jr nz,.too_large
        call Store_WriteFile
        jr c,.disk_failed
        ld hl,Reply226Stor
        ld bc,Reply226StorLen
        jp Reply_Send
.receive_failed:
        ld hl,Reply426
        ld bc,Reply426Len
        jp Reply_Send
.too_large:
        ld hl,Reply552
        ld bc,Reply552Len
        jp Reply_Send
.disk_failed:
        ld hl,Reply452
        ld bc,Reply452Len
        jp Reply_Send

; Обнулить 32-битный размер загрузки, выбрать первую страницу склада и отметить
; режим StoreActive. С этого момента Rx_ProcessBurst направляет payload DataId
; в Store_CopyBurst вместо обычного побайтового обработчика.
Store_Begin:
        xor a
        ld (UploadSize+0),a
        ld (UploadSize+1),a
        ld (UploadSize+2),a
        ld (UploadSize+3),a
        ld (UploadOverflow),a
        ld (UploadNeedPage),a
        ld (DataClosed),a
        ld a,UPLOAD_FIRST_PAGE
        ld (UploadPage),a
        ld hl,#C000
        ld (UploadPointer),hl
        ld a,1
        ld (StoreActive),a
        ld (TransferActive),a
        jp Store_MapAndClear

; Отобразить UploadPage в окно #C000..#FFFF и очистить все 16 КиБ. Очистка нужна
; для последнего неполного сектора: SAVE512 должен получить нули после EOF.
Store_MapAndClear:
        ld a,(UploadPage)
        call WC_MNGC_PL
        xor a
        ld hl,#C000
        ld (hl),a
        ld de,#C001
        ld bc,#3FFF
        ldir
        ret

; Медленный путь одного payload-байта. Используется, когда заголовок +IPD и его
; первые данные пересекают границу burst. При достижении #0000 указатель прошёл
; #FFFF, поэтому следующая запись должна переключить страницу.
Store_PutByte:
        ld (StoreByte),a
        ld a,(UploadOverflow)
        or a
        ret nz
        ld a,(UploadNeedPage)
        or a
        jr z,.write
        ld a,(UploadPage)
        inc a
        ld (UploadPage),a
        cp UPLOAD_FIRST_PAGE+UPLOAD_PAGE_COUNT
        jr nc,.overflow
        call Store_MapAndClear
        ld hl,#C000
        ld (UploadPointer),hl
        xor a
        ld (UploadNeedPage),a
.write:
        ld hl,(UploadPointer)
        ld a,(StoreByte)
        ld (hl),a
        inc hl
        ld (UploadPointer),hl
        call UploadSize_Increment
        ld a,h
        or l
        ret nz
        ld a,1
        ld (UploadNeedPage),a
        ret
.overflow:
        ld a,1
        ld (UploadOverflow),a
        ret

; Быстрый путь для данных +IPD, уже помещённых в RxBurstBuffer.
; Наибольшая непрерывная часть копируется через LDIR с одновременным обновлением
; состояния разборщика и буфера загрузки 256 КиБ. Заголовки и управляющие данные
; по-прежнему разбираются побайтно.
; Быстрый путь STOR: выбрать минимум из трёх величин — остатка burst, остатка
; текущего +IPD и свободного места до конца страницы — затем скопировать LDIR.
; После каждого блока синхронно обновляются все три счётчика и состояние RX.
Store_CopyBurst:
        ld a,(UploadOverflow)
        or a
        jp nz,Store_SkipBurst
        ld a,(UploadNeedPage)
        or a
        jr z,.page_ready
        ld a,(UploadPage)
        inc a
        ld (UploadPage),a
        cp UPLOAD_FIRST_PAGE+UPLOAD_PAGE_COUNT
        jr nc,.overflow
        call Store_MapAndClear
        ld hl,#C000
        ld (UploadPointer),hl
        xor a
        ld (UploadNeedPage),a
.page_ready:
        ; CopyCount=min(BurstRemaining, IpdRemaining, байты до конца страницы).
        ld hl,(BurstRemaining)
        ld (CopyCount),hl
        ld de,(IpdRemaining)
        call MinCopyCountDE
        ld hl,0
        ld de,(UploadPointer)
        or a
        sbc hl,de                       ; #10000 минус указатель загрузки
        ex de,hl
        call MinCopyCountDE

        ld hl,(BurstPointer)
        ld de,(UploadPointer)
        ld bc,(CopyCount)
        ldir
        ld (BurstPointer),hl
        ld (UploadPointer),de
        call Store_SubtractCopyCounts
        call UploadSize_AddCopyCount

        ld hl,(UploadPointer)
        ld a,h
        or l
        jr nz,.check_ipd
        ld a,1
        ld (UploadNeedPage),a
.check_ipd:
        ld hl,(IpdRemaining)
        ld a,h
        or l
        ret nz
        xor a
        ld (RxState),a
        ret
.overflow:
        ld a,1
        ld (UploadOverflow),a
        jp Store_SkipBurst

; Ограничить CopyCount значением DE.
MinCopyCountDE:
        ld hl,(CopyCount)
        or a
        sbc hl,de
        ret c
        ret z
        ld (CopyCount),de
        ret

Store_SubtractCopyCounts:
        ld bc,(CopyCount)
        ld hl,(BurstRemaining)
        or a
        sbc hl,bc
        ld (BurstRemaining),hl
        ld hl,(IpdRemaining)
        or a
        sbc hl,bc
        ld (IpdRemaining),hl
        ret

UploadSize_AddCopyCount:
        ld bc,(CopyCount)
        ld hl,(UploadSize)
        add hl,bc
        ld (UploadSize),hl
        ret nc
        ld hl,(UploadSize+2)
        inc hl
        ld (UploadSize+2),hl
        ret

; Отбрасывать данные сверх предела 256 КиБ, сохраняя границы блоков +IPD.
Store_SkipBurst:
        ld hl,(BurstRemaining)
        ld (CopyCount),hl
        ld de,(IpdRemaining)
        call MinCopyCountDE
        ld hl,(BurstPointer)
        ld de,(CopyCount)
        add hl,de
        ld (BurstPointer),hl
        call Store_SubtractCopyCounts
        ld hl,(IpdRemaining)
        ld a,h
        or l
        ret nz
        xor a
        ld (RxState),a
        ret
.overflow:
        ld a,1
        ld (UploadOverflow),a
        ret

UploadSize_Increment:
        ld hl,UploadSize
        inc (hl)
        ret nz
        inc hl
        inc (hl)
        ret nz
        inc hl
        inc (hl)
        ret nz
        inc hl
        inc (hl)
        ret

; Принимать, пока клиент активного режима не закроет сокет данных.
; Ожидать payload до асинхронного события <DataId>,CLOSED. Каждый реально
; принятый burst перезапускает тайм-аут бездействия. Закрытие control-канала во
; время STOR считается аварией и не приводит к записи накопленного файла.
Store_Receive:
        ld hl,(FtpTimeout)
        ex de,hl
        call ZiFi_SetTimeout
.loop:
        ld a,(DataClosed)
        or a
        jr nz,.done
        call Server_ReadOnce
        jr z,.idle
        ld hl,(FtpTimeout)
        ex de,hl
        call ZiFi_SetTimeout
        jr .loop
.idle:
        call ZiFi_CheckTimeout
        jr c,.loop
        xor a
        ld (StoreActive),a
        ld (TransferActive),a
        scf
        ret
.done:
        ld a,(ControlId)
        cp #FF
        jr z,.aborted
        xor a
        ld (StoreActive),a
        ld (TransferActive),a
        or a
        ret
.aborted:
        xor a
        ld (StoreActive),a
        ld (TransferActive),a
        scf
        ret

; Создать/заменить файл и выгрузить накопленные страницы в FAT секторами 512 байт.
; Формат MkFileBuffer: флаг записи, 32-битный размер little-endian, имя с нулём.
; Выход: CF=1 — MKFILE завершился ошибкой; после успешного создания каждый сектор
; передаётся SAVE512 в порядке возрастания до исчерпания UploadRemaining.
Store_WriteFile:
        call Fs_SelectWork
        ; STOR заменяет существующий обычный файл.
        ld hl,FsEntry
        call WC_FENTRY
        jr z,.create
        ld hl,FsEntry
        call WC_DELETE
.create:
        ld de,MkFileBuffer
        xor a
        ld (de),a
        inc de
        ld hl,UploadSize
        ld bc,4
        ldir
        ld hl,CommandArgument
        call CopyZ
        ld hl,MkFileBuffer
        call WC_MKFILE
        jr nz,.failed

        ld hl,UploadSize
        ld de,UploadRemaining
        ld bc,4
        ldir
        ld a,UPLOAD_FIRST_PAGE
        ld (UploadWritePage),a
        xor a
        ld (UploadWriteSector),a
.sector:
        ld hl,UploadRemaining
        call U32_IsZero
        jr z,.success

        ; FAT API читает надёжно из постоянной страницы плагина. Поэтому один
        ; сектор копируется из окна загрузки #C000 в FileIoBuffer перед SAVE512.
        ld a,(UploadWritePage)
        call WC_MNGC_PL
        ld a,(UploadWriteSector)
        add a,a
        add a,#C0
        ld h,a
        ld l,0
        ld de,FileIoBuffer
        ld bc,512
        ldir
        ld hl,FileIoBuffer
        ld b,1
        call WC_SAVE512
        call Upload_SubSector
        ld a,(UploadWriteSector)
        inc a
        cp 32
        jr c,.same_page
        xor a
        ld (UploadWriteSector),a
        ld a,(UploadWritePage)
        inc a
        ld (UploadWritePage),a
        jr .sector
.same_page:
        ld (UploadWriteSector),a
        jr .sector
.success:
        or a
        ret
.failed:
        scf
        ret

; Уменьшить остаток записи на один сектор; неполный последний сектор даёт ноль.
Upload_SubSector:
        ld hl,(UploadRemaining)
        ld de,512
        or a
        sbc hl,de
        ld (UploadRemaining),hl
        ld hl,(UploadRemaining+2)
        ld de,0
        sbc hl,de
        jr c,.zero
        ld (UploadRemaining+2),hl
        ret
.zero:
        xor a
        ld (UploadRemaining+0),a
        ld (UploadRemaining+1),a
        ld (UploadRemaining+2),a
        ld (UploadRemaining+3),a
        ret

; ---------------------------------------------------------------------------
; Операции записи с каталогами
; ---------------------------------------------------------------------------

; Удаление файла требует флаг записи #00. Полные пути не разбираются здесь:
; клиент должен предварительно перейти в каталог командой CWD.
Cmd_DELE:
        xor a
        call Fs_MakeEntryFromArgument
        jr c,.bad
        call Fs_SelectWork
        ld hl,FsEntry
        call WC_DELETE
        jr z,.bad
        ld hl,Reply250Delete
        ld bc,Reply250DeleteLen
        jp Reply_Send
.bad:
        ld hl,Reply550Delete
        ld bc,Reply550DeleteLen
        jp Reply_Send

; Создать каталог в текущем потоке. После успеха вернуть 257 с исходным именем.
Cmd_MKD:
        ld hl,CommandArgument
        call Fs_ValidateName
        jr c,.bad
        call Fs_SelectWork
        ld hl,CommandArgument
        call WC_MKDIR
        jr nz,.bad
        ld de,ReplyBuffer
        ld hl,Reply257MkdPrefix
        call CopyZNoTerm
        ld hl,CommandArgument
        call CopyZNoTerm
        ld hl,Reply257MkdSuffix
        call CopyZNoTerm
        xor a
        ld (de),a
        ld hl,ReplyBuffer
        call BufferLengthBC
        jp Reply_Send
.bad:
        ld hl,Reply550Mkd
        ld bc,Reply550MkdLen
        jp Reply_Send

; Удалить пустой каталог через запись типа #10. Непустой каталог отклоняет FAT.
Cmd_RMD:
        ld a,#10
        call Fs_MakeEntryFromArgument
        jr c,.bad
        call Fs_SelectWork
        ld hl,FsEntry
        call WC_DELETE
        jr z,.bad
        ld hl,Reply250Delete
        ld bc,Reply250DeleteLen
        jp Reply_Send
.bad:
        ld hl,Reply550Rmd
        ld bc,Reply550RmdLen
        jp Reply_Send

; Первая половина двухшагового переименования: найти файл либо каталог, запомнить
; его тип и старое имя, затем ответить 350. Следующая допустимая команда — RNTO.
Cmd_RNFR:
        xor a
        call Fs_MakeEntryFromArgument
        jr c,.bad
        call Fs_SelectWork
        ld hl,FsEntry
        call WC_FENTRY
        jr nz,.found_file
        ld a,#10
        call Fs_MakeEntryFromArgument
        ld hl,FsEntry
        call WC_FENTRY
        jr z,.bad
        ld a,#10
        jr .save
.found_file:
        xor a
.save:
        ld (RenameFlag),a
        ld hl,CommandArgument
        ld de,RenameOldName
        call CopyZ
        ld a,1
        ld (RenamePending),a
        ld hl,Reply350
        ld bc,Reply350Len
        jp Reply_Send
.bad:
        xor a
        ld (RenamePending),a
        ld hl,Reply550File
        ld bc,Reply550FileLen
        jp Reply_Send

; Завершить отложенное переименование в текущем каталоге. Тип старой записи
; сохраняется в RenameFlag, поэтому файл нельзя случайно превратить в каталог.
Cmd_RNTO:
        ld a,(RenamePending)
        or a
        jr z,.bad_sequence
        ld hl,CommandArgument
        call Fs_ValidateName
        jr c,.bad
        ld a,(RenameFlag)
        ld (RenameEntry),a
        ld hl,RenameOldName
        ld de,RenameEntry+1
        call CopyZ
        call Fs_SelectWork
        ld hl,RenameEntry
        ld de,CommandArgument
        call WC_RENAME
        jr z,.bad
        xor a
        ld (RenamePending),a
        ld hl,Reply250Rename
        ld bc,Reply250RenameLen
        jp Reply_Send
.bad_sequence:
        ld hl,Reply503
        ld bc,Reply503Len
        jp Reply_Send
.bad:
        xor a
        ld (RenamePending),a
        ld hl,Reply550Rename
        ld bc,Reply550RenameLen
        jp Reply_Send

; ---------------------------------------------------------------------------
; Вспомогательные операции с потоками и путями Wild Commander
; ---------------------------------------------------------------------------

; Сделать поток 0 текущим рабочим потоком WC, не меняя его каталог.
Fs_SelectWork:
        ld d,0
        ld bc,#FFFF
        jp WC_STREAM

; Вернуть оба потока WC и текстовый CwdPath к корню выбранного FTP-тома.
Fs_ResetRoot:
        call Config_RootBothStreams
        ld hl,CwdPath
        ld (hl),'/'
        inc hl
        ld (hl),0
        xor a
        ld (CwdDepth),a
        ret

; HL — путь. Поддерживаются абсолютная и относительная формы, компоненты '.' и '..'.
; Абсолютный путь сначала сбрасывает поток в корень. Каждый компонент длиной не
; более 63 байтов проверяется через FAT. Переход `..` из корня остаётся в корне,
; что не позволяет FTP-клиенту выйти к другому устройству/панели WC.
Fs_ChangePath:
        ld a,(hl)
        or a
        jr z,.failed
        cp '/'
        jr nz,.component
        push hl
        call Fs_ResetRoot
        pop hl
.skip_slash:
        ld a,(hl)
        cp '/'
        jr nz,.component
        inc hl
        jr .skip_slash
.component:
        ld a,(hl)
        or a
        ret z
        ld de,PathComponent
        ld b,63
.copy:
        ld a,(hl)
        or a
        jr z,.component_done
        cp '/'
        jr z,.component_done
        ld (de),a
        inc de
        inc hl
        djnz .copy
        jr .failed
.component_done:
        xor a
        ld (de),a
        push hl
        ld hl,PathComponent
        ld de,PathDot
        call String_Equals
        jr z,.component_ok
        ld hl,PathComponent
        ld de,PathDotDot
        call String_Equals
        jr z,.parent
        ld hl,PathComponent
        call Fs_EnterDirectory
        jr c,.component_fail
        jr .component_ok
.parent:
        call Fs_ChangeToParent
        jr c,.component_fail
.component_ok:
        pop hl
        ld a,(hl)
        or a
        ret z
        inc hl
        jr .skip_slash
.component_fail:
        pop hl
.failed:
        scf
        ret

; Войти в один проверенный компонент каталога и синхронно обновить CwdPath.
Fs_EnterDirectory:
        call Path_CanAppend
        ret c
        push hl
        ld de,FsEntry+1
        ld a,#10
        ld (FsEntry),a
        call CopyZ
        call Fs_SelectWork
        ld hl,FsEntry
        call WC_FENTRY
        jr z,.failed_pop
        call WC_GDIR
        pop hl
        call Path_Append
        ld a,(CwdDepth)
        inc a
        ld (CwdDepth),a
        or a
        ret
.failed_pop:
        pop hl
        scf
        ret

; Подняться на один FAT-каталог. При CwdDepth=0 операция успешна, но поток
; остаётся в FTP-корне — стандартное безопасное поведение для `CWD ..`.
Fs_ChangeToParent:
        ld a,(CwdDepth)
        or a
        ret z                            ; корень является родителем самому себе
        call Fs_SelectWork
        ld hl,FsParentEntry
        call WC_FENTRY
        jr z,.failed
        call WC_GDIR
        call Path_RemoveLast
        ld a,(CwdDepth)
        dec a
        ld (CwdDepth),a
        or a
        ret
.failed:
        scf
        ret

; Добавить компонент HL к CwdPath, вставив `/`, кроме случая самого корня.
Path_Append:
        push hl
        ld de,CwdPath
.end:
        ld a,(de)
        or a
        jr z,.at_end
        inc de
        jr .end
.at_end:
        ld a,e
        cp low (CwdPath+1)
        jr nz,.add_slash
        ld a,d
        cp high (CwdPath+1)
        jr z,.copy
.add_slash:
        ld a,'/'
        ld (de),a
        inc de
.copy:
        pop hl
        jp CopyZ

; Проверить, поместятся ли компонент, возможный разделитель и завершающий ноль
; в CwdPath. Входной указатель HL сохраняется. Выход: CF=1 — места недостаточно.
Path_CanAppend:
        push hl
        ld de,CwdPath
.find_end:
        ld a,(de)
        or a
        jr z,.at_end
        inc de
        jr .find_end
.at_end:
        ld a,e
        cp low (CwdPath+1)
        jr nz,.need_slash
        ld a,d
        cp high (CwdPath+1)
        jr z,.check_byte
.need_slash:
        inc de
.check_byte:
        ld a,d
        cp high (CwdPath+FTP_NAME_SIZE)
        jr c,.room
        jr nz,.overflow
        ld a,e
        cp low (CwdPath+FTP_NAME_SIZE)
        jr nc,.overflow
.room:
        ld a,(hl)
        inc hl
        inc de
        or a
        jr nz,.check_byte
        pop hl
        or a
        ret
.overflow:
        pop hl
        scf
        ret

; Удалить последний текстовый компонент CwdPath, сохранив `/` для корня.
Path_RemoveLast:
        ld hl,CwdPath
.find_end:
        ld a,(hl)
        or a
        jr z,.back
        inc hl
        jr .find_end
.back:
        dec hl
        ld a,l
        cp low CwdPath
        jr nz,.check
        ld a,h
        cp high CwdPath
        jr z,.root
.check:
        ld a,(hl)
        cp '/'
        jr z,.cut
        dec hl
        jr .back
.cut:
        ld a,l
        cp low CwdPath
        jr nz,.zero_here
        ld a,h
        cp high CwdPath
        jr nz,.zero_here
.root:
        ld hl,CwdPath+1
.zero_here:
        xor a
        ld (hl),a
        ret

; A — флаг записи; CommandArgument копируется в FsEntry.
; Выход: CF=1 — недопустимое имя.
Fs_MakeEntryFromArgument:
        ld (FsEntry),a
        ld hl,CommandArgument
        call Fs_ValidateName
        ret c
        ld hl,CommandArgument
        ld de,FsEntry+1
        call CopyZ
        or a
        ret

; Проверить имя для операций в текущем каталоге. Запрещены пустая строка, `.`/`..`,
; управляющие символы, `/`, обратная косая черта и `:`. Разделители путей здесь
; не допускаются намеренно: навигация выполняется отдельной командой CWD.
Fs_ValidateName:
        ld a,(hl)
        or a
        jr z,.bad
        ld de,PathDot
        push hl
        call String_Equals
        pop hl
        jr z,.bad
        ld de,PathDotDot
        push hl
        call String_Equals
        pop hl
        jr z,.bad
.loop:
        ld a,(hl)
        or a
        jr z,.ok
        cp 32
        jr c,.bad
        cp '/'
        jr z,.bad
        cp #5C
        jr z,.bad
        cp ':'
        jr z,.bad
        inc hl
        jr .loop
.ok:
        or a
        ret
.bad:
        scf
        ret

; ---------------------------------------------------------------------------
; Десятичные преобразования и работа с буферами
; ---------------------------------------------------------------------------

BufferLengthBC:
        ; Подсчитать длину, сохранив HL на начале отправляемого буфера.
        push hl
        ld bc,0
.loop:
        ld a,(hl)
        or a
        jr z,.done
        inc hl
        inc bc
        jr .loop
.done:
        pop hl
        ret

U16_ToDec:
        ld (NumberTemp),hl
        xor a
        ld (NumberTemp+2),a
        ld (NumberTemp+3),a
        jp U32Temp_ToDec

; HL указывает на 32-битное число от младшего байта; DE принимает ASCII
; и сдвигается за записанные символы.
U32_ToDec:
        push de
        ld de,NumberTemp
        ld bc,4
        ldir
        pop de
U32Temp_ToDec:
        xor a
        ld (NumberDigits),a
        ld hl,NumberTemp
        call U32_IsZero
        jr nz,.divide
        ld a,'0'
        ld (de),a
        inc de
        ret
.divide:
        call Div32By10
        push af
        ld a,(NumberDigits)
        inc a
        ld (NumberDigits),a
        ld hl,NumberTemp
        call U32_IsZero
        jr nz,.divide
.emit:
        pop af
        add a,'0'
        ld (de),a
        inc de
        ld a,(NumberDigits)
        dec a
        ld (NumberDigits),a
        jr nz,.emit
        ret

; Разделить NumberTemp на 10 и вернуть остаток в A.
Div32By10:
        push de
        ld ix,NumberTemp+3
        ld c,4
        xor a
.byte:
        ld h,a
        ld l,(ix+0)
        ld b,0
.subtract:
        ld a,h
        or a
        jr nz,.can_subtract
        ld a,l
        cp 10
        jr c,.byte_done
.can_subtract:
        ld de,10
        or a
        sbc hl,de
        inc b
        jr .subtract
.byte_done:
        ld (ix+0),b
        ld a,l
        dec ix
        dec c
        jr nz,.byte
        pop de
        ret

; HL указывает на четыре байта. Z, если значение равно нулю.
U32_IsZero:
        ld a,(hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        ret

; ---------------------------------------------------------------------------
; Строки протокола и состояние
; ---------------------------------------------------------------------------

FtpUSER: db "USER",0
FtpPASS: db "PASS",0
FtpQUIT: db "QUIT",0
FtpSYST: db "SYST",0
FtpFEAT: db "FEAT",0
FtpNOOP: db "NOOP",0
FtpPWD:  db "PWD",0
FtpXPWD: db "XPWD",0
FtpCWD:  db "CWD",0
FtpXCWD: db "XCWD",0
FtpCDUP: db "CDUP",0
FtpTYPE: db "TYPE",0
FtpPORT: db "PORT",0
FtpEPRT: db "EPRT",0
FtpPASV: db "PASV",0
FtpEPSV: db "EPSV",0
FtpLIST: db "LIST",0
FtpNLST: db "NLST",0
FtpRETR: db "RETR",0
FtpSTOR: db "STOR",0
FtpSIZE: db "SIZE",0
FtpMDTM: db "MDTM",0
FtpDELE: db "DELE",0
FtpMKD:  db "MKD",0
FtpXMKD: db "XMKD",0
FtpRMD:  db "RMD",0
FtpXRMD: db "XRMD",0
FtpRNFR: db "RNFR",0
FtpRNTO: db "RNTO",0
FtpOPTS: db "OPTS",0
FtpCLNT: db "CLNT",0
FtpMODE: db "MODE",0
FtpSTRU: db "STRU",0
FtpSTAT: db "STAT",0
FtpABOR: db "ABOR",0
FtpREST: db "REST",0
FtpMLSD: db "MLSD",0
FtpMLST: db "MLST",0

Reply220: db "220 ZiFi FTP ready; use active mode (PORT/EPRT)",13,10
Reply220Len equ $-Reply220
Reply421Busy: db "421 Only one FTP session is allowed",13,10
Reply421BusyLen equ $-Reply421Busy
Reply331: db "331 Password required",13,10
Reply331Len equ $-Reply331
Reply230: db "230 Login successful; SD card read/write enabled",13,10
Reply230Len equ $-Reply230
Reply530: db "530 Please login with USER and PASS",13,10
Reply530Len equ $-Reply530
Reply530User: db "530 Invalid user",13,10
Reply530UserLen equ $-Reply530User
Reply530Pass: db "530 Invalid password",13,10
Reply530PassLen equ $-Reply530Pass
Reply221: db "221 Goodbye",13,10
Reply221Len equ $-Reply221
Reply215: db "215 UNIX Type: L8",13,10
Reply215Len equ $-Reply215
Reply211Features:
        db "211-Features",13,10
        db " EPRT",13,10
        db " SIZE",13,10
        db " MDTM",13,10
        db "211 End",13,10
Reply211FeaturesLen equ $-Reply211Features
Reply200: db "200 Command okay",13,10
Reply200Len equ $-Reply200
Reply200Type: db "200 Type set",13,10
Reply200TypeLen equ $-Reply200Type
Reply211Status: db "211 ZiFi FTP server is running",13,10
Reply211StatusLen equ $-Reply211Status
Reply226Abort: db "226 No transfer active",13,10
Reply226AbortLen equ $-Reply226Abort
Reply502: db "502 Command not implemented",13,10
Reply502Len equ $-Reply502
Reply502Rest: db "502 Restart markers are not supported",13,10
Reply502RestLen equ $-Reply502Rest
Reply502Mlsd: db "502 MLSD unavailable; use LIST or NLST",13,10
Reply502MlsdLen equ $-Reply502Mlsd
Reply502Passive: db "502 Passive mode unavailable; use PORT or EPRT",13,10
Reply502PassiveLen equ $-Reply502Passive
Reply257Prefix: db "257 ",34,0
Reply257Suffix: db 34," is current directory",13,10,0
Reply250: db "250 Directory changed",13,10
Reply250Len equ $-Reply250
Reply550Dir: db "550 Directory unavailable",13,10
Reply550DirLen equ $-Reply550Dir
Reply213Prefix: db "213 ",0
Reply213Date: db "213 20000101000000",13,10
Reply213DateLen equ $-Reply213Date
Reply550File: db "550 File unavailable",13,10
Reply550FileLen equ $-Reply550File
Reply200Port: db "200 Active data endpoint accepted",13,10
Reply200PortLen equ $-Reply200Port
Reply501Port: db "501 Invalid active data endpoint",13,10
Reply501PortLen equ $-Reply501Port
Reply522: db "522 Use IPv4 EPRT protocol 1",13,10
Reply522Len equ $-Reply522
Reply150List: db "150 Opening active data connection for directory list",13,10
Reply150ListLen equ $-Reply150List
Reply150Retr: db "150 Opening active data connection for file",13,10
Reply150RetrLen equ $-Reply150Retr
Reply150Stor: db "150 Send file data (maximum 262144 bytes)",13,10
Reply150StorLen equ $-Reply150Stor
Reply226: db "226 Transfer complete",13,10
Reply226Len equ $-Reply226
Reply226Stor: db "226 Upload stored on SD card",13,10
Reply226StorLen equ $-Reply226Stor
Reply425: db "425 Cannot open active data connection",13,10
Reply425Len equ $-Reply425
Reply425Port: db "425 Send PORT or EPRT first",13,10
Reply425PortLen equ $-Reply425Port
Reply426: db "426 Data connection failed",13,10
Reply426Len equ $-Reply426
Reply452: db "452 Cannot write file to SD card",13,10
Reply452Len equ $-Reply452
Reply552: db "552 Upload exceeds 256 KiB plugin buffer",13,10
Reply552Len equ $-Reply552
Reply250Delete: db "250 Delete successful",13,10
Reply250DeleteLen equ $-Reply250Delete
Reply550Delete: db "550 Cannot delete file",13,10
Reply550DeleteLen equ $-Reply550Delete
Reply257MkdPrefix: db "257 ",34,0
Reply257MkdSuffix: db 34," created",13,10,0
Reply550Mkd: db "550 Cannot create directory",13,10
Reply550MkdLen equ $-Reply550Mkd
Reply550Rmd: db "550 Cannot remove directory",13,10
Reply550RmdLen equ $-Reply550Rmd
Reply350: db "350 RNFR accepted; send RNTO",13,10
Reply350Len equ $-Reply350
Reply250Rename: db "250 Rename successful",13,10
Reply250RenameLen equ $-Reply250Rename
Reply503: db "503 Send RNFR before RNTO",13,10
Reply503Len equ $-Reply503
Reply550Rename: db "550 Rename failed",13,10
Reply550RenameLen equ $-Reply550Rename

ListFilePrefix: db "-rw-r--r-- 1 zx zx ",0
ListDirPrefix:  db "drwxr-xr-x 1 zx zx ",0
ListDateText:   db " Jan 01 2000 ",0
PathDot:        db ".",0
PathDotDot:     db "..",0
FsParentEntry:  db #10,"..",0

; Состояние FTP-сеанса и буферы управляющего протокола.
LoggedIn:        db 0
UserAccepted:    db 0
TransferActive:  db 0                    ; LIST/RETR/STOR удерживает data-канал
StoreActive:     db 0                    ; payload DataId направляется в склад STOR
RenamePending:   db 0
RenameFlag:      db 0
ListNamesOnly:   db 0
EprtDelimiter:   db 0
CommandLength:   db 0
CommandName:     ds 9
CommandBuffer:   ds FTP_COMMAND_SIZE
CommandArgument: ds FTP_NAME_SIZE

; Зеркало текущего FAT-каталога, нужное для PWD и ограничения корня.
CwdDepth:        db 0
CwdPath:         ds FTP_NAME_SIZE
SavedCwdPath:    ds FTP_NAME_SIZE
PathComponent:   ds 64
FsEntry:         ds FTP_NAME_SIZE+1
RenameEntry:     ds FTP_NAME_SIZE+1
RenameOldName:   ds FTP_NAME_SIZE
MkFileBuffer:    ds FTP_NAME_SIZE+5

; 32-битные little-endian размеры и временные буферы FAT/listing.
FileSize:        ds 4
FileRemaining:   ds 4
DirEntryBuffer:  ds FTP_NAME_SIZE+9
ListLine:        ds FTP_LIST_SIZE
ReplyBuffer:     ds FTP_LIST_SIZE

DataOctets:      ds 6
EprtPortText:    ds 6

; Указатели и счётчики 256-КиБ склада STOR.
UploadSize:      ds 4
UploadRemaining: ds 4
UploadPointer:   dw #C000
UploadPage:      db UPLOAD_FIRST_PAGE
UploadWritePage: db UPLOAD_FIRST_PAGE
UploadWriteSector: db 0
UploadNeedPage:  db 0
UploadOverflow:  db 0
StoreByte:       db 0
CopyCount:       dw 0

; Постоянный секторный буфер для FAT API; окно #C000 используется только как склад.
FileIoBuffer:    ds 512

NumberTemp:      ds 4
NumberDigits:    db 0
