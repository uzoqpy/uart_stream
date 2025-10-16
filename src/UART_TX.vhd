library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity UART_TX is
    port (
        i_Clk           : in  std_logic;
        i_RSTN          : in  std_logic;

        -- enable TX (active high). When '0', TX is idle and ignores i_TX_DV.
        i_TX_EN         : in  std_logic; 		-- active log	

        -- clocks per bit (e.g., 100 MHz / 115200 ? 868)
        i_CLKS_PER_BIT  : in  std_logic_vector(15 downto 0);

        i_TX_DV         : in  std_logic;                 -- 1-cycle load strobe
        i_TX_Byte       : in  std_logic_vector(7 downto 0);
        o_TX_Active     : out std_logic;
        o_TX_Serial     : out std_logic;
        o_TX_Done       : out std_logic;                  -- 1-cycle pulse at end of stop bit
        o_TX_Ready      : out std_logic                   -- '1' when enabled AND idle
    );
end UART_TX;

architecture RTL of UART_TX is
    type t_SM_Main is (s_Idle, s_TX_Start_Bit, s_TX_Data_Bits, s_TX_Stop_Bit, s_Cleanup);
    signal r_SM_Main   : t_SM_Main := s_Idle;

    signal r_Clk_Count : integer := 0;
    signal r_Bit_Index : integer := 0;
    signal r_TX_Data   : std_logic_vector(7 downto 0) := (others => '0');
    signal r_TX_Done   : std_logic := '0';
    signal r_TX_Active : std_logic := '0';
    signal r_TX_Serial : std_logic := '1';
begin
    -- Ready only when enabled AND idle
    o_TX_Ready  <= '1' when (i_TX_EN = '0' and r_SM_Main = s_Idle) else '0';  -- TX_EN active low
    o_TX_Active <= r_TX_Active;
    o_TX_Serial <= r_TX_Serial;
    o_TX_Done   <= r_TX_Done;

    p_UART_TX : process(i_Clk)
        variable clks_per_bit : integer;
    begin
        if rising_edge(i_Clk) then
            -- default: Done deasserted; becomes a 1-cycle pulse in s_Cleanup
            r_TX_Done <= '0';

            if i_RSTN = '0' then
                r_SM_Main   <= s_Idle;
                r_Clk_Count <= 0;
                r_Bit_Index <= 0;
                r_TX_Data   <= (others => '0');
                r_TX_Active <= '0';
                r_TX_Serial <= '1';
                r_TX_Done   <= '0';

            -- TX disable: force idle, hold line high, no done pulse, not ready
            elsif i_TX_EN = '1' then
                r_SM_Main   <= s_Idle;
                r_Clk_Count <= 0;
                r_Bit_Index <= 0;
                r_TX_Active <= '0';
                r_TX_Serial <= '1';
                r_TX_Done   <= '0';

            else
                -- convert input divisor; clamp to >= 1
                clks_per_bit := to_integer(unsigned(i_CLKS_PER_BIT));
                if clks_per_bit < 1 then
                    clks_per_bit := 1;
                end if;

                case r_SM_Main is
                    when s_Idle =>
                        r_TX_Active <= '0';
                        r_TX_Serial <= '1';
                        r_Clk_Count <= 0;
                        r_Bit_Index <= 0;

                        if i_TX_DV = '1' then
                            r_TX_Data <= i_TX_Byte;
                            r_SM_Main <= s_TX_Start_Bit;
                        end if;

                    when s_TX_Start_Bit =>
                        r_TX_Active <= '1';
                        r_TX_Serial <= '0';
                        if r_Clk_Count < (clks_per_bit - 1) then
                            r_Clk_Count <= r_Clk_Count + 1;
                        else
                            r_Clk_Count <= 0;
                            r_SM_Main   <= s_TX_Data_Bits;
                        end if;

                    when s_TX_Data_Bits =>
                        r_TX_Active <= '1';
                        r_TX_Serial <= r_TX_Data(r_Bit_Index);
                        if r_Clk_Count < (clks_per_bit - 1) then
                            r_Clk_Count <= r_Clk_Count + 1;
                        else
                            r_Clk_Count <= 0;
                            if r_Bit_Index < 7 then
                                r_Bit_Index <= r_Bit_Index + 1;
                            else
                                r_Bit_Index <= 0;
                                r_SM_Main   <= s_TX_Stop_Bit;
                            end if;
                        end if;

                    when s_TX_Stop_Bit =>
                        r_TX_Active <= '1';
                        r_TX_Serial <= '1';
                        if r_Clk_Count < (clks_per_bit - 1) then
                            r_Clk_Count <= r_Clk_Count + 1;
                        else
                            r_Clk_Count <= 0;
                            r_SM_Main   <= s_Cleanup;
                        end if;

                    when s_Cleanup =>
                        r_TX_Active <= '0';
                        r_TX_Done   <= '1';   -- single-cycle done strobe
                        r_SM_Main   <= s_Idle;

                    when others =>
                        r_SM_Main <= s_Idle;
                end case;
            end if;
        end if;
    end process;
    
    
    
end RTL;
