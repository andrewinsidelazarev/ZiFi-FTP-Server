from __future__ import annotations

import re
import unittest


ПРЕДЕЛ_ЗАГРУЗКИ = 256 * 1024


def извлечь_ip_станции(строки: list[str]) -> str | None:
    """Смоделировать распознавание нового и старого ответа AT+CIFSR."""
    for строка in строки:
        начало = строка.lstrip(' \t\r"')
        if "STAIP" not in строка and (not начало or not начало[0].isdigit()):
            continue
        for совпадение in re.finditer(r"\d+(?:\.\d+){3}", строка):
            адрес = совпадение.group(0)
            октеты = адрес.split(".")
            if all(октет.isdigit() and 0 <= int(октет) <= 255 for октет in октеты):
                if адрес != "0.0.0.0":
                    return адрес
    return None


class РазборщикIpd:
    """Минимальная модель автомата +IPD из сетевого модуля плагина."""

    def __init__(self) -> None:
        self.состояние = 0
        self.соединение = 0
        self.остаток = 0
        self.блоки: list[tuple[int, bytes]] = []
        self._данные = bytearray()

    def передать(self, блок: bytes) -> None:
        """Передать автомату очередную произвольно разделённую порцию UART."""
        for байт in блок:
            self._байт(байт)

    def _сброс(self, байт: int | None = None) -> None:
        self.состояние = 0
        self.остаток = 0
        self._данные.clear()
        if байт == ord("+"):
            self.состояние = 1

    def _байт(self, байт: int) -> None:
        if self.состояние == 0:
            if байт == ord("+"):
                self.состояние = 1
            return
        if self.состояние in (1, 2, 3):
            ожидается = b"IPD"[self.состояние - 1]
            if байт != ожидается:
                self._сброс(байт)
                return
            self.состояние += 1
            return
        if self.состояние == 4:
            if байт != ord(","):
                self._сброс(байт)
                return
            self.состояние = 5
            return
        if self.состояние == 5:
            if not ord("0") <= байт <= ord("4"):
                self._сброс(байт)
                return
            self.соединение = байт - ord("0")
            self.состояние = 6
            return
        if self.состояние == 6:
            if байт != ord(","):
                self._сброс(байт)
                return
            self.остаток = 0
            self.состояние = 7
            return
        if self.состояние == 7:
            if байт == ord(":") and self.остаток:
                self._данные.clear()
                self.состояние = 8
                return
            if ord("0") <= байт <= ord("9"):
                self.остаток = self.остаток * 10 + байт - ord("0")
                return
            self._сброс(байт)
            return

        self._данные.append(байт)
        self.остаток -= 1
        if self.остаток == 0:
            self.блоки.append((self.соединение, bytes(self._данные)))
            self._сброс()


def разобрать_port(текст: str) -> tuple[str, int]:
    """Разобрать аргумент PORT с теми же границами, что и сервер."""
    части = текст.split(",")
    if len(части) != 6 or any(not часть.isdigit() for часть in части):
        raise ValueError("Неверный формат PORT")
    числа = [int(часть) for часть in части]
    if any(not 0 <= число <= 255 for число in числа):
        raise ValueError("Октет вне диапазона")
    порт = числа[4] * 256 + числа[5]
    if порт == 0:
        raise ValueError("Нулевой порт")
    return ".".join(str(число) for число in числа[:4]), порт


def разобрать_eprt(текст: str) -> tuple[str, int]:
    """Разобрать IPv4-вариант EPRT и отвергнуть неправильный адрес."""
    if not текст:
        raise ValueError("Пустой EPRT")
    разделитель = текст[0]
    части = текст.split(разделитель)
    if len(части) != 5 or части[0] or части[4] or части[1] != "1":
        raise ValueError("Поддерживается только IPv4 EPRT")
    октеты = части[2].split(".")
    if len(октеты) != 4 or any(not октет.isdigit() for октет in октеты):
        raise ValueError("Неверный IPv4")
    if any(not 0 <= int(октет) <= 255 for октет in октеты):
        raise ValueError("Октет IPv4 вне диапазона")
    if not части[3].isdigit():
        raise ValueError("Неверный порт EPRT")
    порт = int(части[3])
    if not 1 <= порт <= 65535:
        raise ValueError("Порт EPRT вне диапазона")
    return ".".join(str(int(октет)) for октет in октеты), порт


