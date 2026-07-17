from __future__ import annotations

from pathlib import Path
import re
import unittest


КОРЕНЬ = Path(__file__).resolve().parents[1]


def найти_значение(данные: bytes, ключ: bytes) -> bytes | None:
    """Смоделировать поиск ключа Ini_FindKey в первом секторе конфигурации."""
    if данные.startswith(b"\xef\xbb\xbf"):
        данные = данные[3:]
    искомый = ключ.lower()
    for строка in re.split(br"[\r\n]+", данные):
        строка = строка.lstrip(b" \t")
        if строка[: len(ключ)].lower() == искомый:
            return строка[len(ключ) :].lstrip(b" \t")
    return None


def разобрать_слово(значение: bytes) -> int | None:
    """Смоделировать Ini_ParseWordValue вместе с проверкой переполнения."""
    if значение.startswith(b'"'):
        значение = значение[1:]
    совпадение = re.match(br"[0-9]+", значение)
    if совпадение is None:
        return None
    число = int(совпадение.group())
    return число if число <= 65535 else None


class ТестыКонфигурации(unittest.TestCase):
    def test_utf8_bom_перед_ssid(self) -> None:
        данные = b'\xef\xbb\xbfSSID: "Home"\r\npassword: "secret"\r\n'
        self.assertEqual(найти_значение(данные, b"SSID:"), b'"Home"')
        self.assertEqual(найти_значение(данные, b"password:"), b'"secret"')

    def test_обычный_файл_без_bom(self) -> None:
        данные = b"SSID: Home\r\npassword: secret\r\n"
        self.assertEqual(найти_значение(данные, b"SSID:"), b"Home")

    def test_старые_строки_только_cr(self) -> None:
        данные = b"SSID: Home\rpassword: secret\rtime: +2\r"
        self.assertEqual(найти_значение(данные, b"SSID:"), b"Home")
        self.assertEqual(найти_значение(данные, b"password:"), b"secret")

    def test_lf_crlf_и_пустые_строки_можно_смешивать(self) -> None:
        данные = b"\r\n\tSSID: Home\n\rpassword: secret\r\n"
        self.assertEqual(найти_значение(данные, b"SSID:"), b"Home")
        self.assertEqual(найти_значение(данные, b"password:"), b"secret")

    def test_password_не_совпадает_с_ftp_password(self) -> None:
        данные = b"ftp_password: ftp-secret\rpassword: wifi-secret\r"
        self.assertEqual(
            найти_значение(данные, b"password:"), b"wifi-secret"
        )

    def test_числовые_ftp_значения_в_кавычках(self) -> None:
        данные = b'ftp_port: "2121"\rftp_timeout: "600"\r'
        порт = найти_значение(данные, b"ftp_port:")
        таймаут = найти_значение(данные, b"ftp_timeout:")
        self.assertEqual(разобрать_слово(порт or b""), 2121)
        self.assertEqual(разобрать_слово(таймаут or b""), 600)

    def test_переполнение_числа_отклоняется(self) -> None:
        self.assertIsNone(разобрать_слово(b'"65536"'))

    def test_asm_вызывает_пропуск_bom(self) -> None:
        исходник = (КОРЕНЬ / "src" / "config.asm").read_text(encoding="utf-8")
        поиск = исходник.split("Ini_FindKey:", 1)[1].split("Ini_SkipUtf8Bom:", 1)[0]
        пропуск = исходник.split("Ini_SkipUtf8Bom:", 1)[1].split("Ini_SkipHorizontal:", 1)[0]
        self.assertIn("call Ini_SkipUtf8Bom", поиск)
        for байт in ("cp #EF", "cp #BB", "cp #BF"):
            self.assertIn(байт, пропуск)

    def test_asm_разделяет_строки_по_cr_и_lf(self) -> None:
        исходник = (КОРЕНЬ / "src" / "config.asm").read_text(encoding="utf-8")
        поиск = исходник.split("Ini_FindKey:", 1)[1].split("Ini_SkipUtf8Bom:", 1)[0]
        разделители = исходник.split("Ini_SkipLineBreaks:", 1)[1].split(
            "Ini_SkipHorizontal:", 1
        )[0]
        self.assertIn("call Ini_SkipLineBreaks", поиск)
        self.assertIn("cp 13", разделители)
        self.assertIn("cp 10", разделители)

    def test_asm_разбирает_кавычки_у_чисел(self) -> None:
        исходник = (КОРЕНЬ / "src" / "config.asm").read_text(encoding="utf-8")
        загрузка = исходник.split("Config_Load:", 1)[1].split(
            "Config_RestoreRoot:", 1
        )[0]
        числовой_вход = исходник.split("Ini_ParseWordValue:", 1)[1].split(
            "Ini_ParseWord:", 1
        )[0]
        self.assertEqual(загрузка.count("call Ini_ParseWordValue"), 2)
        self.assertIn("cp '\"'", числовой_вход)


if __name__ == "__main__":
    unittest.main()
