from __future__ import annotations

import hashlib
import math
import re
import sys
from pathlib import Path


КОРЕНЬ = Path(__file__).resolve().parents[1]
ПУТЬ_WMF = КОРЕНЬ / "ZIFIFTP.WMF"
КАТАЛОГ_ИСХОДНИКОВ = КОРЕНЬ / "src"


def проверить(условие: bool, сообщение: str) -> None:
    """Завершить проверку с понятным описанием нарушенного условия."""
    if not условие:
        raise AssertionError(сообщение)


def извлечь_комментарий(строка: str) -> str:
    """Найти точку с запятой вне строкового литерала ассемблера."""
    в_строке = False
    for номер, символ in enumerate(строка):
        if символ == '"':
            в_строке = not в_строке
        elif символ == ";" and not в_строке:
            return строка[номер + 1 :].strip()
    return ""


def проверить_utf8_и_комментарии() -> None:
    """Проверить кодировку и наличие русского текста во всех комментариях ASM."""
    исходники = sorted(КАТАЛОГ_ИСХОДНИКОВ.glob("*.asm"))
    исходники += sorted(КАТАЛОГ_ИСХОДНИКОВ.glob("*.inc"))
    проверить(bool(исходники), "Исходники ASM не найдены")
    for путь in исходники:
        текст = путь.read_text(encoding="utf-8")
        for номер, строка in enumerate(текст.splitlines(), 1):
            комментарий = извлечь_комментарий(строка)
            if not re.search(r"[A-Za-zА-Яа-яЁё]", комментарий):
                continue
            проверить(
                bool(re.search(r"[А-Яа-яЁё]", комментарий)),
                f"{путь.name}:{номер}: комментарий без русского текста",
            )

    для_utf8 = [КОРЕНЬ / "README.md", КОРЕНЬ / "zifi.ini.example"]
    для_utf8 += sorted((КОРЕНЬ / "tests").glob("*.py"))
    для_utf8 += sorted((КОРЕНЬ / "tools").glob("*.py"))
    for путь in для_utf8:
        путь.read_text(encoding="utf-8")


def проверить_fat_api() -> None:
    """Запретить прямой ввод-вывод в файловых модулях и проверить вызовы WC."""
    имена = ("config.asm", "ftp_commands.asm")
    части = []
    запрещено = re.compile(r"\b(?:in|out|inir|indr|outi|otir)\b", re.IGNORECASE)
    for имя in имена:
        путь = КАТАЛОГ_ИСХОДНИКОВ / имя
        текст = путь.read_text(encoding="utf-8")
        части.append(текст)
        for номер, строка in enumerate(текст.splitlines(), 1):
            код = строка.split(";", 1)[0]
            проверить(
                запрещено.search(код) is None,
                f"{имя}:{номер}: прямой портовый ввод-вывод в модуле FAT",
            )

    файловый_код = "\n".join(части)
    обязательные = (
        "WC_STREAM",
        "WC_FENTRY",
        "WC_GDIR",
        "WC_ADIR",
        "WC_FINDNEXT",
        "WC_GFILE",
        "WC_LOAD512",
        "WC_MKFILE",
        "WC_SAVE512",
        "WC_MKDIR",
        "WC_RENAME",
        "WC_DELETE",
    )
    for имя in обязательные:
        проверить(f"call {имя}" in файловый_код, f"Нет обязательного вызова {имя}")

    zifi = (КАТАЛОГ_ИСХОДНИКОВ / "zifi_uart.asm").read_text(encoding="utf-8")
    проверить("inir" in zifi.lower(), "В модуле ZiFi отсутствует пакетное чтение INIR")
    ожидание_ok = zifi.split("ZiFi_WaitOk:", 1)[1].split("ZiFi_SendWait:", 1)[0]
    проверить(
        "TokConnect" not in ожидание_ok,
        "WIFI CONNECTED нельзя считать завершающим ответом OK",
    )

    команды = (КАТАЛОГ_ИСХОДНИКОВ / "ftp_commands.asm").read_text(encoding="utf-8")
    сборка_ip = команды.split("BuildDataIpFromOctets:", 1)[1].split("Cmd_LIST:", 1)[0]
    проверить(
        re.search(r"push\s+ix\s+call\s+U16_ToDec\s+pop\s+ix", сборка_ip, re.IGNORECASE) is not None,
        "Сборка IP для PORT обязана сохранять IX при десятичном преобразовании",
    )
    проверить(
        zifi.count("call Net_ObserveWaitLine") >= 2,
        "Синхронные ожидания AT обязаны учитывать событие CLOSED",
    )

    сеть = (КАТАЛОГ_ИСХОДНИКОВ / "network.asm").read_text(encoding="utf-8")
    события = сеть.split("Event_Handle:", 1)[1].split("Net_ObserveWaitLine:", 1)[0]
    проверить(
        re.search(
            r"push\s+af\s+ld\s+hl,Reply421Busy\s+ld\s+bc,Reply421BusyLen"
            r"\s+call\s+Net_Send\s+pop\s+af\s+jp\s+Link_Close",
            события,
            re.IGNORECASE,
        )
        is not None,
        "Лишний control-канал обязан получать 421 и закрываться",
    )
    забыть_control = сеть.split("Control_Forget:", 1)[1].split("Net_Send:", 1)[0]
    проверить(
        "ld (DataId),a" in забыть_control and "ld (DataConnected),a" in забыть_control,
        "Аварийное закрытие control-канала обязано забывать data-link",
    )
    quit_код = команды.split("Cmd_QUIT:", 1)[1].split("Cmd_SYST:", 1)[0]
    проверить(
        "Control_Close" in quit_код,
        "QUIT обязан закрывать TCP-канал и освобождать сервер",
    )

    retr = команды.split("Cmd_RETR:", 1)[1].split("Cmd_STOR:", 1)[0]
    проверить(
        len(re.findall(r"push\s+bc\s+call\s+Data_Send\s+pop\s+bc", retr, re.IGNORECASE)) == 2,
        "RETR обязан сохранять длину BC каждого отправляемого блока",
    )
    проверить(
        "ld hl,FileIoBuffer" in retr and "ld hl,#C000" not in retr,
        "RETR обязан загружать FAT-сектор в постоянный буфер страницы плагина",
    )
    минимум_256 = команды.split("File_Min256:", 1)[1].split("File_SubBC:", 1)[0]
    проверить(
        re.search(r"push\s+hl[\s\S]*pop\s+hl", минимум_256, re.IGNORECASE) is not None,
        "Расчёт длины RETR обязан сохранять в HL указатель на данные",
    )
    stor = команды.split("Store_WriteFile:", 1)[1].split("Cmd_DELE:", 1)[0]
    проверить(
        "ld de,FileIoBuffer" in stor and "call WC_SAVE512" in stor,
        "STOR обязан копировать сектор из окна #C000 перед записью через FAT API",
    )
    проверить(
        re.search(r"FileIoBuffer:\s+ds\s+512", команды, re.IGNORECASE) is not None,
        "Постоянный секторный буфер FAT должен иметь размер 512 байт",
    )


