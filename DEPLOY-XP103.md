# Deploy Basic Company (Unicorn) lên Sitecore XP 10.3 on-premise (IIS)

Tài liệu này hướng dẫn clone repo, build ví dụ `helix-basic-unicorn` rồi deploy lên một máy Windows đã cài sẵn **Sitecore XP 10.3 Single (XP0)**, kể cả instance trắng mới cài, sau đó sync item bằng Unicorn. Không cần Docker hay xConnect.

**Tóm tắt nhanh** (máy có cả Visual Studio và Sitecore 10.3, PowerShell chạy bằng quyền Administrator):

```powershell
git clone <url-repo> C:\src\basic-company
cd C:\src\basic-company
.\build-package.ps1
.\artifacts\deploy.ps1 -WebRoot C:\inetpub\wwwroot\sc103.dev.local
```

Sau đó: đăng nhập Sitecore → mở `/unicorn.aspx` → **Sync** → Publish → Populate Solr schema + rebuild index → mở `http://basiccompany.local/`. Chi tiết từng bước ở mục 3.

## 1. Những gì đã thay đổi so với bản gốc (Sitecore 10.1 + Docker)

| File | Thay đổi | Lý do |
|---|---|---|
| `Packages.props` | `PlatformVersion` 10.1.0 → **10.3.0**; `Microsoft.Extensions.DependencyInjection` / `Logging` 2.2.0 → **6.0.0**; bỏ `Sitecore.Nexus` | Sitecore.Kernel 10.3 phụ thuộc MEDI 6.0.0 (để 2.2.0 sẽ lỗi restore NU1605). Package `Sitecore.Nexus` không còn được phát hành từ 10.2, Kernel tự kéo theo `Sitecore.Nexus.Consumption`. |
| `src/Feature/*/tests/*.csproj` | Bỏ `<PackageReference Include="Sitecore.Nexus" />` | Như trên. |
| `nuget.config` | Feed `sitecore.myget.org` → `https://nuget.sitecore.com/resources/v3/index.json` | Package 10.3 chỉ có trên feed mới. |
| `Foundation.Serialization.config` | Bỏ các biến môi trường Docker (`ITEM_SYNC_LOCATION`, `UNICORN_ENABLE_TRANSPARENT_SYNC`, `UNICORN_SHARED_SECRET`); `sourceFolder` = `~/App_Data/unicorn` | Trên IIS không có các biến này nên config bị rỗng hoặc lỗi. Đường dẫn tương đối theo web root chạy được trên mọi máy. |
| `Website.wpp.targets` | File `.yml` được publish vào `App_Data\unicorn\<Layer>\<Module>\serialization\...` | Khớp với `physicalRootPath` trong `Foundation.Serialization.Base.config`. |
| `Project.BasicCompany.config` | `hostName="$(env:BASIC_COMPANY_URL)"` → `basiccompany.local` | Bỏ phụ thuộc biến môi trường. |
| **Mới** `src/Environment/Website/App_Config/Include/zzz/BasicCompany.Environment.config` | Gom mọi thiết lập theo môi trường vào một file | Xem mục 4. |
| `Properties/PublishProfiles/Local.pubxml` | Publish ra `.\artifacts\website` | Không còn dùng thư mục `docker\deploy`. |
| **Mới** `build-package.ps1`, `deploy.ps1` | Đóng gói trên máy dev, deploy trên máy Sitecore | Thay cho bước Docker build và transform. |
| **Mới** `.gitattributes` | `*.yml -text`, `*.dll binary` | Clone trên máy có `core.autocrlf` khác nhau vẫn giữ nguyên item Unicorn và `MicroCHAP.dll`. |

Không đổi:
- **Unicorn giữ bản 4.1.4.** Config trong repo (`Unicorn.AutoPublish.config`, `ignoreBranchId` trong `Unicorn.config`) được viết cho 4.1.4. Bản 4.1.6 đã đổi tên hoặc bỏ các setting đó.
- `Unicorn.DataProvider.10.1.config` vẫn đúng cho 10.2 và 10.3, vì cách đăng ký data provider không đổi từ 10.1.
- Code C# build trên 10.3 không có lỗi và không có cảnh báo API obsolete.

