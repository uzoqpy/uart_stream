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