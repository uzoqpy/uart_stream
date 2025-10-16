-- This file contains the UART Receiver.  This receiver is able to         
-- receive 8 bits of serial data, one start bit, one stop bit,             
-- and no parity bit.  When receive is complete o_rx_dv will be            
-- driven high for one clock cycle.                                        
--                                                                         
-- Set Generic g_CLKS_PER_BIT as follows:                                  
-- g_CLKS_PER_BIT = (Frequency of i_Clk)/(Frequency of UART)               
-- Example: 10 MHz Clock, 115200 baud UART                                 
-- (10000000)/(115200) = 87 Input from top module  

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity UART_RX is
    port (
        i_Clk           : in  std_logic;
        i_RSTN          : in  std_logic;

        -- enable RX (active high). When '0', RX is idle and ignores the line.
        i_RX_EN         : in  std_logic;  

        -- clocks per bit (e.g., 100 MHz / 9600 ? 10417)
        i_CLKS_PER_BIT  : in  std_logic_vector(15 downto 0);

        i_RX_Serial     : in  std_logic;
        o_RX_DV         : out std_logic;  -- 1-cycle pulse when a byte is ready
        o_RX_Byte       : out std_logic_vector(7 downto 0)
    );
end UART_RX;

architecture rtl of UART_RX is
    type t_SM_Main is (s_Idle, s_RX_Start_Bit, s_RX_Data_Bits, s_RX_Stop_Bit, s_Cleanup);
    signal r_SM_Main   : t_SM_Main := s_Idle;

    signal r_RX_Data_R : std_logic := '1';
    signal r_RX_Data   : std_logic := '1';

    signal r_Clk_Count : integer := 0;
    signal r_Bit_Index : integer range 0 to 7 := 0;
    signal r_RX_Byte   : std_logic_vector(7 downto 0) := (others => '0');
    signal r_RX_DV     : std_logic := '0';
begin
    -- 2-FF synchronizer for RX line
    p_SAMPLE : process (i_Clk)
    begin
        if rising_edge(i_Clk) then
            if i_RSTN = '0' then
                r_RX_Data_R <= '1';
                r_RX_Data   <= '1';
            else
                r_RX_Data_R <= i_RX_Serial;
                r_RX_Data   <= r_RX_Data_R;
            end if;
        end if;
    end process;

    -- RX state machine with enable
    p_UART_RX : process (i_Clk)
        variable clks_per_bit : integer;
    begin
        if rising_edge(i_Clk) then
            if i_RSTN = '0' then
                r_RX_DV     <= '0';
                r_Clk_Count <= 0;
                r_Bit_Index <= 0;
                r_SM_Main   <= s_Idle;

            elsif i_RX_EN = '0' then
                -- Force idle when disabled; abort any in-progress reception
                r_RX_DV     <= '0';
                r_Clk_Count <= 0;
                r_Bit_Index <= 0;
                r_SM_Main   <= s_Idle;

            else
                -- convert divisor; clamp to >=1
                clks_per_bit := to_integer(unsigned(i_CLKS_PER_BIT));
                if clks_per_bit < 1 then
                    clks_per_bit := 1;
                end if;

                case r_SM_Main is
                    when s_Idle =>
                        r_RX_DV     <= '0';
                        r_Clk_Count <= 0;
                        r_Bit_Index <= 0;
                        if r_RX_Data = '0' then
                            r_SM_Main <= s_RX_Start_Bit;  -- start bit edge
                        else
                            r_SM_Main <= s_Idle;
                        end if;

                    -- sample in middle of start bit
                    when s_RX_Start_Bit =>
                        if r_Clk_Count = (clks_per_bit - 1) / 2 then
                            if r_RX_Data = '0' then
                                r_Clk_Count <= 0;
                                r_SM_Main   <= s_RX_Data_Bits;
                            else
                                r_SM_Main   <= s_Idle;  -- false start
                            end if;
                        else
                            r_Clk_Count <= r_Clk_Count + 1;
                            r_SM_Main   <= s_RX_Start_Bit;
                        end if;

                    -- sample each data bit
                    when s_RX_Data_Bits =>
                        if r_Clk_Count < clks_per_bit - 1 then
                            r_Clk_Count <= r_Clk_Count + 1;
                            r_SM_Main   <= s_RX_Data_Bits;
                        else
                            r_Clk_Count               <= 0;
                            r_RX_Byte(r_Bit_Index)   <= r_RX_Data;
                            if r_Bit_Index < 7 then
                                r_Bit_Index <= r_Bit_Index + 1;
                                r_SM_Main   <= s_RX_Data_Bits;
                            else
                                r_Bit_Index <= 0;
                                r_SM_Main   <= s_RX_Stop_Bit;
                            end if;
                        end if;

                    -- stop bit (expect '1')
                    when s_RX_Stop_Bit =>
                        if r_Clk_Count < clks_per_bit - 1 then
                            r_Clk_Count <= r_Clk_Count + 1;
                            r_SM_Main   <= s_RX_Stop_Bit;
                        else
                            r_Clk_Count <= 0;
                            r_RX_DV     <= '1';        -- one-cycle strobe
                            r_SM_Main   <= s_Cleanup;
                        end if;

                    when s_Cleanup =>
                        r_RX_DV   <= '0';
                        r_SM_Main <= s_Idle;

                    when others =>
                        r_SM_Main <= s_Idle;
                end case;
            end if;
        end if;
    end process;

    o_RX_DV   <= r_RX_DV;
    o_RX_Byte <= r_RX_Byte;
    
       
end rtl;
