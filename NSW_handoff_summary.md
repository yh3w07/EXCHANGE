# NSW（NVT SDC Wrapper）Handoff Summary

## 1. 專案目標

NSW 的目標是讓同一份 Block-level Tcl/SDC constraint 可在 Block、Partition 與 Top hierarchy 執行，並吸收以下差異：

- Block clock 與 Top clock 的一對多 mapping。
- Generated clock 的 master/source/name 轉換。
- Multi-hierarchy，例如 `BLK -> Partition -> TOP`。
- Synthesis transformation，例如 single-bit DFF banking 成 multi-bit DFF。
- Cross-library vendor 差異，例如 DFF clock pin 使用 `CK` 或 `CP`。
- Flatten、uniquify、rename、replication、constant propagation 等 object 變化。

核心維護要求：Block constraint 必須維持唯一 source of truth，保留動態 Tcl 寫法，例如 `if`、`foreach`、`proc`、變數與 PrimeTime query；不希望經過 compiler 後重新產生另一份 plain SDC。

## 2. 已確認的架構方向

採用 runtime wrapper，而不是離線 Constraint Compiler：

```text
Block Tcl/SDC
    -> NSW leaf-command adapter
    -> execution context / mapping / policy
    -> native PrimeTime command
```

NSW 應定位為 **Constraint Portability Runtime**，不只是 clock wrapper。

建議拆成以下共用元件：

1. **Execution Context**
   - 保存目前執行層級：BLK、Partition 或 TOP。
   - 保存 instance、scenario、mode/corner 等資訊。
   - 避免 Block SDC 反覆寫 `$whole_chp` 類型的分支。

2. **Object Resolver**
   - 統一服務 `nvt_get_cells`、`nvt_get_pins`、`nvt_get_ports`、`nvt_get_nets`、`nvt_get_clocks` 等 query wrappers。
   - 處理 hierarchy、MBFF、vendor library、rename、replication及missing object。
   - 回傳真正的 PrimeTime collection，不把 collection 當普通 Tcl string。

3. **Clock Lineage / Mapping Registry**
   - 集中保存 local clock、Top clocks、generated clocks、master clock及root clock關係。
   - Clock name prefix只作輸出命名，不作內部 identity。
   - 不建議每個 wrapper call 重複傳 `-top_list`；它最多只作 per-command override。

4. **Command Adapters**
   - 每個 `nvt_*` wrapper只解析該 command 的原生 options及NSW metadata。
   - 共用 mapping、展開、驗證與native dispatch邏輯，不在各wrapper重複實作。

5. **Policy與Trace**
   - 每次操作分類為 `pass / map / expand / collapse / substitute / skip / reject`。
   - 記錄來源file/line/proc、原始selector、mapping原因、最後objects及native command。
   - 未支援或語意不確定時不可靜默猜測。

## 3. MBFF與Cross-library要求

### MBFF

只依賴MB separator不足，應保存bit-aware mapping：

```text
logical register   physical cell   logical pin   physical pin
reg_a[0]           MBFF_17         D             D0
reg_a[1]           MBFF_17         D             D1
reg_a[0]           MBFF_17         Q             Q0
reg_a[*]           MBFF_17         CK            CP
```

需要處理：

- 一對一：`EXACT`
- 一對多：`EXPANDED`
- 多對一：`COLLAPSED`
- 等價pin/cell替換：`SUBSTITUTED`
- 找不到：`MISSING`
- 多個候選且無法決定：`AMBIGUOUS`

Banking可能重新排列bits，因此不可只用名稱規則推導D/Q bit；shared clock pin也需要去重。

### Cross-library

`CK <-> CP` synonym table可作fallback，但主要mapping應基於semantic role：

```text
clock, data, q, qbar, set, reset, scan_in, scan_enable, gate_enable
```

需驗證edge polarity、set/reset polarity、latch vs. flip-flop、functional vs. scan pin及clock-gating pin角色。可優先查library attributes/timing arcs，再使用vendor mapping table。

## 4. 高風險Command Families

第一優先：

- Query：`get_cells`、`get_pins`、`get_ports`、`get_nets`、`get_clocks`、`all_registers`
- Clock：`create_clock`、`create_generated_clock`、`set_clock_groups`、`set_clock_uncertainty`、`set_clock_latency`
- Exceptions：`set_false_path`、`set_multicycle_path`、`set_max_delay`、`set_min_delay`、`set_disable_timing`、`set_data_check`
- Mode：`set_case_analysis`
- I/O：`set_input_delay`、`set_output_delay`、`set_driving_cell`、`set_load`

