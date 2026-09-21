# Gauge

โปรแกรมมอนิเตอร์ระบบบน menu bar ของ macOS — ทางเลือกทดแทน iStat Menus ที่อ่านค่าทุกอย่างจากเครื่องโดยตรง
ไม่มี license server ไม่มี telemetry และไม่ต่อเน็ตเลยจนกว่าจะเปิดใช้เองเป็นรายฟีเจอร์

สร้างและทดสอบบน MacBook Pro (Mac17,2 · Apple M5) / macOS 27 / Swift 6.4

---

## สิ่งที่ทำได้

| Module | รายละเอียด |
|---|---|
| **CPU** | โหลดรวม แยก user/system/idle, per-core แยก P-core / E-core, load average, uptime, จำนวน process/thread, top processes |
| **GPU** | Device / Renderer / Tiler utilisation, หน่วยความจำที่ GPU ใช้ |
| **Memory** | App / Wired / Compressed / Cached แยกสี, memory pressure, swap, page-in/out |
| **Disks** | ความจุทุก volume ที่ mount อยู่, อัตรา read/write แบบเรียลไทม์, ยอดสะสมตั้งแต่ boot |
| **Network** | ดาวน์/อัปโหลดเรียลไทม์, peak, ยอดสะสม, ทุก interface พร้อม IP, public IP (ต้องเปิดเอง) |
| **Sensors** | อุณหภูมิ CPU die (เฉลี่ย + สูงสุด), **ความถี่ Efficiency / Super / GPU เป็น GHz**, กราฟอุณหภูมิ CPU, กำลังไฟ, พัดลม, กราฟอุณหภูมิ SSD และอุณหภูมิแบตรวม (เฉลี่ยจากทุกเซลล์) — รายการเซ็นเซอร์ดิบทั้ง 47 ตัวอยู่ใน Settings → Sensors |
| **Battery** | %, health, cycle count, ความจุจริงหน่วย mAh, แรงดัน, กระแส, อุณหภูมิ, เวลาที่เหลือ |
| **Time** | นาฬิกาปรับ format ได้ + world clocks |
| **Weather** | สภาพอากาศปัจจุบัน / รายชั่วโมง / 7 วัน — **ปิดไว้เป็นค่าเริ่มต้น** |
| **Combined** | สรุปทุกอย่างในเมนูเดียว |

แต่ละ module มี menu bar item ของตัวเอง เลือกรูปแบบแสดงผลได้ 5 แบบ: Text, Graph, Text + Graph, Gauge, Icon

**ออกจากโปรแกรม** ได้ 3 ทาง: ปุ่ม power มุมขวาล่างของทุก panel, คลิกขวาที่ไอคอน menu bar → Quit Gauge,
หรือปุ่ม Quit Gauge ใน Settings → About

### กราฟและหน้าตา

Layout เดินตามโครงเดียวกับ iStat Menus: แต่ละ dropdown คือ stack ของ **section** ที่มีหัวข้อ
ค่าปัจจุบันชิดขวา กราฟเต็มความกว้าง แล้วต่อด้วย legend กับช่วงเวลา

**ชนิดกราฟที่มี**

| กราฟ | ใช้ที่ไหน |
|---|---|
| Stacked area | CPU (user/system), Memory (app/wired/compressed) |
| Mirrored | Network (ดาวน์บน–อัปล่าง), Disk (read/write) |
| Area / Line / Columns | เลือกได้ทุก module, Columns ใช้เป็นค่าเริ่มต้นของกราฟกำลังไฟ |
| Ring gauge | GPU, พื้นที่ดิสก์, แบตเตอรี่, พัดลม, หน้า Combined |
| Per-core grid | กราฟประวัติย่อยรายคอร์ (10 ช่องบน M5) แยกสี Super/Efficiency |
| Heat strip | แถบสีไล่ตามอุณหภูมิ CPU ตามเวลา |
| Segmented bar | สัดส่วนหน่วยความจำ ณ ปัจจุบัน |
| Forecast band | ช่วงอุณหภูมิสูง–ต่ำ 7 วัน |
| Hourly bars | โอกาสฝนรายชั่วโมง |

