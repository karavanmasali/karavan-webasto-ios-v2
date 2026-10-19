# Karavan Webasto iOS — v0.2 clean

Bu paket önceki denemelerde oluşan `Info.plist` kopyalama hatasını kökten kaldıracak şekilde sıfırdan düzenlenmiştir.

## Önemli yapı değişikliği

`AppInfo.plist` proje kökündedir ve `sources:` listesine hiç eklenmez.

Swift kaynakları `project.yml` içinde tek tek listelenir. Bu yüzden XcodeGen `Info.plist` dosyasını uygulama kaynağı gibi ikinci kez kopyalayamaz.

Beklenen repo kökü:

- `.github/`
- `KaravanWebasto/`
- `AppInfo.plist`
- `project.yml`
- `README_TR.md`
- `LICENSE`

`KaravanWebasto/` içinde **Info.plist yoktur**.

## Bu sürümdeki termostat mantığı

HeatGenie/Boygu için kamuya açık entegrasyon belgeleri güç aç/kapat, sıcaklık, mod ve telemetriyi destekliyor; ancak bu protokol ailesi için yerleşik "Auto Start/Stop" yapılandırma anahtarı doğrulanmış değil.

Bu yüzden uygulama bilinmeyen bir "native auto-start" register'ı yazmıyor.

Uygulama kendi eşiklerini kullanır:

- START: kullanıcı seçer
- STOP: kullanıcı seçer
- STOP sıcaklığının START'tan en az 2°C yüksek olması zorunlu
- STOP eşiğinde normal güç kapatma komutu gönderilir; ana 12V kesilmez
- CLEAR/soğutma tamamlanmadan yeniden START verilmez
- Isıtıcı tamamen OFF olduktan ve sıcaklık START eşiğine düştükten sonra normal START komutu gönderilir
- Cihaz hata bildiriyorsa otomatik START yapılmaz

## GitHub'a sıfırdan yükleme

En temiz yöntem mevcut repoyu silmeden yeni bir repo açmaktır.

Önerilen isim:

`karavan-webasto-ios-v2`

ZIP'i aç ve **ZIP'in içindeki dosya/klasörleri** repo köküne yükle.

Sonra:

1. `Actions`
2. `Build unsigned iOS IPA`
3. Build yeşil olursa en altta `KaravanWebasto-unsigned` artifact'i çıkar.
4. Artifact'i indir.
5. İçindeki `.ipa` dosyasını Windows'tan iPhone'a sideload edebilirsin.

## İlk cihaz testi

Otomasyonu ilk açılışta hemen etkinleştirme.

Sıra:

1. HeatGenie uygulamasını tamamen kapat.
2. Karavan Webasto uygulamasında "Isıtıcıyı Bul" de.
3. Ortam, kasa ve voltaj doğru okunuyor mu kontrol et.
4. Manuel START dene.
5. Çalışırken Manuel STOP / CLEAR dene.
6. CLEAR tamamen bitsin.
7. Bunlar doğruysa otomatik termostatı aç.

## Not

iOS, uygulama kullanıcı tarafından zorla kapatıldığında arka plan Bluetooth otomasyonunu devam ettirmez. Bluetooth bağlantısı koparsa otomatik yeniden START garanti değildir.
