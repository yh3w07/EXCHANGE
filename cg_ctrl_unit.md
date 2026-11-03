# ---------------------------------------
# Clock Tree Latency Analysis
# ---------------------------------------
## 目的: 
設計一個PrimeTime tcl: 使用既有的IC current_design設計, 掃過一定level的partition, 估算chip多少DFF對應的clock latency約有多少

## 細節:
- 針對current_design下的partition (hierarical block), Level可以User自行定義
- 每個Level掃過整個hierarical block, 看此block interface有多少clock input
- 針對每個clock input -> 看推多少DFF -> 統計從這個clock input的arrival到DFF/CK arrival走了多少ns -> 估算中位數or平均值
- 整理出"多少DFF fanout預估的Latency為多少"的經驗值 (離峰的值可不考慮, 使用中位數??)
- report應該最少有下列兩個:
  1. 每個block的hierarchical report
     TOP
       BLK_A (hclk, DFF: 3333, Average latency: 0.67ns, Median latency: 0.7ns)
             (core_clk, DFF .. )
           SUB_BLK_A (hclk, DFF: 1111, Average latency: 0.4ns, Median latency: 0.5ns)
                     (core_clk, DFF .. )
           SUB_CLK_B 
       BLK_B (hclk, DFF: 3333, Average latency: 0.67ns, Median latency: 0.7ns)
             (core_clk, DFF .. )
           SUB_BLK_C (hclk, DFF: 1111, Average latency: 0.4ns, Median latency: 0.5ns)
                     (core_clk, DFF .. )
           SUB_CLK_D 

  2. 最後統計的預估clock latency report or formula
     Example:
     # DFF, Estimated Latency, 
     1000 , 0.5ns
     5000 , 0.8ns
     10000, 1.0ns
     ...
