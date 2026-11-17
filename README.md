# FantasticReader

Приложение для macOS 13+: распознаёт текст с фото и PDF (Google Cloud Vision, Apple Vision или Tesseract),
позволяет править области распознавания как в FineReader и сохраняет результат в PDF (как фото документа) или DOCX (только текст).

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

## Режимы распознавания
- **Google Cloud Vision** — облако, много языков (в т.ч. армянский). Нужен ключ: console.cloud.google.com →
  включить Cloud Vision API → Credentials → Create API key. Вставьте его в Настройках (хранится в связке ключей).
- **Apple Vision** — на Mac, без интернета: русский, украинский, английский и др.
- **Tesseract** — на Mac, без интернета. Установите `brew install tesseract`, языки (включая армянскую модель Calfa)
  скачиваются в Настройках → Языки Tesseract.

## Области
После распознавания текст на изображении обведён зелёными рамками. Рамку можно выделить, перетащить,
уменьшить за углы или удалить (правый клик) — текст сразу пересобирается без «мусора».
«Новая область» — нарисовать рамку; новые области (оранжевые) распознаются кнопкой «Распознать области».

## Готовый DMG
Скачайте `FantasticReader.dmg` на странице Releases, откройте и перетащите приложение в «Программы».
Приложение не подписано Apple: при первом запуске правый клик → «Открыть».
Собрать DMG самостоятельно: `./make-dmg.sh`.