def проверить_wmf(путь: Path) -> tuple[int, str]:
    """Проверить структуру заголовка, размер страницы кода и ключевые литералы."""
    проверить(путь.is_file(), f"Не найден файл {путь}")
    данные = путь.read_bytes()
    проверить(len(данные) > 512, "Файл WMF короче заголовка")
    проверить(данные[:16] == bytes(16), "Нарушен резерв в начале заголовка")
    проверить(данные[16:32] == b"WildCommanderMDL", "Неверная сигнатура WMF")
    проверить(данные[32] == 0x0A, "Неверная версия формата плагина")
    проверить(данные[33] == 0, "Ненулевой резервный байт +33")
    проверить(данные[34] == 17, "Плагину должно выделяться 17 страниц")
    проверить(данные[35] == 0, "В окно #8000 должна включаться страница 0")

    размер_кода = len(данные) - 512
    блоки = math.ceil(размер_кода / 512)
    проверить(данные[36] == 0, "Код должен загружаться в страницу 0")
    проверить(данные[37] == блоки, "В заголовке неверно указано число блоков кода")
    проверить(данные[38:48] == bytes(10), "Неиспользуемые описатели блоков не очищены")
    проверить(данные[48:165] == bytes(117), "Нарушен резерв заголовка +48..+164")
    проверить(
        данные[165:197].rstrip(b" ") == b"ZiFi FTP Server v0.10",
        "Неверное имя плагина",
    )
    проверить(данные[197] == 0x03, "Плагин должен запускаться из меню F10")
    проверить(данные[198:512] == bytes(314), "Нарушен резерв до конца заголовка")
    проверить(0 < размер_кода <= 0x4000, "Код не помещается в страницу #8000..#BFFF")

    литералы = (
        b"zifi.ini",
        b"ftp_user:",
        b"AT+CIPMUX=1",
        b"AT+CIPSERVER=1,",
        b"AT+CIPSTART=",
        b"220 ZiFi FTP ready",
        b"421 Only one FTP session is allowed",
        b"PORT",
        b"EPRT",
        b"STOR",
        b"RETR",
    )
    for литерал in литералы:
        проверить(литерал in данные, f"В WMF отсутствует литерал {литерал!r}")

    исходник = (КАТАЛОГ_ИСХОДНИКОВ / "ftp_commands.asm").read_text(encoding="utf-8")
    проверить("UPLOAD_PAGE_COUNT equ 16" in исходник, "Изменён размер буфера STOR")

    сумма = hashlib.sha256(данные).hexdigest()
    return размер_кода, сумма


def main() -> int:
    """Выполнить все проверки и вывести краткий отчёт."""
    путь = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ПУТЬ_WMF
    проверить_utf8_и_комментарии()
    проверить_fat_api()
    размер_кода, сумма = проверить_wmf(путь)
    print(f"WMF проверен: {путь}")
    print(f"Размер файла: {путь.stat().st_size} байт; код: {размер_кода} байт")
    print(f"SHA-256: {сумма}")
    print("FAT: только встроенный драйвер Wild Commander; прямых портов SD нет")
    print("Комментарии и документация: UTF-8, русский текст")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as ошибка:
        print(f"Ошибка проверки: {ошибка}", file=sys.stderr)
        raise SystemExit(1)