def нормализовать_путь(текущий: str, новый: str) -> str:
    """Смоделировать ограничение корня FTP и обработку точек в CWD."""
    if not новый:
        raise ValueError("Пустой путь")
    части = [] if новый.startswith("/") else [x for x in текущий.split("/") if x]
    for компонент in новый.split("/"):
        if компонент in ("", "."):
            continue
        if компонент == "..":
            if части:
                части.pop()
            continue
        if len(компонент) > 63:
            raise ValueError("Слишком длинный компонент")
        части.append(компонент)
    результат = "/" + "/".join(части)
    if len(результат) > 255:
        raise ValueError("Слишком длинный путь")
    return результат


class ТестыПротокола(unittest.TestCase):
    def test_ip_из_cifsr(self) -> None:
        новый = ['+CIFSR:STAIP,"192.168.1.27"\r', '+CIFSR:STAMAC,"aa:bb:cc:dd:ee:ff"\r']
        старый = ['192.168.0.44\r', 'OK\r']
        ещё_нет = ['+CIFSR:APIP,"192.168.4.1"\r', '+CIFSR:STAIP,"0.0.0.0"\r']
        self.assertEqual(извлечь_ip_станции(новый), "192.168.1.27")
        self.assertEqual(извлечь_ip_станции(старый), "192.168.0.44")
        self.assertIsNone(извлечь_ip_станции(ещё_нет))

    def test_ipd_принимает_разорванный_заголовок(self) -> None:
        разборщик = РазборщикIpd()
        for часть in (b"noise+I", b"PD,1,4:US", b"ER", b"+IPD,2,5:abcde"):
            разборщик.передать(часть)
        self.assertEqual(разборщик.блоки, [(1, b"USER"), (2, b"abcde")])

    def test_ipd_разделяет_соседние_пакеты(self) -> None:
        разборщик = РазборщикIpd()
        разборщик.передать(b"+IPD,0,6:NOOP\r\n+IPD,0,6:QUIT\r\n")
        self.assertEqual(разборщик.блоки, [(0, b"NOOP\r\n"), (0, b"QUIT\r\n")])

    def test_port(self) -> None:
        self.assertEqual(разобрать_port("192,168,1,23,7,138"), ("192.168.1.23", 1930))
        with self.assertRaises(ValueError):
            разобрать_port("192,168,1,256,7,138")
        with self.assertRaises(ValueError):
            разобрать_port("127,0,0,1,0,0")

    def test_eprt(self) -> None:
        self.assertEqual(разобрать_eprt("|1|192.168.1.23|65535|"), ("192.168.1.23", 65535))
        self.assertEqual(разобрать_eprt("|1|255.255.255.255|21|"), ("255.255.255.255", 21))
        for значение in ("|2|192.168.1.23|21|", "|1|999.1.1.1|21|", "|1|1.2.3|21|", "|1|1.2.3.4|65536|"):
            with self.subTest(значение=значение), self.assertRaises(ValueError):
                разобрать_eprt(значение)

    def test_корень_пути_нельзя_покинуть(self) -> None:
        self.assertEqual(нормализовать_путь("/games/demo", "../../../system"), "/system")
        self.assertEqual(нормализовать_путь("/games", "/music/./mods"), "/music/mods")

    def test_граница_буфера_stor(self) -> None:
        данные = bytearray()
        данные.extend(bytes(ПРЕДЕЛ_ЗАГРУЗКИ))
        self.assertEqual(len(данные), ПРЕДЕЛ_ЗАГРУЗКИ)
        данные.append(0)
        self.assertGreater(len(данные), ПРЕДЕЛ_ЗАГРУЗКИ)


if __name__ == "__main__":
    unittest.main()