รายการ process มีไอคอนแอปจริงและแถบจัดอันดับตามสัดส่วนการใช้งาน

### เลื่อนเมาส์ดูย้อนหลัง และเลือกช่วงเวลา

ทุกกราฟประวัติ:

- **เอาเมาส์ชี้** จะขึ้นเส้น crosshair พร้อมกล่องบอก **เวลาที่จุดนั้น** (เช่น `10:39:42 · 43m ago`)
  และ**ค่าของทุกเส้น** ณ จุดนั้น ถ้าช่วงนั้นไม่มีข้อมูลจะบอกว่า `no data` ไม่ใช่เดาค่าให้
- **dropdown ข้างชื่อกราฟ** เลือกช่วงเวลาได้ 10 แบบ:
  `10 นาที · 1 · 3 · 6 · 12 ชั่วโมง · 1 · 3 · 7 · 14 · 28 วัน`
  แต่ละกราฟจำค่าของตัวเองแยกกัน (กราฟ CPU ดู 1 ชม. ขณะที่ load average ดู 7 วันได้)
  ตั้งค่าเริ่มต้นรวมได้ที่ Settings → General → Chart history

### ประวัติเก็บยังไงถึงย้อนได้ 28 วัน

ถ้าเก็บดิบทุก 2 วินาที 28 วันคือ 1.2 ล้านจุดต่อ metric — เก็บไม่ไหว จึงเก็บเป็น **3 ชั้น**
โดยแต่ละ bucket เก็บทั้ง **ต่ำสุด / เฉลี่ย / สูงสุด** (ไม่งั้น spike สั้น ๆ จะหายไปตอนซูมออก)

| ชั้น | ความละเอียด | ครอบคลุม | ใช้กับช่วง |
|---|---|---|---|
| live | 2 วินาที | 1 ชั่วโมง | 10m, 1h |
| minute | 1 นาที | 25 ชั่วโมง | 3h, 6h, 12h, 1d |
| quarter | 15 นาที | 28 วัน | 3d, 7d, 14d, 28d |

- รวมทุก metric ประมาณ **2.5 MB** ใน RAM
- ชั้น minute กับ quarter **เซฟลงดิสก์** ที่ `~/Library/Application Support/Gauge/history.gauge`
  ทุก 1 นาทีและตอนปิดแอป ช่วงเวลาระดับวัน/สัปดาห์จึงยังอยู่หลังรีสตาร์ต
  (ชั้น live ไม่เซฟ — ข้อมูล 2 วินาทีเมื่อชั่วโมงก่อนไม่มีประโยชน์แล้ว)
- **ช่วงที่ไม่มีข้อมูล** (เครื่อง sleep หรือปิดแอป) จะเว้นว่างในกราฟ ไม่ลากเส้นผ่านศูนย์
- ต้นทุนการบันทึก **0.01 ms ต่อรอบ** สำหรับ 28 metrics (วัดด้วย `--bench`)

**ปรับได้ที่ Settings → Appearance** (หรือในหน้าของแต่ละ module)

- **สีหลัก / สีรอง** ของกราฟแต่ละ module เลือกเองได้ผ่าน colour picker
- **รูปแบบกราฟ** Area / Line / Columns / Stacked / Mirrored (เลือกได้เท่าที่ module นั้นรองรับ)
- **รูปแบบ fade** 4 แบบ
  - `Fade to clear` — ไล่จากสีไปโปร่งใส (ค่าเริ่มต้น แบบเดียวกับ iStat Menus)
  - `Solid fill` — สีทึบระดับเดียว
  - `Line only` — เส้นอย่างเดียว ไม่มีพื้น
  - `Fade between colours` — ไล่จากสีหลักไปสีรอง
