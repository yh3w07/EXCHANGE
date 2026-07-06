# ---------------------------------------
# NSW - NVT SDC WRAPPER Spec
# ---------------------------------------
## 前提: (BLK = Block)
    - 目前在BLK Level Constraint整合到Top Level Constraint有下列問題:
      問題1: create_clock @ ports大部分都會被移除, Top Level會流Clock近來
      問題2: Block後面的generated clock本來只對應一組master clock, 但從Top Level流進來的master clock可能有n組
      問題3: Top Clock Naming與BLK Clock Naming針對同一個port流進來的Clock有可能不一樣
      問題4: 承上, 在後面其他SDC Command有帶clock option的都需要整個replace Clock Name (example: set_multicycle_path / set_clock_group)
      問題5: 有些BLK SDC Command不需要在Top Level有 (ex: set_case_analysis 1 [get_ports XXX] -> 會在Top其他地方定義)
      問題6: 由於上述, BLK Level除了需要寫自己的BLK Level Constraint, 還需要因應上面需求寫Top Level Constraint
             Example:
             if {$whole_chp == 0} {
                # BLK Level Description
             } else {
                # TOP Level Description
             }
      問題7: 上述問題會造成1) Code不容易閱讀 2) BLK與TOP Level行為可能不一致 
      
## 目的: 
    - 讓BLK Level RD, 只要考慮BLK Level的Constraint, Top Level由NSW接替解決上述問題
    - Top Level還是要介入, 但介入程度變小, 修改BLK Level Code程度變小, 讓Code複雜度降低, 在未來好Maintain

## 細節:
    - NSW的大方向
      使用SDC Wrapper, 完全繼承原生DC/PT的SDC Command, 裡面添加額外功能, 專為Top Level整合做使用
      Example: 
      nvt_create_clock -name clk [get_ports clk] -blk; # -blk 代表只有blk會使用, top level不需要apply
      nvt_create_generated_clock -name clk_gen -master_clock clk -combinational -source [get_ports clk] -top_list $clk_LIST; # clk_LIST是Top Level RD會提供, Top Level流進去的master clock 有哪些

    - 針對上述問題NSW提供的解法:   
      解法1: 可使用-blk option去除
      解法2: 可使用-top_list option  
      解法3: NSW需要將BLK Level的local clock name換成clk_LIST所指定的clock name (需考慮n各clock in使用loop)
      解法4: 同上
      解法5: 可使用-blk option去除
      解法6: BLK Level只要keep當行敘述, NSW處理Top Level的SDC
      解法7: NSW可縮減if..else..end敘述. BLK/TOP Level行為在NSW程式化可控制

    - Top Generated Clock Naming Rule: (讓每一個gen clock知道自己的最root clock是誰)
      目前Top Clock Naming採用Prefix
      假設目前 hierarchy如下列:
                          BLK0               |      BLK1               |     BLK2
      BLK CLK NAME:  aclk_0/aclk_1/aclk_2--->|---> aclk_gen2 --------->|---->aclk_gen3
      TOP CLK NAME:  aclk_0/aclk_1/aclk_2--->|---> aclk0__aclk_gen2--->|---->aclk0__aclk_gen3
                                                   aclk1__aclk_gen2          aclk1__aclk_gen3
                                                   aclk2__aclk_gen2          aclk2__aclk_gen3
    - top_list產生:
      Auto Mode:   在建置第一版DC or PT時候, 讓NSW靠command去追尋相對應的Master Clock是那些
      Manual Mode: 人工自己填入

## 其他考慮:
    - TOP CLK NAME重複性問題:  如果遇到TOP CLK NAME Generation有重複問題, 需要加入BLK postfix解決
    - script 架構:
      各個NSW SDC Command 方開, 讓之後Extend / Maintain容易
      Example: nvt_create_clock.tcl / nvt_create_generated_clock / nvt_set_clock_group .. etc
      使用一個統整的tcl (ex: nsw.tcl) 去把所有NSW command import近來
    - multi-hierarchy
      TOP Level 的定義根據Physical Design時候的規劃而定. 有可能Partition in Partition
      Example: TOP Hierarchy
      ------------------------
      | TOP
      |    -------------------
      |    | GRPAK
      |    |   ------
      |    |   | GRPA
      |    |
      |    |   ------
      |    |   | GRPK
      
      GRPA/GRPK是Physiacl Design中的BLK. 
      1st stage: GRPAK當作TOP檢視STA result
      2nd stage: TOP當作TOP檢視STA result
    - SDC Command的正確性: 
      我手邊有SYNOPSYS提供的DC/PrimeTime SDC Reference Command User Guide, 如何讓你可以檢索這些Command(Command Function / Command Option / Input Type .. etc)
      Example: 使用RAG?
