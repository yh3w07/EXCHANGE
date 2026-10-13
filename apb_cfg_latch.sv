module apb_cfg_latch (
    input  logic        PCLK,
    input  logic        PRESETn,
    input  logic        PSEL,
    input  logic        PENABLE,
    input  logic        PWRITE,
    input  logic [31:0] PADDR,
    input  logic [31:0] PWDATA,
    input  logic        scan_test_en,
    output logic [31:0] cfg_q
);

    wire write_en;
    wire gclk;

    assign write_en = PSEL & PENABLE & PWRITE
                    & (PADDR == 32'h100);

    // TSMC OR-type ICG
    // Cell name depends on library drive strength
    CLKHQD12BWP7T40P140HVT u_icg (
        .CPN (PCLK),
        .E   (write_en),
        .TE  (scan_test_en),
        .Q   (gclk)
    );

    // Active-low CFG Latch
    always_latch begin
        if (!PRESETn)
            cfg_q <= 32'b0;
        else if (!gclk)
            cfg_q <= PWDATA;
    end

endmodule