- **ความเข้มของ fade** ปรับได้ 5–100%
- **สลับได้ว่าจะให้ตัวเลขเปลี่ยนสีตามโหลด** (เขียว→เหลือง→ส้ม→แดง) หรือใช้สีที่เลือกไว้ตลอด
- **พื้นหลัง popup** — Liquid Glass ของ macOS 26 (ค่าเริ่มต้น), Liquid Glass แบบใส,
  vibrancy แบบเดิม หรือพื้นทึบ พร้อมปรับ **สี tint**, **ความเข้ม tint**, **ความมนมุม**,
  **เงา** และ **เส้นขอบ** ได้ทั้งหมด มี preview วางบนพื้นหลังลายเพื่อให้เห็นเอฟเฟกต์จริง
  (บน macOS ที่ยังไม่มี Liquid Glass จะถอยไปใช้ vibrancy ให้เอง)
- **ไฮไลต์แถวตอนเอาเมาส์ชี้** เปิด/ปิดได้
- **ความกว้างกราฟบน menu bar** 16–80 pt
- มีตัวอย่างสดในหน้า settings เห็นผลทันทีก่อนกด

ดูหน้าตาทุกแบบได้โดยไม่ต้องเปิดแอป: `Gauge --preview ./out --demo` จะ render ทุก panel
ทุก menubar style ทั้งโหมดสว่างและมืดออกมาเป็น PNG (`--demo` ใส่ข้อมูลตัวอย่างให้กราฟมีรูปร่าง)

---

## ติดตั้ง

```bash
./Scripts/package.sh   # build + สร้าง .dmg และ .pkg พร้อมตรวจสอบผลลัพธ์
open package/          # ไฟล์ติดตั้งอยู่ในโฟลเดอร์ package/ ของโปรเจกต์
```

ได้ 2 แบบให้เลือก:

| ไฟล์ | วิธีใช้ |
|---|---|
| **`Gauge-1.0.dmg`** | ดับเบิลคลิก แล้วลาก Gauge ไปใส่ Applications (มีไอคอน Applications ให้ในหน้าต่างเลย) พร้อมไฟล์ `Read me first.txt` และ `Uninstall Gauge.command` |
| **`Gauge-1.0.pkg`** | ดับเบิลคลิกแล้วกด Next ไปเรื่อย ๆ — ติดตั้งลง `/Applications` ปิดตัวเก่าให้ก่อนและเปิดตัวใหม่ให้อัตโนมัติเมื่อเสร็จ |

สร้างแยกได้: `./Scripts/package.sh dmg` หรือ `./Scripts/package.sh pkg`

### ⚠️ ครั้งแรกที่เปิดต้อง right-click → Open

แอปเซ็นแบบ **ad-hoc** ไม่ได้เซ็นด้วย Developer ID (ต้องสมัคร Apple Developer Program ปีละ $99)
macOS จึงบล็อกการดับเบิลคลิกครั้งแรก วิธีผ่าน:

1. เปิด Applications
2. **คลิกขวา** (หรือ Control-click) ที่ Gauge → **Open**
3. กด Open ยืนยันอีกครั้ง

macOS จะจำไว้ ครั้งต่อไปเปิดปกติ ถ้ายังไม่ยอมให้สั่ง:

```bash
xattr -dr com.apple.quarantine /Applications/Gauge.app
```

### ถอนการติดตั้ง

`Uninstall Gauge.command` ในไฟล์ DMG หรือ `./Scripts/uninstall.sh` — จะถามยืนยันก่อน แล้วลบ
ตัวแอป, preferences, ไฟล์ history, cache, keychain item ของ AccuWeather key และ login item

### build อย่างเดียว ไม่เอา installer

```bash
./build.sh                                  # build + ประกอบ .app + เซ็นแบบ ad-hoc
open ~/.cache/gauge-build/out/Gauge.app     # ลองใช้
```

ต้องมีแค่ **Command Line Tools** (`xcode-select --install`) ไม่ต้องลง Xcode เต็ม

