# zapret-auto

**Tek dosya, kurulumsuz DPI atlatma + şifreli DNS, Windows için.**
İnternet servis sağlayıcının (ISS) DPI ile engellediği siteleri (Discord, Roblox, Wattpad vb.) açar, DNS zehirlenmesini şifreli DNS (DoH) ile aşar. VPN değildir: trafik tünellenmez, ping değişmez, sadece engellenen bağlantıların ilk paketleri değiştirilir.

[English below](#english)

---

## Hızlı başlangıç

1. [**Releases**](../../releases/latest) sayfasından `ZAPRET-AUTO.bat` dosyasını indir.
2. Çift tıkla, yönetici iznini onayla.
3. **Kur / Onar**'a bas. Araç engelleri ölçer, senin ISS'inde çalışan en iyi ayarı bulur ve kalıcı olarak kurar.

Bu kadar. Bilgisayar her açıldığında kendiliğinden çalışır.

> **Windows "bilgisayarınızı korudu" derse:** *Ek bilgi → Yine de çalıştır*. İnternetten indirilen her .bat dosyasında çıkar.
> **Antivirüs uyarı verirse:** aşağıdaki [Antivirüs](#antivirüs) bölümüne bak.

## Ne yapar?

| | |
|---|---|
| **Engel tespiti** | Hangi sitelerin DPI ile engellendiğini ve DNS'in zehirlenip zehirlenmediğini ölçer (Test Et hiçbir şey kurmadan sadece ölçer). |
| **Strateji seçimi** | [zapret](https://github.com/bol-van/zapret) / [Flowseal](https://github.com/Flowseal/zapret-discord-youtube) paketindeki ~20 stratejiyi senin bağlantında tek tek dener, çalışanı seçer. Aynı ağda bir dahaki sefere hatırlar. |
| **DPI atlatma** | `winws` bir Windows servisi olarak kurulur; *autohostlist* ile yeni engelleri kendiliğinden öğrenir. |
| **Şifreli DNS** | Windows 10'da [dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy), Windows 11'de Windows'un kendi DoH'u (deneysel). Sunucular IP ile tanımlı (1.1.1.1 / 8.8.8.8), SNI gönderilmez. |
| **Nöbetçi** | Arka planda sürekli çalışan bir program değil; bir zamanlanmış görev. Açılışta, 6 saatte bir ve ağ değişince kontrol eder: duran servisi başlatır, bozulan DNS'i düzeltir, strateji artık çalışmıyorsa yenisini bulur. |
| **Kendini toparlama** | Bir işlem yarıda kesilirse (pencere kapatıldı, elektrik gitti) sonraki açılışta sistem otomatik toparlanır; DNS hiçbir zaman ölü bırakılmaz. |
| **Çakışma tespiti** | Daha önce kurulmuş GoodbyeDPI, ByeDPI, başka zapret kurulumları vb. bulunur, onayınla durdurulur (silinmez). Proxy/VPN istemcileri ve hosts dosyası için uyarı verir. |
| **Temiz kaldırma** | **Kaldır**: servisler, görev ve dosyalar silinir; DNS ayarları, durdurulan araçlar ve diğer ayarlar kurulumdan önceki haline döner. |

## Güvenlik ve şeffaflık

- **Tek, okunabilir dosya.** `ZAPRET-AUTO.bat`'ın üst kısmı kısa bir batch başlatıcı, geri kalanı düz PowerShell. Base64, gizlenmiş kod ya da gizli indirme yok. Not Defteri ile açıp ne yaptığını okuyabilirsin.
- **İndirilen paketler doğrulanır.** zapret ve dnscrypt-proxy, resmi GitHub sürümlerinden indirilir ve SHA256 ile doğrulanır (sabitlenmiş sürümler: zapret-discord-youtube 1.9.9c, dnscrypt-proxy 2.1.16).
- **Güvenlik ayarlarına kendiliğinden dokunmaz.** Antivirüs istisnası eklemez, Defender'ı kapatmaz.
- **Değiştirdiği şeyler:** `zapret` ve `dnscrypt-proxy` servisleri, `\zapret-auto\` altında bir zamanlanmış görev, internete çıkan ağ bağdaştırıcısının DNS ayarı, TCP zaman damgaları. Dosyalar `%ProgramData%\zapret-auto` içindedir. Hepsi **Kaldır** ile geri alınır.
- **Telemetri yok.** Hiçbir yere veri gönderilmez; teşhis raporu sadece senin bilgisayarına, kullanıcı adı ve ziyaret edilen siteler maskelenerek yazılır.

## Antivirüs

`winws.exe` ve WinDivert sürücüsü ağ paketlerini değiştirdiği için bazı antivirüsler tarafından **yanlış pozitif** olarak ("HackTool" vb.) işaretlenir. Bu durumda araç ne olduğunu açıkça söyler ve yol gösterir: `C:\ProgramData\zapret-auto` klasörünü antivirüsünün istisnalarına ekleyip **Kur / Onar**'a tekrar bas.
Windows 11'de **Akıllı Uygulama Denetimi (Smart App Control)** açıksa imzasız `winws.exe` çalışamaz; araç bunu kurulumdan önce tespit eder.

## Komut satırı

```
ZAPRET-AUTO.bat                 arayüz
ZAPRET-AUTO.bat install /quiet  sessiz kurulum
ZAPRET-AUTO.bat probe           sadece ölç
ZAPRET-AUTO.bat status          durum
ZAPRET-AUTO.bat uninstall       kaldır
ZAPRET-AUTO.bat help            tüm komutlar
```

## Gereksinimler

Windows 10 / 11 (64-bit), PowerShell 5.1 (Windows ile gelir), yönetici izni. İlk kurulumda GitHub'a erişim gerekir; erişim yoksa başka bir bilgisayarda **Ayarlar → Çevrimdışı paket** ile hazırlanan zip kullanılabilir.

## Teşekkürler

- [bol-van/zapret](https://github.com/bol-van/zapret): `winws` ve DPI atlatma teknikleri
- [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube): Windows paketi ve stratejiler
- [DNSCrypt/dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy): şifreli DNS
- [WinDivert](https://github.com/basil00/WinDivert): paket yakalama sürücüsü

Bu projeler depoya dahil edilmez; çalışma sırasında resmi sürümlerinden indirilir ve kendi lisanslarına tabidir.

## Lisans

[GPL-3.0](LICENSE)

---

## English

**Single-file, install-free DPI bypass + encrypted DNS for Windows.**
Opens sites your ISP blocks with DPI and defeats DNS poisoning with DNS-over-HTTPS. Not a VPN: no tunnel, no ping change; only the first packets of blocked connections are modified.

**Quick start:** download `ZAPRET-AUTO.bat` from [Releases](../../releases/latest), double-click, approve the admin prompt, press **Install / Repair**. It measures the blocks, picks the strategy that works on your connection (from the zapret / Flowseal bundle) and installs it as a boot service. The UI follows your Windows language (Turkish / English).

**Highlights:** probe mode that changes nothing, per-network strategy memory, autohostlist learns new blocks, encrypted DNS via dnscrypt-proxy (Windows 10) or built-in DoH (Windows 11, experimental), a watchdog scheduled task that repairs services/DNS and re-selects a strategy when the ISP changes its DPI, recovery of interrupted tasks, detection of GoodbyeDPI/ByeDPI/other zapret installs, clean uninstall that restores the previous state.

**Transparency:** one readable file (short batch launcher + plain PowerShell, no obfuscation), downloads pinned official releases verified by SHA256, never adds antivirus exclusions by itself, no telemetry.

**Antivirus:** `winws.exe`/WinDivert are often false-flagged as "HackTool"; the tool explains it and asks you to exclude `C:\ProgramData\zapret-auto`.

License: [GPL-3.0](LICENSE). Third-party components are downloaded at runtime from their official releases and keep their own licenses.

---

<sub>Claude (Anthropic) yardımıyla geliştirildi. / Developed with the help of Claude (Anthropic).</sub>
