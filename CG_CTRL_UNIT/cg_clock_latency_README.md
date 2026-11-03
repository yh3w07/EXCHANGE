# PrimeTime Clock Latency Analysis

版本：1.0。使用已載入、已設定 clocks／parasitics 的 `current_design`。

## 執行

把 `cg_clock_latency.tcl` 複製到執行 PrimeTime 的機器，在現有 `pt_shell` session 執行：

```tcl
source /your/path/cg_clock_latency.tcl
::cg_latency::run -max_level 3 -out_dir ./cg_latency_results
```

- `source` 只載入指令，不會自動掃描設計。
- `TOP` 是第 1 層；範例掃描第 1～3 層。`-max_level 0` 掃描全部階層。
- 預設使用 `max`，讀取目前分析環境；不切換 corner，也不修改 clock constraints。
- 建議先跑 `-max_level 2` 檢查報表及 coverage，再擴大階層。
- 輸出目錄若已有同名報表會停止。需要覆寫時明確加上 `-overwrite 1`。

```tcl
# 全部階層
::cg_latency::run -max_level 0 -out_dir ./cg_latency_all

# 改用 min
::cg_latency::run -max_level 3 -delay_type min -out_dir ./cg_latency_min

# 指定 clock 名稱（不是 pin 名稱）及額外的 macro 排除規則
::cg_latency::run -max_level 4 -clock_patterns {core_clk* bus_clk*} \
    -exclude_ref_patterns {SRAM* ROM* CUSTOM_MACRO*} -out_dir ./cg_latency_core
```

## 計數與量測規則

| 項目 | 行為 |
|---|---|
| 一筆觀測 | 一個 `(block, clock input)`；TOP 使用 input／inout port，其他 block 使用 interface input／inout pin |
| Clock input 判斷 | 讀取 pin／port 的 `clocks` attribute，不依 pin 名稱猜測 |
| 負載 | `all_registers -edge_triggered -clock_pins` 與 `-level_sensitive -clock_pins` 所識別的 DFF／latch |
| 計數單位 | 唯一 sequential **cell**，不是 bit；multi-bit FF 算一個 cell |
| 子階層 | 包含該 block 內的所有後代負載，即使後代超過掃描深度；深度只限制觀測起點 |
| 同一 cell 多個 clock pin | 單一入口只算一次；彙整該入口可達的 clock pins，max 取較大差值、min 取較小差值 |
| 多入口／父子階層 | 各自保留，全部納入統計及模型；不因共用負載而刪除 |
| Macro | 排除 memory、black box、hierarchical cell、integrated clock-gating cell；自訂 macro 可用排除 patterns 補充 |
| 未被標記的 custom macro | 無法保證自動辨識；請以 `-exclude_ref_patterns` 或 `-exclude_cell_patterns` 指定 |
| Fanout traversal | 使用有效 timing arcs，遵循目前 case analysis／disabled arcs；不是所有實體連線的無條件聯集 |
| 單位 | 自動取得 design time unit，必要時由 library unit 判斷，所有輸出轉成 ns |

量測採用 `arrival_window`。同一個 clock、同一個來源 edge 先在各點合併 rise／fall：max 取較大 arrival、min 取較小 arrival。配對後計算：

```text
delta(clock, source_edge) = sink_clock_pin_arrival - block_input_arrival
cell_latency = max(delta)                 # -delay_type max
cell_latency = min(delta)                 # -delay_type min
```

只配對相同 clock／來源 edge；不把不同 clock 的 arrival 相減，也不加入半個 period。來源 edge 僅用於內部配對，不要求使用者指定 rise／fall。

**這是 arrival envelope 的差值。** 同 clock 經多入口匯合時，sink 的最大 arrival 可能由另一入口決定，因此差值不保證等於經指定入口的 point-to-point path delay。本工具依需求使用 arrival 差值，沒有另外執行每個 sink 的路徑列舉。

Generated-clock source 預設允許繼續 traversal；若下游已變成另一個 clock，且兩端沒有共同的 clock／來源 edge，會保留負載數並標示 `no_common_clock_edge`。不自行推算 master/generated clock 的 edge mapping。也可用 `-continue_generated 0` 將 traversal 停在該邊界。

缺少 window、無共同 clock／edge、明顯負差值，都列為 missing，不替換成 0。若同一 cell 的任何可達 clock pin 無法量測，整個 cell 的 latency 視為 missing，避免只保留其中可用 pin 而低估。`loads.csv` 保留原因。