> **ไฟล์ติดตั้ง** (`.dmg` / `.pkg`) อยู่ที่ `package/` ในโปรเจกต์ — หาง่ายและ sync ไปกับ OneDrive
> ด้วย แต่ไม่ถูกเก็บลง git (ดู `.gitignore`)
>
> **ตัว `.app` ที่ build ระหว่างทาง** ไปอยู่ที่ `~/.cache/gauge-build/out/` แทน เพราะมันถูกเขียนทับ
> ทุกครั้งที่ build ถ้าวางไว้ใน OneDrive ตัว sync จะทำงานหนักเปล่า ๆ
> (เปลี่ยนที่ได้ด้วย `GAUGE_OUTPUT=...` และ `GAUGE_PACKAGE_OUTPUT=...`)

### คำสั่งอื่น

```bash
swift run GaugeTests                       # ชุดทดสอบ
APP=~/.cache/gauge-build/out/Gauge.app/Contents/MacOS/Gauge
$APP --dump      # พิมพ์ค่าที่อ่านได้ทั้งหมดหนึ่งรอบ
$APP --preview ./out --demo        # render ทุก panel/menubar เป็น PNG
$APP --weather "Bangkok"           # ทดสอบ weather provider
$APP --bench                       # จับเวลาการอ่านค่าแต่ละตัว
$APP --history-stats               # ดูว่าแต่ละช่วงเวลามีข้อมูลกี่จุด
$APP --map-sensors --save          # calibrate เซ็นเซอร์จาก CLI (~2 นาที)
$APP --panel cpu 20                # เปิด dropdown จริงบนจอ 20 วินาที
swift Scripts/make-icon.swift              # สร้างไอคอนใหม่
```

---

## เซ็นเซอร์ไหนคือ CPU จริง — วัดเอา ไม่ใช่เดา

Apple ไม่เคยประกาศว่าเซ็นเซอร์ชื่อ `PMU tdie7` วัดอะไร แอปมอนิเตอร์ทั่วไปจึงเดาเอา
Gauge ใช้วิธีวัดแทน: สั่งโหลดทีละคลัสเตอร์ (ผ่าน thread QoS — งาน background จะถูกจำกัดให้อยู่บน
efficiency core ส่วนงาน user-interactive จะวิ่งบนคอร์เร็ว) แล้วดูว่าเซ็นเซอร์ตัวไหนร้อนตาม

ผลบน Mac17,2 (M5):

| กลุ่มเซ็นเซอร์ | Δ ตอนโหลด Efficiency | Δ ตอนโหลด Super | สรุป |
|---|---|---|---|
| `PMU tdie1–14` | +6.9 ถึง +13.3 °C | +8.5 ถึง +19.5 °C | **ได compute ของ CPU** |
| `PMU2 tdie1–10` | +0.2 ถึง +1.0 °C | +0.9 ถึง +1.3 °C | คนละบริเวณ ไม่ใช่ CPU |
| `NAND CH0` | +3.0 °C | −2.3 °C | SSD (ร้อนจาก I/O ไม่ใช่ CPU) |

ผลที่ตามมา 2 อย่าง:

1. **ค่า "CPU temperature" เฉลี่ยเฉพาะ `PMU tdie*`** — ตอนแรกโค้ดเฉลี่ยรวม PMU2 เข้าไปด้วย
   ทำให้ค่าต่ำกว่าจริงราว 6–8 °C (แสดง 51 °C ทั้งที่ของจริง 59.6 °C)
2. **ไม่ map เซ็นเซอร์เป็นรายคอร์** ความร้อนกระจายทั่วได เซ็นเซอร์ทุกตัวขยับตามทั้งสองคลัสเตอร์
   (`tdie1` เอียงไปทาง Super ที่ ΔP/ΔE ≈ 1.9 ส่วน `tdie8` เอียงไป Efficiency ที่ ≈ 0.9 — ไม่แยกขาดพอ)
   Gauge จึงรายงาน **ค่าเฉลี่ยของได** กับ **ค่าสูงสุด** แทนการอ้างว่ารู้อุณหภูมิรายคอร์

