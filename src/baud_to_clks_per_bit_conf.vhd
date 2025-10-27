-- baud_to_clks_per_bit_conf_default.vhd
-- If baud or fclk is invalid, output DEFAULT_CPB; otherwise round(fclk/baud).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity baud_to_clks_per_bit_conf is
    generic (
        OUT_WIDTH    : integer := 16;
        -- Pick the CPB you want as a fallback:
        -- e.g., 10417 for 9600 baud @ 100 MHz, or 868 for 115200 @ 100 MHz
        DEFAULT_CPB  : integer := 10417
    );
    port (
        i_fclk_hz       : in  std_logic_vector(31 downto 0);
        i_baud_val      : in  std_logic_vector(31 downto 0);
        o_clks_per_bit  : out std_logic_vector(OUT_WIDTH-1 downto 0)
    );
end entity;

architecture comb of baud_to_clks_per_bit_conf is
begin
    process(i_fclk_hz, i_baud_val)
        variable fclk_i : integer;
        variable baud_i : integer;
        variable cpb_i  : integer;
        variable max_u  : unsigned(OUT_WIDTH-1 downto 0);  -- 0xFFFF.. for saturation
        variable def_i  : integer;
    begin
        fclk_i := to_integer(unsigned(i_fclk_hz));
        baud_i := to_integer(unsigned(i_baud_val));
        max_u  := (others => '1');

        -- Clamp DEFAULT_CPB into [1 .. max]
        if DEFAULT_CPB < 1 then
            def_i := 1;
        elsif DEFAULT_CPB > to_integer(max_u) then
            def_i := to_integer(max_u);
        else
            def_i := DEFAULT_CPB;
        end if;

        if (baud_i <= 0) or (fclk_i <= 0) then
            cpb_i := def_i;  -- use your chosen default
        else
            -- round( fclk / baud ) = (fclk + baud/2) / baud
            cpb_i := (fclk_i + (baud_i/2)) / baud_i;

            -- saturate to output width
            if cpb_i < 1 then
                cpb_i := 1;
            elsif cpb_i > to_integer(max_u) then
                cpb_i := to_integer(max_u);
            end if;
        end if;

        o_clks_per_bit <= std_logic_vector(to_unsigned(cpb_i, OUT_WIDTH));
    end process;
end architecture;


--library ieee;
--use ieee.std_logic_1164.all;
--use ieee.numeric_std.all;
--
---- Compile-time clks-per-bit calculator (no runtime math).
--entity baud_to_clks_per_bit_const is
--    generic (
--        FCLK_HZ   : positive := 100_000_000; -- fabric clock, Hz
--        BAUD_HZ   : positive := 115_200;     -- UART baud, Hz
--        OUT_WIDTH : positive := 16;          -- width of output vector
--        ROUND_EN  : boolean  := false        -- true = round, false = truncate
--    );
--    port (
--        o_clks_per_bit : out std_logic_vector(OUT_WIDTH-1 downto 0)
--    );
--end entity;
--
--architecture rtl of baud_to_clks_per_bit_const is
--
--    -- Choose rounded or truncated division at elaboration.
--    function clks_per_bit_const(
--        constant fclk : natural;
--        constant baud : natural;
--        constant round_en : boolean
--    ) return natural is
--    begin
--        if round_en then
--            return (fclk + (baud / 2)) / baud; -- round to nearest
--        else
--            return fclk / baud;                 -- truncate
--        end if;
--    end function;
--
--    constant CLKS_PER_BIT_INT : natural :=
--        clks_per_bit_const(FCLK_HZ, BAUD_HZ, ROUND_EN);
--
--    -- Optional width check (remove if your tool dislikes asserts).
--    -- pragma translate_off
--    --assert CLKS_PER_BIT_INT < 2**OUT_WIDTH
--    --    report "o_clks_per_bit width too small for computed value"
--    --    severity failure;
--    -- pragma translate_on
--
--    constant CLKS_PER_BIT_VEC : unsigned(OUT_WIDTH-1 downto 0) :=
--        to_unsigned(CLKS_PER_BIT_INT, OUT_WIDTH);
--
--begin
--    o_clks_per_bit <= std_logic_vector(CLKS_PER_BIT_VEC);
--end architecture;
                                   