注意事項：

- `-from/-through/-to` 各自可能一對多，不能無條件做Cartesian product。
- 多個 `-through` 有順序語意。
- `set_disable_timing -from/-to` 必須保持同一cell的timing arc pairing。
- Generated clock 的master、source與name必須一致展開。
- Clock groups必須保留group邊界，不能攤平成單一collection。
- Empty/missing object應依command分類為allow、warning或error。

## 5. 已取得的PrimeTime Reference

原始文件：

```text
C:\Users\yh3w07\Desktop\AI_DATABASE\NSW\references\primetime\pt_command.pdf
C:\Users\yh3w07\Desktop\AI_DATABASE\NSW\references\primetime\reference_info.txt
```

Metadata：

- Title：PrimeTime Constraint Consistency Tool Commands
- PrimeTime release：Y-2026.03
- 961頁，約3.88 MB
- PDF 1.6，未加密，有可搜尋文字層
- Command List：PDF第2～16頁
- TOC可解析出523個唯一commands

已下載並驗證portable Xpdf 4.06：

```text
C:\Users\yh3w07\Documents\Codex\2026-07-01\s\work\tools\xpdf-4.06\
```

下載檔SHA-256：

```text
2B6CA45DA794E7854A6468FD6C8063FDE62701F001CE03FA4F603EAB7E15A0B6
```

已抽取文字：

```text
C:\Users\yh3w07\Documents\Codex\2026-07-01\s\work\references\primetime\pt_command.layout.txt
C:\Users\yh3w07\Documents\Codex\2026-07-01\s\work\references\primetime\command_list_pages_002_016.txt
```

全文約1.78 MB，保留961個form-feed換頁標記。已抽查：

- `create_clock`：PDF page 90
- `create_generated_clock`：page 94
- `get_cells`：page 148
- `get_clocks`：page 159
- `get_pins`：page 215
- `set_case_analysis`：page 790
- `set_false_path`：page 835

文字抽取品質良好，syntax/options可讀。尚未完成523個commands的逐command索引；原規劃輸出 `index.json`、`index.tsv`與每個command獨立section。

## 6. 測試條件

目前開發環境不能直接執行PrimeTime；使用者可在公司環境人工執行`pt_shell`測試並回傳log。

建議測試策略：

1. 使用純Tcl mock backend測試argument parsing、mapping、policy與trace。
2. 每個milestone提供可獨立執行的PrimeTime test bundle。
3. Bundle包含`run.tcl`、test data、預期關鍵log與結果收集步驟。
4. 由使用者在`pt_shell`執行並回傳完整log。
5. PrimeTime collection與command semantics未經真實integration test前，不宣告完成。

## 7. 尚需使用者提供的材料

第一階段只需3段匿名化片段，每段約30～150行：

1. MBFF single-bit到multi-bit mapping案例。
2. Cross-vendor `CK/CP` mapping案例。
3. Block到Top generated-clock整合案例。

片段需附相關`proc/if/foreach`、變數定義或範例值、預期BLK/TOP行為及已知corner case。

架構驗證後，再提供一份完整、匿名化且具代表性的Block SDC，用來檢查global variables、source順序與跨command互動；不需要提供所有Blocks。

若有既有`nvt_get_pins`與`nvt_get_cells`程式，建議作為行為與corner-case參考，但核心resolver可重新設計。是否要求API完全向下相容尚未決定。

## 8. 建議下一步

1. 完成PrimeTime reference的523-command精確索引；先不用vector RAG。
2. 讀取既有`nvt_get_pins/nvt_get_cells`與三個實際SDC案例。
3. 定義Object Resolver的input/output、mapping status與error policy。
4. 定義Execution Context、native dispatch及trace格式。
5. 以以下commands建立第一個vertical slice：

```text
nvt_get_cells
nvt_get_pins
nvt_get_clocks
nvt_create_clock
nvt_create_generated_clock
nvt_set_false_path
nvt_set_case_analysis
```

6. 產生第一份PrimeTime人工integration test bundle。

第一版不應嘗試包完全部SDC commands；應先證明同一份含動態Tcl的Block constraint能在BLK、MBFF、cross-vendor與TOP四種情境下正確執行並留下可追溯紀錄。