รันซ้ำบนเครื่องคุณเองได้ด้วย `Gauge --map-sensors`

ส่วนชื่อคลัสเตอร์ CPU เอามาจากระบบตรง ๆ (`hw.perflevel0.name`) — บน M5 คือ **Super** กับ
**Efficiency** ไม่ใช่ P/E ที่ hard-code ไว้ และรู้ว่าคอร์ไหนอยู่คลัสเตอร์ไหนจาก `cluster-type`
ใน IORegistry ไม่ใช่การเดาลำดับ

### Calibrate ในตัวแอป

**Settings → Sensors → Calibrate sensors…** จะรันการทดลองข้างบนให้บนเครื่องของคุณเอง
(ราว 2 นาที เครื่องจะทำงานหนักตลอดช่วงนั้น กดยกเลิกได้) เมื่อเสร็จแล้ว:

- เซ็นเซอร์จะถูกจัดกลุ่มใหม่เป็น **"Super Core Area N"** และ **"Efficiency Core Area N"**
  ตามคลัสเตอร์ที่วัดได้ว่ามันตอบสนองมากกว่า ส่วนตัวที่ตอบสนองพอ ๆ กันจะขึ้นว่า "Shared Die N"
- panel จะแสดงอุณหภูมิเฉลี่ยแยกรายคลัสเตอร์
- มีตารางผลการวัดให้ดูว่าแต่ละตัวขยับกี่องศาตอนโหลดคลัสเตอร์ไหน
- ผลเก็บไว้ผูกกับรุ่นเครื่อง ถ้าย้ายไฟล์ settings ไปเครื่องอื่นจะไม่ถูกนำมาใช้

ย้ำอีกครั้งว่านี่คือ **affinity ที่วัดได้ ไม่ใช่การ map รายคอร์** — ความร้อนกระจายทั่วได
เซ็นเซอร์ทุกตัวจึงขยับตามทั้งสองคลัสเตอร์ การแบ่งคือดูว่าคลัสเตอร์ไหนทำให้มันขยับมากกว่า

---

## ประสิทธิภาพ

ตัวมอนิเตอร์ที่กินแรงกว่าสิ่งที่มันเฝ้าดูก็ไม่มีประโยชน์ `--bench` จับเวลาแต่ละ collector:

| collector | ตอนเปิด panel | ตอนพับอยู่ (ปกติ) |
|---|---|---|
| Sensors | 43 ms | 16 ms ทุก 4 วินาที |
| Network | 13.6 ms | 1.3 ms |
| Disk | 6.2 ms | 0.07 ms |
| GPU | 0.8 ms | 0.8 ms |
| CPU + Memory | 0.01 ms | 0.01 ms |
| Processes | 1.9 ms | ทุก 15 วินาที |

วิธีที่ใช้ลด: เก็บชื่อ interface ไว้ใน cache (ทั้งกรณีเจอและไม่เจอ), ใช้ `inet_ntop` แทน
`getnameinfo`, อ่าน volume capacity ทุก 10 วินาทีแทนทุก tick, อ่านเซ็นเซอร์เฉพาะที่ menu bar
ใช้จริงตอนไม่มี panel เปิด และไม่ตั้งภาพ menu bar ใหม่ถ้าเนื้อหาไม่เปลี่ยน (AppKit จะสร้าง
snapshot ใหม่ทุกครั้งที่ตั้งภาพ)

ผลจริง: **~1% CPU และ 24 MB RSS** ตอนพับอยู่ (เดิม 3.7% / 100 MB)

---

## เรื่องความเป็นส่วนตัว

นี่คือจุดที่ตั้งใจออกแบบให้ต่างจาก iStat Menus ชัด ๆ

**ค่าเริ่มต้น Gauge ไม่ส่งอะไรออกนอกเครื่องเลย** ไม่มีการเช็ก license ไม่มีการเช็กอัปเดต ไม่มี analytics

