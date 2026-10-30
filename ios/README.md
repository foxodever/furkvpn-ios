# FurkVPN для iOS

iPhone- и iPad-клиент FurkVPN (iOS 15+): SwiftUI-приложение и расширение Packet Tunnel с тем же ядром
Xray-core и той же Go-обёрткой (`../core/libxray`), что в Android-приложении.

```
FurkVPN/      приложение: экраны (Views/), подписка и API (Http.swift), VPN-профиль (VPNController.swift)
FurkTunnel/   расширение Packet Tunnel: ядро Xray на utun-дескрипторе туннеля
Shared/       общее для обоих: модели, хранилище в App Group, обёртка над ядром (Core.swift), сообщения
project.yml   описание проекта для XcodeGen (FurkVPN.xcodeproj в git не хранится)
build.sh      сборка на macOS: ядро → Frameworks/Libxray.xcframework, проект, IPA
```

## Как это работает

- Ключ, подписка, зеркала, `x-hwid` и прочие заголовки, API furkapp.net — как в Android (см. README в корне).
  `x-device-os: iOS`, модель — вида `iPhone15,3`. HWID хранится в связке ключей: переустановка приложения —
  то же устройство.
- Разбор ключа и подписки, правила маршрутизации и сборка конфига туннеля написаны на Go
  (`core/libxray/keys.go`, `subscription.go`, `routes.go`, `tunconfig.go`) — это перенос Kotlin-кода
  Android-приложения вместе с его тестами. Swift только показывает экраны и управляет VPN.
- Приложение складывает подписку (`subscription.json`, `subscription_configs.json`) и настройки в общий
  контейнер App Group `group.com.furkvpn.app`. Расширение при запуске берёт оттуда выбранный сервер и правила,
  собирает конфиг (`BuildTunnelConfig`: вход TUN, DNS через модуль Xray по TCP, свои правила перед правилами
  сервера) и запускает ядро на utun-дескрипторе туннеля (`StartTunnel`).
- Туннель: 172.19.0.1/30 и fdfe:dcba:9876::1/126, маршруты по умолчанию для IPv4 и IPv6, DNS 172.19.0.2 —
  как в Android. Соединения самого расширения идут мимо туннеля.
- Смена сервера или правил при подключённом VPN не переподключает VPN: приложение шлёт расширению `reload`,
  и оно перезапускает ядро на том же туннеле.
- **Пинг**: без VPN — в приложении (`Ping`); с VPN — в расширении (его соединения не идут в туннель,
  а приложения — идут). В расширении не больше трёх проверок одновременно: каждая — отдельное ядро, а
  расширению iOS даёт около 50 МБ памяти (`SetMemoryLimit(32, 50)` заставляет Go собирать мусор раньше).
- **Автовыбор** — то же, что в Android-сервисе: новое ядро при смене сети (Wi-Fi ↔ мобильная), раз в 10 секунд
  `AutoSelectCheck` смотрит проверки балансировщика и перезапускает ядро (не чаще раза в 2 минуты), если умерли
  серверы, через которые шёл трафик; после сна дольше 5 минут серверы перепроверяются сразу; после перезапуска
  запасным ставится сервер, который был лучшим.
- Ссылки `furkvpn://import?url=…` (их открывает furkapp.net/import на iPhone) добавляют ключ.

Чего нет по сравнению с Android: приложений без VPN (iOS не даёт VPN-приложению выбирать приложения),
раздачи интернета, журнала подключений, определения белых списков, QR-сканера, импорта и экспорта настроек.

## Сборка

Нужны macOS с Xcode, Go (версия из `core/go.mod`), gomobile и XcodeGen:

```bash
cd core && go install golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind && gomobile init
brew install xcodegen
./ios/build.sh                # → ios/build/FurkVPN-<версия>-unsigned.ipa
```

Без Mac собирает GitHub Actions (`.github/workflows/ios.yml`) при пуше в ветку `ios`: IPA и конец журнала
сборки кладутся в ветку `ios-build` (её можно забрать ключом деплоя) и в артефакты запуска.

**IPA без подписи.** Она подписана ad-hoc с нужными правами (Network Extension, App Group). Поставить её как есть
можно через TrollStore; иначе её нужно переподписать сертификатом разработчика с профилями для
`com.furkvpn.app` и `com.furkvpn.app.tunnel`, в которых есть Network Extensions (Packet Tunnel) и App Group
`group.com.furkvpn.app`. VPN-расширение работает только с платным аккаунтом Apple Developer.

## Выпуск (позже)

Для TestFlight и App Store нужен аккаунт организации (правило 5.4 App Review для VPN-приложений) и в секретах
репозитория — ключ App Store Connect API (Issuer ID, Key ID, .p8) и Team ID; тогда в workflow добавляется
подписанная сборка (`xcodebuild archive` с `-allowProvisioningUpdates`) и загрузка в TestFlight.
Версия — `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` в `project.yml`.