為取得內部 pin arrival，執行時暫設 `timing_save_pin_arrival_and_slack=true`，然後 `update_timing`。完成或發生 Tcl error 時，恢復原本設定與 `current_instance`。這會增加執行期間的 timing database 記憶體需求。此 attribute 的保存條件見 [Synopsys Variables and Attributes 手冊](https://studylib.net/doc/28580174/pt3)；window 格式亦參考 [Synopsys PrimeTime CAE 的說明](https://www.deepchip.com/items/0451-06.html)。

## 離群值、分組與公式

| 項目 | 預設行為 |
|---|---|
| 離群值範圍 | 每個 `(block, clock input)` 內的 cell latency |
| 排除方法 | 低於 `Q1 − 1.5×IQR` 或高於 `Q3 + 1.5×IQR` |
| 小樣本 | 少於 8 筆不排除；IQR 接近 0 時也不排除，並標示原因 |
| Fanout 數量 N | 全部唯一 DFF＋latch cells；missing／outlier **不減少 N** |
| 平均／中位數／P10／P90 | 使用排除離群值後的 latency；quantile 採 `(n−1)×p` 線性插值 |
| Coverage | 有效量測 cell 數／N，計算於 IQR 排除之前 |
| 模型資格 | 有 retained latency、clock 已 propagated，且 coverage 達門檻；預設必須 100% |
| 數量級分組 | 1–2–5 sequence：如 `[1000,2000)`、`[2000,5000)`、`[5000,10000)` |
| 每組經驗值 | 該組各筆觀測 median 的 median／mean／P10／P90；每筆觀測等權重 |
| 擬合 target | 每筆觀測的 retained median latency；N 使用完整實體 cell 數 |
| 候選公式 | `max(0,a+b×log10(N))`、`max(0,a+b×sqrt(N))`、`max(0,a+b×N)`，另含 constant baseline |
| 選擇方式 | Leave-one-observation-out RMSE 最低者；同時列出 training RMSE 與 R² |
| 樣本不足 | 少於 5 筆有效觀測，或少於 3 種 N，不產生公式 |

父子及多入口資料全部保留且等權重。它們可能共用負載，因此模型的 LOO 誤差不是獨立新 IC 的驗證結果。是否可準確套用新 IC，仍需以新 IC 實測確認；技術、CTS、floorplan 或分析環境變更後尤其應重新校準。程式不強制 fanout／latency 必須單調增加。

離群值排除只針對每個入口內的 cell latency；不會對所有大小 block 的 latency 一起做全域 IQR，避免將大 block 的較長 latency 當成離群值刪除。

## 輸出

| 檔案 | 內容 |
|---|---|
| `hierarchy.rpt` | 縮排階層、各入口 DFF／latch／總負載、mean／median／P10／P90、missing／outlier 數 |
| `observations.csv` | 每個入口一列，包含完整統計、coverage、是否納入模型及原因；latency 欄位皆為 ns |
| `loads.csv` | 每個入口／cell 的選定 pin、clock、來源 edge、兩端 arrival、差值及狀態；可停用 |
| `fanout_latency.csv` | 各 1–2–5 負載區間的觀測數、實際負載中位數與經驗 latency |
| `estimates.csv` | 在校準範圍內的 1–2–5 參考點，例如 1000、2000、5000、10000 及公式預測 |
| `model.rpt` | 候選公式、係數、誤差、選定公式、有效 N 範圍；不足時說明原因 |
| `model.tcl` | 儲存模型供後續重新載入；必須搭配主程式 |
| `run.log` | `status=COMPLETE` 或 `FAILED`、選項、警告；失敗時其餘檔案可能不完整 |

先確認 `run.log` 為 `COMPLETE`，再檢查 `observations.csv` 的 `coverage` 與 `fit_reason`。missing 詳細原因在 `loads.csv` 的 `detail`。

## 使用公式估算新 IC

第一次分析後可直接呼叫：

```tcl
::cg_latency::predict 5000
# 回傳 dict：loads、estimated_latency_ns、extrapolated
```

另一次 session、或只有 Tcl 而沒有 PrimeTime 的環境：

```tcl
source /your/path/cg_clock_latency.tcl
source /your/path/cg_latency_results/model.tcl
::cg_latency::predict 5000

# 預設拒絕超出原本 N 範圍的外插；明確允許時第二參數設 1
::cg_latency::predict 50000 1
```

`model.tcl` 不含通用預設係數；只有實際分析得到足夠資料後才有可用模型。跨 IC 估算是經驗推估，不是 timing signoff。

## 選項

| 選項 | 預設 | 說明 |
|---|---|---|
| `-max_level` | `3` | 掃描第 1 層到此層；`0` 表示全部 |
| `-out_dir` | 自動建立唯一名稱 | 建議指定新的輸出目錄 |
| `-delay_type` | `max` | `max` 或 `min` |
| `-clock_patterns` | `{*}` | Clock 名稱的 glob patterns |
| `-exclude_ref_patterns` | `{}` | 額外排除 ref_name 的 patterns |
| `-exclude_cell_patterns` | `{}` | 排除完整 cell path；若要排除整個 subtree，使用 `{U_MACRO U_MACRO/*}` |
| `-iqr_multiplier` | `1.5` | `0` 停用離群值排除 |
| `-outlier_min_samples` | `8` | 啟用 IQR 的最少有效 cell 數，必須 ≥4 |
| `-min_coverage` | `1.0` | 模型樣本的最低 coverage，可在 0～1 調整；調低後須檢查缺漏偏差 |
| `-time_unit_ns` | `auto` | 一個設計時間單位等於多少 ns；例如設計使用 ps 時指定 `0.001` |
| `-write_loads` | `1` | `0` 停用逐負載明細，減少磁碟輸出 |
| `-continue_generated` | `1` | 是否繼續追蹤 generated-clock source；不進行跨 clock 的 arrival 配對 |
| `-overwrite` | `0` | `1` 先清除本工具固定報表檔名後重建；不刪除其他檔案 |

## 驗證範圍

- 已使用實際 Tcl 8.6 runtime 執行純函式與模擬 PrimeTime collections／attributes 的測試。
- 測試涵蓋統計、window 包裝格式、多 clock／來源 edge 配對、max／min、單位轉換、離群值、模型選擇、階層深度、多入口、cell 去重、latch、macro／ICG 排除、報表輸出及失敗時狀態恢復。
- 本機沒有 `pt_shell`，**尚未用真實 PrimeTime 版本或 IC database 驗證**。模擬測試不能證明 PT API 在你的版本可直接執行。
- 針對單一已載入的分析 session／worker；不在 DMSA manager 合併不同 scenario。
- 大設計會對每個入口執行一次 fanout traversal；全部階層加上逐負載 CSV 可能耗時且檔案較大。

若 PT 執行失敗，保留工具版本、完整錯誤及 `run.log`，可據此調整相容性。