มีแค่ 2 อย่างที่ต่อเน็ต และทั้งคู่ **ปิดไว้จนกว่าจะเปิดเอง**:

1. **Weather** — ส่งเฉพาะพิกัดที่เลือกไปยัง provider
   - `Open-Meteo` (ค่าเริ่มต้น) — ฟรี ไม่ต้องสมัคร ไม่ต้องใช้ API key ไม่มี user id ในคำขอ
   - `AccuWeather` (ทางเลือก) — ต้องใช้ API key ซึ่งเก็บใน **Keychain** ไม่ใช่ไฟล์ preferences
   - แอปไม่ขอสิทธิ์ Location Services — ผู้ใช้พิมพ์ชื่อเมืองเอง
2. **Public IP** — ยิงไปที่ endpoint ที่แก้ URL ได้เอง อย่างมากทุก 15 นาที

> **ถาม: weather จำเป็นไหม?**
> ไม่จำเป็นต่อการมอนิเตอร์ระบบเลย มันเป็นฟีเจอร์เดียวที่บังคับให้ต้องต่อเน็ตและเปิดเผยตำแหน่ง
> จึงแยกออกมาเป็น opt-in แทนที่จะฝังรวมไปกับ module อื่น เปิดใช้ก็ได้ ไม่เปิดแอปก็ทำงานครบทุกอย่าง

---

## แหล่งข้อมูลของตัวเลขแต่ละตัว

| ข้อมูล | API ที่ใช้ |
|---|---|
| CPU, memory | Mach `host_processor_info` / `host_statistics64` |
| Processes | `libproc` (`proc_listpids`, `proc_pid_rusage`) |
| GPU | IORegistry `IOAccelerator` → `PerformanceStatistics` |
| Disks | `IOBlockStorageDriver` counters + `URLResourceValues` |
| Network | routing socket `NET_RT_IFLIST2` + `SCDynamicStore` |
| อุณหภูมิ | `IOHIDEventSystemClient` (Apple Silicon) / SMC keys (Intel) |
| พัดลม, กำลังไฟ | SMC ผ่าน `AppleSMC` user client |
| Battery | `IOPowerSources` + `AppleSmartBattery` + SMC gas gauge |
| ความถี่ CPU/GPU | `IOReport` DVFS residency × ตาราง `voltage-states` ใน pmgr |

ไม่ต้องใช้สิทธิ์ root และไม่ต้องติดตั้ง daemon (ต่างจาก iStat Menus ที่รัน daemon เป็น root)

---

## โครงสร้างโค้ด

```
Sources/
  CGaugeSMC/        C shim สำหรับ SMC — struct ต้องเป็น 80 ไบต์พอดี
                    ซึ่ง Swift จัด layout ให้เป็น 76 (ดูคอมเมนต์ใน header)
  GaugeKit/         ตัวอ่านค่าทั้งหมด + settings + weather provider
    SMC.swift       ถอดรหัสค่า SMC (little-endian บน Apple Silicon)
    Sensors.swift   IOHID + SMC, จัดกลุ่มและตั้งชื่อเซ็นเซอร์ให้อ่านรู้เรื่อง
    CPU/Memory/Disk/Network/GPU/Battery/Processes.swift
    Weather.swift   Open-Meteo + AccuWeather หลัง protocol เดียวกัน
    MonitorHub.swift  timer เดียว sampling รอบเดียว แจกให้ทุก module
  Gauge/            แอป AppKit + SwiftUI
    Menubar/        วาด menu bar เป็น NSImage (text / graph / gauge / icon)
    Panels/         dropdown ของแต่ละ module
    Settings/       หน้าตั้งค่า
  GaugeTests/       ชุดทดสอบ (executable — ดูหมายเหตุด้านล่าง)
```

---

## หมายเหตุทางเทคนิค 3 ข้อ

สามเรื่องนี้เกิดจากการ build ด้วย Command Line Tools อย่างเดียว บันทึกไว้กันลืม

