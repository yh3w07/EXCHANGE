# Clock latency analysis — v2.0

在已載入設計的 PrimeTime session 執行：

```tcl
source /your/path/cg_clock_latency.tcl
::cg_latency::run -max_level 3 -out_dir ./cg_latency_v2
```

只輸出兩份報告：

| 檔案 | 內容 |
|---|---|
| `hierarchy.rpt` | 每層 block 的 clock input、DFF／latch 數量、平均與中位 latency |
| `estimated_latency.rpt` | 依負載數量級分組的 latency，以及擬合公式 |

## 掃描規則

- TOP 為第 1 層，只作報告標題；**從 TOP 下的 sub-block（第 2 層）開始分析**。
- `-max_level 3` 分析第 2、3 層；`0` 分析所有 sub-block 層級。
- 起點只使用各 block 介面上 **`clocks` attribute 非空的 input／inout pin**。
- 不從 TOP port 開始、不依名稱猜 clock、不列 non-clock pin。
- 每個入口統計該 block 內全部後代 DFF／latch；macro 不計。掃描深度不截斷後代負載。
- 同一入口內，同一 sequential cell 只計一次；父子 block 或不同入口可以重複納入。
- Latency 使用相同 clock／來源 edge 的 `arrival` 差值，內部合併 rise／fall；所有結果轉為 ns。
- 預設 `max`。Corner 使用目前 session，不另外切換。
- 每個入口內，以 1.5×IQR 排除 latency 離群值；少於 8 筆或 IQR 為 0 時保留。排除離群值不減少負載數。

## 報告範例

```text
TOP
  BLK_A (level 2)
    (hclk, DFF: 3333, Latch: 0, Average latency: 0.6700 ns, Median latency: 0.7000 ns)
    SUB_BLK_A (level 3)
      (hclk, DFF: 1111, Latch: 0, Average latency: 0.4000 ns, Median latency: 0.5000 ns)
```

預估報告以 DFF＋latch cell 數量分組，使用各入口的中位 latency 歸納公式；父子樣本全部保留。資料不足時會標示，並保留分組結果，不強行給公式。

## 選項

| 選項 | 預設 | 說明 |
|---|---|---|
| `-max_level` | `3` | 分析第 2 層至指定層；`0` 表示全部 sub-block 層級 |
| `-out_dir` | 自動建立新目錄 | 兩份報告的存放位置；同名報告會覆寫 |
| `-delay_type` | `max` | `max` 或 `min` |

## 執行與驗證

- Console 只顯示準備階段及各 clock input 的開始／完成；不產生 CSV、逐 pin 明細或模型匯出檔。
- 開始時仍需準備內部 pin arrival 並更新 timing，這一步作用於目前 design。之後才逐一從 sub-block clock input 追蹤。
- 若 arrival 無法配對，保留負載數、標示 missing，該筆不參與公式；ideal clock 也不參與公式。
- 同 clock 多入口匯合時，arrival 差值是 envelope 的差，不保證等於指定入口的獨立 path delay。
- 已以 Tcl runtime／模擬 collections 驗證；本機無 `pt_shell`，尚未以真實 IC database 驗證。
