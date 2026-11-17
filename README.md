# FantasticReader

Приложение для macOS 13+: распознаёт текст с фото и PDF через Gemini API (все языки, которые знает модель)
и сохраняет результат в PDF (как фото документа) или DOCX (только текст).

## Установка
Нужны Xcode или Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Arthuralend/fantasticreader.git
cd fantasticreader
./build-app.sh
cp -R FantasticReader.app /Applications/
```

Если macOS блокирует запуск: правый клик по приложению → «Открыть».
Быстрый запуск без установки: `swift run`.

## API-ключ
1. Получите ключ на https://aistudio.google.com (Get API key).
2. Вставьте его в окне приложения (значок ключа). Хранится в связке ключей macOS.

Файлы отправляются в Google для распознавания.