1. **`@State` ใช้ไม่ได้** — ใน SDK ของ macOS 26 ขึ้นไป `@State` เป็น macro ที่ต้องใช้ plugin
   `SwiftUIMacros` ซึ่งมากับ Xcode เท่านั้น โค้ดจึงใช้ `UIState<Value>` (ObservableObject เล็ก ๆ)
   คู่กับ `@StateObject` แทน — ได้ lifetime และ `Binding` เหมือนกันทุกประการ
   (`@ObservedObject`, `@Binding`, `@StateObject`, `@Environment` ใช้ได้ปกติ)

2. **ไม่มี XCTest** — มากับ Xcode เช่นกัน ชุดทดสอบจึงเป็น executable ที่มี harness ของตัวเอง
   `swift run GaugeTests` คืน exit code 0 เมื่อผ่านหมด ปัจจุบัน 42 tests / 174 checks

3. **SMC struct ต้องอยู่ใน C** — user client ของ SMC ต้องการ struct ขนาด 80 ไบต์เป๊ะ ๆ
   แต่ Swift จัดให้เป็น 76 (มันยัด field ถัดไปลงใน tail padding ของ `SMCKeyInfoData`)
   ทำให้ทุกคำขอถูกปฏิเสธเงียบ ๆ จึงต้องเก็บ struct ไว้ฝั่ง C

4. **dropdown ไม่ได้ใช้ NSPopover** — NSPopover วาดพื้นหลังทึบกับหัวลูกศรของตัวเองทับสิ่งที่
   content วางไว้ข้างหลัง รวมถึง Liquid Glass ด้วย จึงเปลี่ยนไปใช้ borderless `NSPanel`
   พื้นหลังใส แล้วให้ material เป็นพื้นหลังเอง (ได้ควบคุมความมนมุมกับเงาด้วย)
   ผลข้างเคียงที่ต้องกัน: คลิกไอคอนตอน panel เปิดอยู่จะทำให้ panel เสีย key แล้วปิดตัวเอง
   *ก่อน* action ของปุ่มจะทำงาน ถ้าไม่กันไว้จะเด้งเปิดใหม่ทันที

5. **Liquid Glass ไม่ปรากฏในภาพ preview** — window server เป็นคน composite ให้
   การ render ลง bitmap นอกจอจึงได้พื้นโปร่งเปล่า ๆ `--preview` เลยบังคับใช้พื้นทึบ
   ถ้าจะดู material จริงต้องใช้ `--panel <module>` ที่เปิดหน้าต่างจริงบนจอ

> คอมเมนต์ในโค้ดเขียนเป็นภาษาอังกฤษตามธรรมเนียมของโปรเจกต์ Swift — ถ้าอยากให้แปลเป็นไทยบอกได้

---

## ที่ยังไม่ได้ทำ

พูดตรง ๆ ว่ายังไม่เท่า iStat Menus ทุกจุด สิ่งที่ยังขาด:

- **ควบคุมความเร็วพัดลม** — โค้ดอ่าน/เขียน SMC พร้อมแล้ว (`SMC.write`) แต่การเขียนคีย์ `F0Md`/`F0Tg`
  ต้องมีสิทธิ์ที่แอปไม่มี ทำได้ต้องลง privileged helper เป็น root ซึ่งเป็นสิ่งที่ตั้งใจเลี่ยง
- **Notifications** — ยังไม่มีระบบตั้งกฎแจ้งเตือน (เช่น CPU เกิน 90% นาน 1 นาที)
- **บันทึกประวัติลงดิสก์** — history เก็บใน memory เท่านั้น ปิดแอปแล้วหาย
- **ลากจัดลำดับ menu bar item** — มี field `order` รองรับแล้ว แต่ยังไม่มี UI ลากจัด
- **Astronomy / ISS tracking** — ตัดออก เพราะเป็นของเล่นที่ไม่เกี่ยวกับการมอนิเตอร์ระบบ