> Toàn bộ phần Docker của bản gốc (`docker\`, `docker-compose*.yml`, `Dockerfile`, `.env`, `init.ps1`) đã được xoá. Module Unicorn remote sync (`Unicorn.psm1`, `MicroCHAP.dll`) chuyển sang `tools\unicorn\`.

## 2. Yêu cầu

**Máy dev (build):**
- Visual Studio 2019/2022 hoặc Build Tools, có workload *ASP.NET and web development* (cần MSBuild và `Microsoft.Web.XmlTransform.dll`).
- .NET Framework 4.8 Developer Pack.
- Truy cập được `api.nuget.org` và `nuget.sitecore.com`.

**Máy Sitecore (đích):**
- Sitecore XP 10.3.x Single (XP0) đã cài và chạy được, có Solr. Instance trắng là đủ.
- Biết đường dẫn web root, ví dụ `C:\inetpub\wwwroot\sc103.dev.local`. Đường dẫn phải **≤ 80 ký tự**, xem mục 6.
- PowerShell 5.1, chạy bằng quyền Administrator.

## 3. Các bước deploy

Máy dev và máy Sitecore có thể là **cùng một máy** (thường gặp nhất khi tự cài local) hoặc hai máy khác nhau. Các bước giống nhau, chỉ khác ở chỗ có copy file zip hay không.

### 3.0 Lấy source

```powershell
git clone <url-repo> C:\src\basic-company
cd C:\src\basic-company
```

- Nên clone vào đường dẫn ngắn (ví dụ `C:\src\...`), tránh lỗi đường dẫn dài của Windows khi build.
- File `.gitattributes` giữ nguyên các file `.yml` của Unicorn như lúc commit, bất kể `core.autocrlf` của từng máy. Không cần chỉnh gì thêm.
- Repo **không** chứa `artifacts\`, `bin\`, `obj\` hay file zip. Mỗi người tự build.

### 3.1 Build gói

```powershell
.\build-package.ps1
```

Nếu PowerShell chặn script (`running scripts is disabled on this system`), chạy một lần trong cửa sổ hiện tại:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

Kết quả gồm thư mục `artifacts\` và file `BasicCompany-Unicorn-<ngày-giờ>.zip`:

```
website\      dll, view, config, css/js, App_Data\unicorn\**\*.yml (194 item)
transforms\   XDT của các module (Layers.config, Views\Web.config)
tools\        Microsoft.Web.XmlTransform.dll, Unicorn.psm1, MicroCHAP.dll
deploy.ps1
```

DLL của Sitecore **không** nằm trong gói (Helix Publishing Pipeline đã loại ra), nên không ghi đè `bin` của instance.

### 3.2 Deploy trên máy Sitecore

Mở PowerShell bằng quyền **Administrator**:
- **Cùng một máy:** không cần zip, chạy thẳng `.\artifacts\deploy.ps1 ...` từ thư mục repo (các ví dụ bên dưới viết `.\deploy.ps1`, thay bằng `.\artifacts\deploy.ps1`).
- **Hai máy khác nhau:** copy file zip sang máy Sitecore, giải nén, rồi `cd` vào thư mục vừa giải nén. Nếu Windows đánh dấu file tải về là bị chặn, chạy `Get-ChildItem -Recurse | Unblock-File` trong thư mục đó.

`-WebRoot` là thư mục vật lý của site Sitecore trong IIS (thư mục chứa `bin\Sitecore.Kernel.dll`). Không nhớ thì xem trong IIS Manager → Sites → chọn site → *Basic Settings* → *Physical path*, hoặc chạy `Get-Website | Select Name, PhysicalPath`.

Chọn một trong hai cách.

**Cách A: sync bằng tay qua giao diện (đơn giản nhất)**

```powershell
.\deploy.ps1 -WebRoot C:\inetpub\wwwroot\sc103.dev.local
```

Sau đó đăng nhập `https://sc103.dev.local/sitecore`, mở `https://sc103.dev.local/unicorn.aspx` và bấm **Sync** (sync tất cả configuration).

**Cách B: deploy và sync tự động**

```powershell
.\deploy.ps1 -WebRoot C:\inetpub\wwwroot\sc103.dev.local `
    -UnicornSecret "<chuỗi ngẫu nhiên dài ít nhất 64 ký tự>" -Sync
```

Script sẽ ghi secret vào `App_Config\Include\zzz\BasicCompany.UnicornSecret.config`. Nó chờ Sitecore khởi động lại rồi chạy sync qua binding `https` của site IIS. Nếu không tự đoán được URL, thêm tham số `-CmUrl https://sc103.dev.local`.

Script `deploy.ps1` thực hiện các việc sau:
1. Copy `website\` vào web root. Riêng `App_Data\unicorn` được mirror, nên item bị xoá trong source cũng bị xoá trên server.
2. Áp dụng XDT:
   - `App_Config\Layers.config`: nạp `Rainbow.config` và thư mục `Unicorn` trước Foundation/Feature/Project. **Bắt buộc**, thiếu bước này Unicorn sẽ nạp sau các module.
   - `Views\Web.config`: thêm namespace `BasicCompany.Foundation.FieldRendering`.
   - Lần chạy đầu, file gốc được lưu thành `*.basiccompany-original`. Các lần sau transform lại từ file gốc, nên chạy lại bao nhiêu lần cũng không bị nhân đôi entry.
3. Ghi host name vào `BasicCompany.Environment.config`, thêm binding IIS `http://basiccompany.local` và thêm dòng `127.0.0.1 basiccompany.local` vào file hosts. Dùng `-SkipBinding` nếu muốn tự làm (xem mục 3.3).

### 3.3 Cấu hình `basiccompany.local` (hosts file + IIS binding)

Site Basic Company chạy **trong cùng site IIS với Sitecore**: Sitecore nhận request rồi chọn site `basic-company` dựa vào host name trên URL. Vì vậy cần hai thứ:
1. Tên `basiccompany.local` trỏ về máy mình (file hosts).
2. Site IIS của Sitecore nhận request có host `basiccompany.local` (binding).

`deploy.ps1` tự làm cả hai (trừ khi dùng `-SkipBinding`). Muốn làm tay hoặc kiểm tra lại thì làm như sau.

**Bước 1: thêm vào file hosts**

Cách 1, bằng Notepad:
1. Mở Start, gõ `Notepad`, chuột phải → **Run as administrator**.
2. *File → Open* → `C:\Windows\System32\drivers\etc\hosts` (đổi bộ lọc sang *All Files* mới thấy file).
3. Thêm dòng sau vào cuối file, rồi lưu:

```text
127.0.0.1    basiccompany.local
```

Cách 2, bằng PowerShell (Administrator):

```powershell
Add-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Value "127.0.0.1`tbasiccompany.local" -Encoding ASCII
```

**Bước 2: thêm binding cho site IIS của Sitecore**

Cách 1, bằng IIS Manager:
1. Mở **IIS Manager** (`inetmgr`) → *Sites* → chọn site Sitecore (ví dụ `sc103.dev.local`).
2. Bên phải bấm **Bindings…** → **Add…**
3. Type `http`, IP address `All Unassigned`, Port `80`, Host name `basiccompany.local` → OK.

Cách 2, bằng PowerShell (Administrator), thay `sc103.dev.local` bằng tên site IIS của bạn:

```powershell
Import-Module WebAdministration
New-WebBinding -Name "sc103.dev.local" -Protocol http -Port 80 -HostHeader "basiccompany.local"
```

**Bước 3: kiểm tra**

```powershell
ipconfig /flushdns
ping basiccompany.local
```

Lệnh `ping` phải trả về `127.0.0.1`. Sau đó mở `http://basiccompany.local/` (nhớ gõ `http://`, không phải `https://`).

Lưu ý:
- Nếu dùng **host name khác**, ví dụ `company.dev.local`, hãy truyền `-HostName company.dev.local` cho `deploy.ps1`. Host trong file hosts, binding IIS và `hostName` trong `BasicCompany.Environment.config` phải **giống hệt nhau**.
- Máy dùng proxy công ty: thêm `*.local` vào danh sách bypass proxy (Windows Settings → Network → Proxy), nếu không trình duyệt sẽ gửi request ra proxy.
- Không đặt binding `basiccompany.local` cho site IIS nào khác, vì IIS sẽ báo trùng binding.

### 3.4 Sync Unicorn (nếu dùng cách A)

1. Đăng nhập `https://sc103.dev.local/sitecore` bằng tài khoản admin.
2. Mở `https://sc103.dev.local/unicorn.aspx`.
3. Bấm **Sync** ở trên cùng (sync tất cả configuration). Lần đầu mất khoảng 1–2 phút, kết thúc bằng thông báo thành công và không có dòng lỗi màu đỏ.

Cách B đã sync sẵn trong lúc chạy `deploy.ps1`, có thể bỏ qua bước này.

### 3.5 Sau khi sync (chỉ làm lần đầu)

1. **Publish:** Content Editor → *Publish* → *Publish site*, chọn *Smart publish* với target `web`. Unicorn AutoPublish đã publish các item vừa sync, bước này để chắc chắn.
2. **Solr:** Control Panel → *Indexing* → **Populate Solr Managed Schema** → chọn tất cả → Populate. Cần bước này vì feature Products thêm computed field `_templates`.
3. **Index:** Control Panel → *Indexing Manager* → rebuild `sitecore_master_index` và `sitecore_web_index`. Trang *Products* tìm sản phẩm bằng Content Search.
4. Mở `http://basiccompany.local/`.

Những lần deploy sau, chỉ cần chạy lại `build-package.ps1` và `deploy.ps1`, rồi Sync và Publish. Bước Solr chỉ làm lại khi có thay đổi về index.

## 4. Config cần chỉnh theo môi trường

Mọi thiết lập theo môi trường nằm trong **`src/Environment/Website/App_Config/Include/zzz/BasicCompany.Environment.config`**. File này nằm trong thư mục `zzz` nên được nạp sau cùng và ghi đè config của các module.

| Thiết lập | Mặc định | Khi nào đổi |
|---|---|---|
| `site[@name='basic-company']/@hostName` | `basiccompany.local` | Đổi bằng tham số `deploy.ps1 -HostName ten.host`, không cần sửa file. Nhiều host thì ngăn cách bằng `\|`. |
| `sc.variable sourceFolder` (đang comment) | `~/App_Data/unicorn` | Trên máy dev, trỏ về thư mục `src` để *Reserialize* ghi ngược vào source. |
| `enableTransparentSync` | `false` | Đặt `true` nếu muốn Sitecore đọc item thẳng từ file `.yml`, không cần Sync (chỉ nên dùng cho dev). |
| `authenticationProvider/SharedSecret` (đang comment) | không có | Dùng cho sync từ script. Thường để `deploy.ps1 -UnicornSecret` tạo file riêng. |

Lưu ý:
- `deploy.ps1` ghi đè `BasicCompany.Environment.config` mỗi lần deploy, rồi chỉ ghi lại host name. Thay đổi nào khác cần giữ lâu dài thì sửa trong **source** rồi build lại gói.
- Ngoài file này **không cần sửa** `web.config`, `ConnectionStrings.config` hay config nào của Sitecore. Code dùng connection string, Solr core và Identity Server sẵn có của instance.
- Site `basic-company` được khai báo `patch:before` site `website`, kế thừa `website` (`inherits="website"`). Root là `/sitecore/content/Basic Company`, trang chủ là `/Home`.

## 5. Kiểm tra sau deploy

| Kiểm tra | Kỳ vọng |
|---|---|
| `https://<cm>/unicorn.aspx` | Có các configuration `Foundation.*`, `Feature.*`, `Project.BasicCompany`. Sync không báo lỗi. |
| Content Editor | Có `/sitecore/content/Basic Company/Home`, cùng `/sitecore/templates/{Foundation,Feature,Project}/...` |
| `http://basiccompany.local/` | Trang chủ có header, hero và footer. |
| `http://basiccompany.local/Products` | Có danh sách sản phẩm. Nếu rỗng, xem lại mục 3.5 bước 2–3. |
| `App_Data\logs\log.*.txt` | Không có lỗi `Unicorn`, `Rainbow` hay `Could not load type`. |

## 6. Lỗi thường gặp

| Triệu chứng | Nguyên nhân / Cách xử lý |
|---|---|
| `The physical root path of this SFS tree ... is longer than the configured max base path length 150` | Web root dài hơn 80 ký tự. Trỏ `sourceFolder` sang một thư mục ngắn hơn (ví dụ `C:\unicorn`) trong `BasicCompany.Environment.config`, rồi copy `App_Data\unicorn\*` sang đó. |
| Restore báo `Unable to find package Sitecore.Kernel 10.3.0` | `nuget.config` vẫn trỏ feed cũ, hoặc máy dev không ra được internet. |
| `/unicorn.aspx` bắt đăng nhập lại liên tục | Thiếu `Unicorn.UI.IdentityServer.config`, hoặc instance không dùng Identity Server. Kiểm tra file có trong `App_Config\Include\Unicorn`. |
| Sync báo *parent does not exist* | `Layers.config` chưa được transform, khiến Unicorn nạp sai thứ tự. Chạy lại `deploy.ps1` và kiểm tra `App_Config\Layers.config` có `<add path="Unicorn" type="Folder"/>`. |
| `http://basiccompany.local` trả về trang Sitecore mặc định | Host name không khớp. Làm lại mục 3.3: kiểm tra binding IIS, file hosts và giá trị `hostName` trong `BasicCompany.Environment.config` (phải dùng đúng tên trên URL). |
| Sync tự động báo `401` / `Authentication failed` | Sitecore chưa nạp file secret (đợi app pool khởi động lại xong), hoặc secret truyền vào `-UnicornSecret` khác giá trị trong file. |
| Trang Products rỗng | Chưa populate schema hoặc chưa rebuild index (mục 3.5). |
| Nâng cấp Sitecore (10.3.x lên bản mới hơn) xong, `Layers.config` mất cấu hình Unicorn | Xoá các file `*.basiccompany-original` rồi chạy lại `deploy.ps1`, để script lưu lại bản gốc mới. |

## 7. Unit test

Các test dùng `Sitecore.FakeDb` nên cần license Sitecore. Đặt `license.xml` theo đường dẫn trong `src/Feature/*/tests/app.config` (`LicenseFile`), hoặc sửa đường dẫn đó. Nếu không có license, 14/15 test sẽ lỗi ở `LicenseManager`. Đây không phải lỗi code.
